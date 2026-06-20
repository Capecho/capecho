import 'package:capecho_api/capecho_api.dart'
    show CapechoApi, ExplainStatus, WordExplanation, Reading, PosGroup;
import 'package:capecho_app_core/capecho_app_core.dart' show pronunciationParts, computeSenseLayout;
import 'package:capture_native/capture_native.dart';

/// One part of speech held by the device-local cache: its label + meanings (per-POS senses, all of
/// them). Plain records (not the store's row types) keep this controller free of a
/// `capecho_local_store` dependency.
typedef CachedPos = ({String partOfSpeech, List<String> senses});

/// One pronunciation reading held by the device-local cache: the bare primary/secondary transcriptions
/// (`""` when omit-on-failed or the target has no second slot), the idiom [kind] (or null), and its
/// per-POS [pos] rows.
typedef CachedReading = ({
  String pronunciationPrimary,
  String pronunciationSecondary,
  String? kind,
  List<CachedPos> pos,
});

/// The full free-layer blob held by the device-local cache: the pronunciation/POS [readings] with their
/// senses. (The senses ARE the explanation — there's no prose summary.)
typedef CachedExplanation = ({List<CachedReading> readings});

/// A full-blob lookup against the device-local explanation cache; null on a miss.
typedef CachedExplanationLookup =
    CachedExplanation? Function({
      required String surfaceUnit,
      required String targetLanguage,
      required String explanationLanguage,
    });

/// Persists a fresh `/explain` result into the device-local cache.
typedef CachedExplanationStore =
    void Function({
      required String surfaceUnit,
      required String targetLanguage,
      required String explanationLanguage,
      required List<CachedReading> readings,
    });

/// Fetches the free word-layer explanation for a just-shown capture and pushes it into the native
/// capture overlay's explanation slot (loading → ready/failed). The overlay is fire-and-forget native
/// UI; this controller is the Dart side that drives its slot over the `updateOverlayExplanation`
/// bridge — and the side that knows the TARGET PROFILE: pronunciation labels/decoration are computed
/// here ([pronunciationParts]) and the per-POS sense LAYOUT (cap/numbering/hint) by
/// [computeSenseLayout], so the native renderer stays presentational (no US/UK, no cap rules in Swift).
///
/// The SERVER is the only target allowlist (Phase D3 of docs/multilingual-explanations.md): every
/// capture requests `/explain`, and a `language_unsupported` status drives the native slot's
/// "not available for this language yet" treatment via the `lang_unsupported` bridge phase.
///
/// RFC §B cost gates wrap the fetch: a degenerate-junk gate ([isLikelyJunk], pure punctuation /
/// numbers / URLs) plus a keyboard-mash gate ([isLikelyGibberish], single-token "asdfgh" / "aaaa")
/// drop non-words before any call — showing the calm "not a word" slot instead — and an optional
/// device-local cache ([readCache] / [writeCache]) shows a re-captured unit's meaning OFFLINE and
/// persists each fresh result, so the only `/explain` calls are first-time, real-word captures.
class OverlayExplanationController {
  OverlayExplanationController({
    required this.api,
    required this.capture,
    this.explanationLanguage = 'en',
    this.readCache,
    this.writeCache,
  });

  final CapechoApi api;
  final CaptureNative capture;

  /// The gloss (native) language (`en` | `zh-Hans` | `es`). The host passes the live account/prefs
  /// value so a Settings change takes effect on the next capture.
  final String explanationLanguage;

  /// Device-local explanation cache (RFC §B.3.1), injected so this controller stays testable without a
  /// real store. [readCache] returns a unit's already-explained blob (→ show offline, skip the
  /// network); [writeCache] persists a fresh `/explain` result so the next capture of that unit is
  /// offline-instant. Both no-op when omitted (tests / a host without a store).
  final CachedExplanationLookup? readCache;
  final CachedExplanationStore? writeCache;

  /// Monotonic token: the overlay is reused across captures, so a slow fetch for capture A must not paint
  /// its result into capture B's slot. Each [explainFor] claims the latest generation; a fetch whose
  /// generation was superseded drops its result silently (capture B's own fetch drives the slot).
  int _generation = 0;

