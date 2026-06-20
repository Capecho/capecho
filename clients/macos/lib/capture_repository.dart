import 'dart:io';

import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_local_store/capecho_local_store.dart';
import 'package:capture_native/capture_native.dart';
import 'package:path_provider/path_provider.dart';

import 'metrics_recorder.dart';
import 'overlay_explanation_controller.dart' show CachedExplanation, CachedReading;

/// The LOCAL dedup key for OFFLINE capture — the deterministic, language-independent normalization the
/// device store keys on before sync. Mirrors the server's `dedupKey` (backend/src/dedup-key.ts) shared
/// part — lowercase + collapse-whitespace + trim + strip edge punctuation — and deliberately does NOT
/// lemmatize: `study`/`studied` and `saw`/`see` stay distinct cards (T21 2026-06-03). NFC is the one step
/// left to the server (Dart has no native NFC); the server re-keys authoritatively on sync, so any gap
/// self-heals. Dedup is language-independent (the scope key already carries the target). A shared parity
/// fixture pins this against the TS `dedupKey`.
String localDedupKey(String surfaceUnit) => surfaceUnit
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .replaceAll(RegExp(r'^[^\p{L}\p{M}\p{N}]+|[^\p{L}\p{M}\p{N}]+$', unicode: true), '');

const String kLocalDedupVersion = 'client-v1';

/// Owns the device local store + the native capture journal, and the
/// save → durable-journal → drain → store loop (ENG-1).
class CaptureRepository {
  CaptureRepository._(this.capture, this._store);

  final CaptureNative capture;
  final LocalStore _store;
  MetricsRecorder? _metrics;

  /// Opens the store (co-located with the native journal under Application
  /// Support/Capecho) and drains any journaled-but-undrained captures — the
  /// crash-recovery path on launch.
  static Future<CaptureRepository> open() async {
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory('${supportDir.path}/Capecho');
    await dir.create(recursive: true);
    final store = LocalStore.open(
      path: '${dir.path}/local-store.db',
      normalizer: localDedupKey,
      normalizationVersion: kLocalDedupVersion,
    );
    final repo = CaptureRepository._(CaptureNative(), store);
    await repo.drain();
    return repo;
  }

  /// Drains the native journal into the local store (idempotent). Returns a
  /// `{ contextClientRowId : wordId }` map for the entries that NEWLY CREATED a
  /// word this drain — so the host can claim just the row tied to the save event
  /// it's reacting to (its `SavedRef.clientRowId`), and only when that word is
  /// brand new. A re-capture that dedups into an existing word, and any OTHER
  /// entry that happens to drain in the same pass (e.g. a pre-login entry whose
  /// earlier drain failed), are excluded — so a pre-login backlog word is never
  /// auto-claimed without explicit Sync (bug #5 + review follow-ups). Empty when
  /// nothing new was created.
  Future<Map<String, String>> drain() async {
    final raw = await capture.journalEntries(_store.lastDrainedSeq);
    if (raw.isEmpty) return const {};
    final entries = <JournalEntry>[];
    for (final record in raw) {
      try {
        entries.add(JournalEntry.fromMap(record));
      } catch (_) {
        // A structurally-invalid record must NOT abort the whole drain — that
        // would never advance the cursor and would permanently wedge every
        // later capture (review H1). Native validates before writing, so this
        // is belt-and-suspenders for a corrupted/legacy record: skip it; valid
        // higher-seq entries still drain and advance the cursor past it.
        continue;
      }
    }
    if (entries.isEmpty) return const {};
    // Collect the (save-event id → word id) mapping the drain assigns, then hand it to the §14 metrics
    // recorder (T17) so capture_completed is keyed by the WORD id — correlatable with the word-id-keyed
    // sync funnel. The callback only appends (side-effect-free inside the txn); we pipe it AFTER drain
    // returns (post-COMMIT). On a rollback `_store.drain` throws, so no phantom mapping is ever piped.
    // A null recorder (the pre-startMetrics launch drain) simply skips it.
    final saved = <({String clientRowId, String wordId})>[];
    final createdByContext = <String, String>{};
    _store.drain(
      entries,
      onApplied: (clientRowId, wordId, created) {
        saved.add((clientRowId: clientRowId, wordId: wordId));
        if (created) createdByContext[clientRowId] = wordId;
      },
    );
    if (saved.isNotEmpty) _metrics?.onCaptureDrained(saved);
    return createdByContext;
  }

