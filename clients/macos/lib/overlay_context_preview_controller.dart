import 'package:capecho_api/capecho_api.dart' show CapechoApi, ApiException;
import 'package:capture_native/capture_native.dart';

/// Fetches the opt-in IN-CONTEXT explanation preview (E2) for a just-captured word and pushes the
/// result into the native capture overlay's ready card. The user taps "Explain in this sentence"; the
/// overlay shows a spinner immediately (native), then this controller runs the metered
/// `POST /explain/context/preview` and pushes the in-context gloss — or a quota / failure note — back
/// over the `updateOverlayContextPreview` bridge.
///
/// §178 holds: this only ever runs in response to a user tap (the overlay emits the request via
/// [CaptureNative.overlayContextPreviewRequests]), never automatically. The preview is metered from the
/// SAME daily pool as the saved context layer (one 10/day cap), so a tap costs exactly like a save-time
/// explanation.
///
/// Adopt-on-save (no recharge): a successful preview's `previewHandle` is remembered here keyed by its
/// `(unit, sentence)`. When the user then taps Save, the host's immediate auto-claim looks the handle up
/// via [adoptableHandleFor] and carries it on the claim row; the backend attaches that already-metered
/// gloss to the new context (no recharge) — so the Word Book entry already shows the explanation. The
/// handle lives only in memory: a preview TTL-expires in ~30 min, and the realistic flow (signed in,
/// online, preview → Save → immediate claim) resolves well within that, so threading it through the
/// local journal / store would buy nothing. A miss (edited sentence, app relaunch, expiry) just falls
/// back to the user re-explaining from the Word Book — the previous behavior.
class OverlayContextPreviewController {
  OverlayContextPreviewController({required this.api, required this.capture});

  final CapechoApi api;
  final CaptureNative capture;

  /// Monotonic token: the overlay is reused across captures, so a slow preview for word A must not paint
  /// into word B's card. Each [previewFor] claims the latest generation; a superseded result is dropped.
  /// (The native side ALSO guards on the still-shown unit, so this is defense in depth — a new capture
  /// resets the native slot, and a late result whose word no longer matches is dropped there too.)
  int _generation = 0;

  // The last SUCCESSFUL preview's adoptable handle, scoped to the exact `(unit, sentence)` it was
  // generated for. Cleared at the start of every [previewFor] so a failed/superseded/quota run never
  // leaves a stale handle that a Save could wrongly adopt. Matched on exact equality (the same capture
  // feeds both the preview and the save), mirroring the backend's sentence-equality adopt guard.
  String? _lastHandle;
  String? _lastUnit;
  String? _lastContextText;
  // The last successful preview's gloss TEXT, scoped to the same `(unit, sentence)` as the handle.
  // Persisted to the local store on Save so the (signed-out) Word Book renders it without re-generating —
  // the local-display twin of the server-side adopt the handle drives.
  String? _lastMeaning;

  /// The still-valid preview handle for [unit] inside [contextText], or null when the most recent
  /// preview was for a different word/sentence (or there is none). The host calls this when building the
  /// claim row for a just-saved word so the paid gloss is adopted instead of re-generated.
  String? adoptableHandleFor({required String unit, required String contextText}) {
    if (_lastHandle == null) return null;
    if (unit.trim() == _lastUnit && contextText == _lastContextText) return _lastHandle;
    return null;
  }

  /// The last successful preview's gloss TEXT for [unit] inside [contextText], or null on a mismatch /
  /// none. The host writes it to the just-saved context row's local cache (matched on the SAME exact
  /// `(unit, sentence)` the overlay guards on), so the Word Book shows the explanation offline — even
  /// signed out, where no server adopt runs.
  String? adoptableGlossFor({required String unit, required String contextText}) {
    if (_lastMeaning == null) return null;
    if (unit.trim() == _lastUnit && contextText == _lastContextText) return _lastMeaning;
    return null;
  }

  /// Run the metered in-context preview for [unit] inside [contextText] and push the terminal state into
  /// the overlay. The native side already shows the spinner on tap, so this pushes only `ready` (with the
  /// gloss), `quota` (the shared daily cap is spent — its own calm treatment), `login` (the endpoint is
  /// account-only and the caller is signed out — a prompt to sign in for the free daily allowance), or
  /// `failed`. The word still saves regardless, and its meaning is available later in the Word Book.
  ///
  /// [contextLanguage] and [spanStart]/[spanEnd] are forwarded verbatim from the native request (computed
  /// there on the CURRENT text — script-certain language, unique-occurrence span); the backend prompt
  /// uses them to label the text's language and mark the asked-about occurrence. All optional: absent
  /// means "unknown", which the backend treats as exactly that (never defaulting).
  Future<void> previewFor({
    required String unit,
    required String contextText,
    required String targetLanguage,
    String? explanationLanguage,
    String? contextLanguage,
    int? spanStart,
    int? spanEnd,
  }) async {
    final gen = ++_generation;
    // A fresh run invalidates any prior adoptable handle (different word/sentence, or a retry of this
    // one) until it succeeds again — so a Save mid-flight never adopts a stale gloss.
    _lastHandle = null;
    _lastUnit = null;
    _lastContextText = null;
    _lastMeaning = null;
    final u = unit.trim();
    if (u.isEmpty || contextText.trim().isEmpty) return; // nothing to explain in-context
    try {
      final res = await api.explainContextPreview(
        surfaceUnit: u,
        contextText: contextText,
        targetLanguage: targetLanguage,
        contextLanguage: contextLanguage,
        spanStart: spanStart,
        spanEnd: spanEnd,
        explanationLang: explanationLanguage,
      );
      if (gen != _generation) return; // a newer request (or capture) superseded this one
      await capture.updateOverlayContextPreview(phase: 'ready', meaning: res.meaning);
      // Remember the paid gloss so Save can adopt it without recharge (server-side via the handle) AND
      // cache its text locally (matched on this exact unit+sentence) so the Word Book shows it offline.
      _lastHandle = res.previewHandle;
      _lastUnit = u;
      _lastContextText = contextText;
      _lastMeaning = res.meaning;
    } on ApiException catch (e) {
      if (gen != _generation) return;
      // The in-context preview is account-only, so a signed-out (or expired-session) caller 401s: that
      // gets its own "sign in — 10 free a day" prompt, not the generic failure note — the feature isn't
      // broken, it just needs an account. The user's shared daily cap (429 `quota_exhausted`) keeps its
      // own calm "daily limit" note; everything else (503 global budget, 5xx, a refused generation) is
      // the generic failure note.
      final String phase;
      if (e.isUnauthorized) {
        phase = 'login';
      } else if (e.error == 'quota_exhausted') {
        phase = 'quota';
      } else {
        phase = 'failed';
      }
      await capture.updateOverlayContextPreview(phase: phase);
    } catch (_) {
      if (gen != _generation) return;
      await capture.updateOverlayContextPreview(phase: 'failed');
    }
  }
}