  /// Fetch `/explain` for [unit] (the just-captured word) and push the result into the overlay.
  /// `api.explain` works signed-in (generates on miss) or anonymous (cache-hit only); a miss or any
  /// failure resolves to the calm "failed" slot — the word still saves and the Word Book fetches its
  /// meaning later. [explanationLanguage] overrides the gloss language for this call (the host passes
  /// the live account value so a Settings change takes effect on the next capture); it falls back to
  /// the controller's default when omitted.
  Future<void> explainFor({
    required String unit,
    required String targetLanguage,
    String? explanationLanguage,
  }) async {
    // Claim this generation FIRST — before any early-return guard — so a NEW capture (even a junk /
    // empty / non-allowlisted one that paints nothing) supersedes a prior in-flight fetch. Otherwise
    // that older fetch would resolve, pass its staleness check, and paint its stale meaning into THIS
    // capture's overlay slot (cross-capture contamination).
    final gen = ++_generation;
    final u = unit.trim();
    if (u.isEmpty) {
      return; // nothing to explain; the native slot stays resting
    }
    if (isLikelyJunk(u) || isLikelyGibberish(u)) {
      // Not a vocabulary unit — pure punctuation/number/URL (junk), or a single-token keyboard-mash /
      // repeated-key string ("asdfgh", "aaaa"). Don't spend a call; show the calm "not a word" slot.
      // The capture still SAVES (decision: 照常入库、仅不查) — the user can delete it from the Word Book.
      await capture.updateOverlayExplanation(phase: 'not_a_word');
      return;
    }
    final lang = explanationLanguage ?? this.explanationLanguage;
    // Re-capture of a unit already explained on this device: show the cached meaning OFFLINE and skip
    // the network (RFC §B.3.1 — the free layer is a public, context-independent meaning).
    final cached = readCache?.call(
      surfaceUnit: u,
      targetLanguage: targetLanguage,
      explanationLanguage: lang,
    );
    if (cached != null) {
      await _pushReady(_cachedToExplanation(cached), targetLanguage: targetLanguage);
      return;
    }
    await capture.updateOverlayExplanation(phase: 'loading');
    try {
      final res = await api.explain(unit: u, target: targetLanguage, explanationLang: lang);
      if (gen != _generation) return; // a newer capture superseded this fetch
      if (res.status == ExplainStatus.notAWord) {
        // The model itself declined a word-shaped non-word (L3) that the local gates couldn't catch —
        // same calm "not a word" slot. The capture still saves (照常入库、仅不查).
        await capture.updateOverlayExplanation(phase: 'not_a_word');
        return;
      }
      if (res.status == ExplainStatus.languageUnsupported) {
        // D3: the SERVER is the only allowlist. Its language_unsupported drives the native
        // langUnsupported note (copy unchanged); the capture still saves.
        await capture.updateOverlayExplanation(phase: 'lang_unsupported');
        return;
      }
      final explanation = res.explanation;
      // The captured unit's PRIMARY sense is the server's must-pass core. A blob without any sense is
      // unusable (no fallback field exists).
      if (explanation != null && explanation.primarySense.trim().isNotEmpty) {
        await _pushReady(explanation, targetLanguage: targetLanguage);
        // Cache the public free-layer blob so the next capture of this unit is offline-instant.
        writeCache?.call(
          surfaceUnit: u,
          targetLanguage: targetLanguage,
          explanationLanguage: lang,
          readings: _toCachedReadings(explanation),
        );
      } else {
        await capture.updateOverlayExplanation(phase: 'failed');
      }
    } catch (_) {
      if (gen != _generation) return; // superseded — let the newer capture own the slot
      await capture.updateOverlayExplanation(phase: 'failed');
    }
  }

  /// Paint the ready slot: compute the per-POS sense LAYOUT ([computeSenseLayout]) + display-ready
  /// pronunciation parts ([pronunciationParts], from the TARGET profile), then bridge them so the native
  /// side renders verbatim. Shared by the fresh-fetch and offline cache-hit paths so a re-capture
  /// restores the SAME content. Every stored sense shows on one line per POS (no cap, no "more" hint —
  /// the overlay scrolls if tall).
  Future<void> _pushReady(WordExplanation explanation, {required String targetLanguage}) {
    final layout = computeSenseLayout(explanation);
    return capture.updateOverlayExplanation(
      phase: 'ready',
      readings: [
        for (final r in layout.readings)
          {
            'pronunciations': [
              for (final part in pronunciationParts(
                targetLanguage: targetLanguage,
                primary: r.pronunciationPrimary,
                secondary: r.pronunciationSecondary,
              ))
                {'label': part.label, 'display': part.display},
            ],
            'isIdiom': r.isIdiom,
            'pos': [
              for (final p in r.pos)
                {'partOfSpeech': p.partOfSpeech, 'senses': p.senses, 'note': p.note},
            ],
          },
      ],
    );
  }

  /// Rebuild an api [WordExplanation] from a cached blob, so the cache-hit path runs through the same
  /// [computeSenseLayout] + bridge as a fresh fetch.
  WordExplanation _cachedToExplanation(CachedExplanation c) => WordExplanation(
    readings: [
      for (final r in c.readings)
        Reading(
          pronunciationPrimary: r.pronunciationPrimary,
          pronunciationSecondary: r.pronunciationSecondary,
          kind: r.kind,
          pos: [for (final p in r.pos) PosGroup(partOfSpeech: p.partOfSpeech, senses: p.senses)],
        ),
    ],
  );

  /// Flatten a fresh explanation into the cache record shape persisted by [writeCache].
  List<CachedReading> _toCachedReadings(WordExplanation e) => [
    for (final r in e.readings)
      (
        pronunciationPrimary: r.pronunciationPrimary,
        pronunciationSecondary: r.pronunciationSecondary,
        kind: r.kind,
        pos: [for (final p in r.pos) (partOfSpeech: p.partOfSpeech, senses: p.senses)],
      ),
  ];
}