  /// Durably saves a capture, then projects it into the store. Returns the
  /// durable-write receipt.
  ///
  /// Two-phase contract (see local-store README): phase 1 — the native fsync'd
  /// journal append — is the durable commit and the honest "saved" signal; once
  /// [CaptureNative.saveCapture] resolves, the capture CANNOT be lost. Phase 2 —
  /// the [drain] into the queryable store — is a best-effort, idempotent
  /// projection that self-heals on the next launch drain, so a drain failure
  /// must NOT fail the save (that would falsely report a durable capture as
  /// lost — review P2).
  Future<SavedRef> save(CaptureResult result, {required String targetLanguage}) async {
    final unit = result.word?.trim() ?? '';
    // Persist the single punctuation-delimited SENTENCE (the overlay's editable
    // field), falling back to the wider context only when there is no segmented
    // sentence — same precedence as CaptureNative.showOverlay, so this path (no
    // live caller today) can't diverge from what the overlay saves (CR B2).
    final context = (result.sentence?.isNotEmpty ?? false)
        ? result.sentence
        : (result.context.isNotEmpty ? result.context : null);
    final ref = await capture.saveCapture(
      surfaceUnit: unit,
      targetLanguage: targetLanguage,
      contextText: (context != null && context.isNotEmpty) ? context : null,
      // Stamped ONLY when the context's script makes its language certain — never
      // defaulted to the target (the unit's language and the sentence's genuinely
      // diverge, e.g. a zh unit captured inside an English article). Same rule as
      // the live native Save path (CaptureNativePlugin.overlaySave).
      contextLanguage: (context != null && context.isNotEmpty)
          ? scriptCertainLanguage(context)
          : null,
      // Enum names map 1:1 to the journal's allowed source tags
      // ('ocr' | 'selection' | 'clipboard').
      source: result.contextSource.name,
    );
    // Phase 2 is best-effort: swallow a projection failure so it never masquerades
    // as a lost capture. The undrained journal re-applies on the next launch (or
    // the next successful drain), and `lastDrainedSeq` makes that replay a no-op.
    try {
      await drain();
    } catch (_) {
      // Intentionally swallowed. Production should surface this on a separate
      // telemetry/log channel (the capture is durable; only the projection lagged).
    }
    return ref;
  }

  List<WordRow> savedWords() => _store.activeWords();

  /// Whether [surfaceUnit] under [targetLanguage] is already an active word the current viewer would see
  /// in their Word Book — drives the capture overlay's "already in your Word Book" cue on a re-capture
  /// (bug #6). Scoped to exactly what the viewer's book shows so the cue and the book never disagree:
  /// signed out (`accountId` null) → the anonymous catalog; signed in → only rows synced into THIS
  /// account. Un-synced anonymous rows do NOT count when signed in (they aren't in the account's book
  /// yet) — the fix for the stale "already saved" cue after a sign-in / account switch.
  bool isAlreadySaved(String surfaceUnit, String targetLanguage, {String? accountId}) =>
      _store.hasActiveWord(surfaceUnit, targetLanguage, accountId: accountId);

  /// Active words that are still anonymous (pre-login, `claimed = 0`) — the rows a signed-out Word
  /// Book reads, and the rows offered for the post-login sync. Account-synced rows are excluded, which
  /// is what isolates them after a sign-out.
  List<WordRow> anonymousWords() => _store.anonymousWords();

  /// The locally-saved context sentences for a word (the signed-out Word Book detail + the post-login
  /// claim payload).
  List<ContextRow> contextsFor(String wordClientRowId) => _store.contextsFor(wordClientRowId);

  /// The `(unit, contextText)` of a saved context row, for matching an overlay preview's held gloss to
  /// the row it belongs to before caching it locally. Null for an unknown id / a context with no text.
  ({String unit, String contextText})? contextGlossKey(String contextClientRowId) =>
      _store.contextGlossKey(contextClientRowId);

  /// Cache the in-sentence "Explain here" gloss on a just-saved context row so the Word Book shows it
  /// without re-generating (the signed-out path; signed in also adopts it server-side). No-op for an
  /// unknown id. See [LocalStore.setContextGloss].
  void setContextGloss(String contextClientRowId, String meaning) =>
      _store.setContextGloss(contextClientRowId, meaning);

  /// The device-cached free word-layer explanation (per-POS senses + pronunciation readings) for a
  /// unit, as the overlay controller's store-free record shape, or null on a miss — lets a re-capture
  /// show its meaning OFFLINE and skip a redundant `/explain` (eng-review Issue 1 / RFC §B.3.1). Keyed
  /// by the same normalization as the dedup, so any surface form of the unit hits. Converting to records
  /// here keeps the controller free of a `capecho_local_store` dependency.
  CachedExplanation? cachedExplanation({
    required String surfaceUnit,
    required String targetLanguage,
    required String explanationLanguage,
  }) {
    final hit = _store.getExplanation(
      surfaceUnit: surfaceUnit,
      targetLanguage: targetLanguage,
      explanationLanguage: explanationLanguage,
    );
    if (hit == null) return null;
    return (
      readings: [
        for (final r in hit.readings)
          (
            pronunciationPrimary: r.pronunciationPrimary,
            pronunciationSecondary: r.pronunciationSecondary,
            kind: r.kind,
            pos: [for (final g in r.pos) (partOfSpeech: g.partOfSpeech, senses: g.senses)],
          ),
      ],
    );
  }

  /// Cache a free-layer explanation (its per-POS senses + pronunciation readings) after a successful
  /// `/explain`, so the next capture of the same unit is offline-instant. Mirrors the public cache; the
  /// store refuses a unit that normalizes away or a senseless blob. Best-effort — never on the save
  /// path, so it can't fail a capture. The readings are the overlay controller's plain records so
  /// callers don't depend on the store's row types.
  void cacheExplanation({
    required String surfaceUnit,
    required String targetLanguage,
    required String explanationLanguage,
    required List<CachedReading> readings,
  }) => _store.putExplanation(
    surfaceUnit: surfaceUnit,
    targetLanguage: targetLanguage,
    explanationLanguage: explanationLanguage,
    readings: [
      for (final r in readings)
        LocalReading(
          pronunciationPrimary: r.pronunciationPrimary,
          pronunciationSecondary: r.pronunciationSecondary,
          kind: r.kind,
          pos: [
            for (final g in r.pos) LocalPosGroup(partOfSpeech: g.partOfSpeech, senses: g.senses),
          ],
        ),
    ],
    now: DateTime.now().millisecondsSinceEpoch,
  );

  /// Soft-delete a local word (signed-out Word Book delete). Idempotent; a later resave resurrects it.
  void softDelete(String wordClientRowId) => _store.softDelete(wordClientRowId);

  /// Restore a soft-deleted local word (signed-out Word Book Undo). Idempotent.
  void restore(String wordClientRowId) => _store.restore(wordClientRowId);

  /// Mark locally-captured words as synced into the account [accountId] (`claimed = 1`) after a
  /// successful `POST /words/claim`, so a signed-out Word Book no longer shows them and the signed-in
  /// "already saved" cue can scope to the owning account. See [LocalStore.markClaimed].
  void markClaimed(List<String> wordClientRowIds, String accountId) =>
      _store.markClaimed(wordClientRowIds, accountId);

  /// Start the §14 metrics pipeline (CEO-10): wire the native capture-lifecycle stream + this store's
  /// durable buffer to `POST /metrics` via [api]. Idempotent — a second call is a no-op. The store
  /// stays private; [metrics] exposes the recorder so the app can record the sync funnel + cascade
  /// failures (the events that don't originate in the native overlay).
  Future<void> startMetrics({required CapechoApi api, String? appVersion}) async {
    if (_metrics != null) return;
    final id = await capture.installId();
    final recorder = MetricsRecorder(
      lifecycle: capture.captureLifecycle,
      store: _store,
      api: api,
      installId: id,
      appVersion: appVersion,
    );
    _metrics = recorder;
    recorder.start();
  }

  /// The §14 metrics recorder once [startMetrics] has run (else null) — for the sync funnel +
  /// capture-failure events the app emits outside the native overlay path.
  MetricsRecorder? get metrics => _metrics;

  void close() {
    _metrics?.dispose();
    _store.close();
  }
}
