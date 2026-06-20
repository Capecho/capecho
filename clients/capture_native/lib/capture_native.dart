import 'dart:typed_data';

import 'package:capecho_capture_core/capecho_capture_core.dart';

import 'capture_native_platform_interface.dart';

// Re-export the shared core types so app code only needs to depend on this
// plugin to consume captures.
export 'package:capecho_capture_core/capecho_capture_core.dart';
export 'capture_native_platform_interface.dart'
    show
        CapechoShortcut,
        CaptureLifecycleEvent,
        OverlayExplainRequest,
        OverlayContextPreviewRequest,
        SavedRef;

/// The cross-platform capture facade.
///
/// The native adapter (macOS now, Windows later) emits a platform-neutral
/// [OcrSnapshot] per capture; this class runs the SHARED Dart [CaptureCascade]
/// (which composes [CaptureReconstructor]) on each one and exposes a stream of
/// [CaptureResult]s. The cascade applies the OCR→clipboard tiebreak (US-4.1)
/// identically on every platform — only the native adapter differs.
class CaptureNative {
  CaptureNative({CaptureCascade? cascade}) : _cascade = cascade ?? const CaptureCascade();

  final CaptureCascade _cascade;

  /// Optional capture diagnostic: when set, invoked with the raw [OcrSnapshot]
  /// and the reconstructed [CaptureResult] for every capture, so the app can dump
  /// them (e.g. to JSONL) for offline replay when tuning reconstruction. Null in
  /// production — a single null-check per capture, no overhead. See the macOS
  /// app's `CaptureDebug`.
  void Function(OcrSnapshot snapshot, CaptureResult result)? onDebugCapture;

  /// Reconstructed captures (the unit + sentence + context), one per capture,
  /// after the OCR→clipboard cascade. An empty result ([CaptureResult.isEmpty])
  /// means the cascade found nothing usable — the app still routes it to the normal editable
  /// [showOverlay] (with empty fields) so capture is ALWAYS completable by hand (capture issue 1).
  Stream<CaptureResult> get captures => CaptureNativePlatform.instance.snapshots.map((snapshot) {
    final result = _cascade.resolve(snapshot);
    onDebugCapture?.call(snapshot, result);
    return result;
  });

  /// The raw native snapshots, before reconstruction (useful for debugging).
  Stream<OcrSnapshot> get snapshots => CaptureNativePlatform.instance.snapshots;

  /// Triggers a one-shot capture (same path as the global hotkey). The result
  /// arrives on [captures].
  Future<void> triggerCapture() => CaptureNativePlatform.instance.triggerCapture();

  /// Matches the app-wide NATIVE appearance to the Capecho app's theme ('system' | 'light' | 'dark'), so
  /// native chrome that isn't Flutter — the menu-bar status dropdown + the capture overlay — follows the
  /// app's Light/Dark choice instead of the OS. 'system' clears the override (follow OS). Push at launch +
  /// on every Settings → Appearance change.
  Future<void> setAppearanceMode(String mode) =>
      CaptureNativePlatform.instance.setAppearanceMode(mode);

  /// Presents the native capture overlay for a reconstructed [result]. [targetLanguage] is the capture's
  /// INITIAL target (the language being learned, already script-auto-switched by the caller);
  /// [learningLanguage] is the user's CONFIGURED learning language, which the overlay uses to RE-DERIVE the
  /// target whenever the unit changes (a "set as word" promotion or an inline edit) — so attribution
  /// follows the word the user actually ends up with. [explanationLanguage] (the language a meaning is
  /// rendered IN) follows the account/device setting — there is no per-capture gloss picker. The overlay's
  /// Save writes the durable journal natively and fires [saved]. Unit + context are plain values —
  /// reconstruction already happened in the shared Dart core.
  Future<void> showOverlay(
    CaptureResult result, {
    required String targetLanguage,
    required String learningLanguage,
    required String explanationLanguage,
    bool alreadySaved = false,
    String? brightness,
    String? suggestedTargetLanguage,
    String? detectedSpanLanguage,
    double detectedSpanLanguageConfidence = 0,
    String? sourceApp,
    String? sourceTitle,
  }) {
    final unit = (result.word ?? '').trim();
    // The overlay's "Sentence" field shows the SINGLE sentence the word sits in
    // ([result.sentence], segmented at . ? ! 。！？), NOT the wider multi-sentence
    // [result.context] window. Punctuation is the robust, cross-platform sentence
    // boundary — a headline ending in "?" is cut right there with no geometry at
    // all — whereas the ~360-rune context expansion deliberately spans NEIGHBOURING
    // sentences, which is what bled an adjacent headline / sentence into the field.
    // Falls back to context only when there is no segmented sentence (e.g. a
    // clipboard / selection capture whose sentence == context anyway).
    final rawSentence = (result.sentence?.isNotEmpty ?? false) ? result.sentence! : result.context;
    // When the only text the cascade produced is the unit echoed back — a
    // bare-word capture with no surrounding sentence (e.g. the user selected just
    // the word) — leave the Sentence field empty rather than pre-filling it with
    // the word itself, which reads as noise. (Mirrors the capture metrics' "real
    // context" rule: counts only when non-empty AND not equal to the unit.)
    final sentenceText = unit.isNotEmpty && rawSentence.trim() == unit ? '' : rawSentence;
    return CaptureNativePlatform.instance.showOverlay({
      'unit': result.word ?? '',
      'context': sentenceText,
      // The enum names ('ocr' | 'selection' | 'clipboard') are exactly the
      // journal's allowed source tags, so no mapping table is needed.
      'source': result.contextSource.name,
      'targetLanguage': targetLanguage,
      // The user's CONFIGURED learning language (pre script-auto-switch). The overlay re-derives the
      // capture target from this when the unit changes (set as word / edit), so attribution tracks the
      // actual word rather than the originally-captured one.
      'learningLanguage': learningLanguage,
      // The gloss language (the language a meaning is rendered IN), from the account/device setting —
      // there is no per-capture picker. Distinct from [targetLanguage] (what is being learned).
      'explanationLanguage': explanationLanguage,
      // Whether this unit is already in the Word Book — the overlay shows an
      // "already saved" cue (bug #6). Computed by the app from the local store.
      'alreadySaved': alreadySaved,
      // The app's resolved theme brightness ('light' | 'dark') so the native overlay matches the Capecho
      // app's appearance rather than the OS (#2). Omitted (null) → the overlay follows the OS.
      'brightness': ?brightness,
      // A target-language the captured SPAN was confidently detected to be, when it
      // differs from [targetLanguage] (Phase 2). The overlay surfaces it on the target
      // chip as a one-tap switch suggestion; null → no suggestion. Never auto-applied.
      'suggestedTargetLanguage': ?suggestedTargetLanguage,
      // The captured SPAN's detected language + [0,1] confidence (from capture-time recognition). The
      // overlay caches these so it can re-evaluate the same-script suggestion when the unit changes,
      // without re-running detection. Null language → none detected.
      'detectedSpanLanguage': ?detectedSpanLanguage,
      'detectedSpanLanguageConfidence': detectedSpanLanguageConfidence,
      // Capture-source provenance: the app + window the capture came from. The overlay holds these
      // (it never edits or displays them) and writes them to the journal on Save. Omitted when null.
      'sourceApp': ?sourceApp,
      'sourceTitle': ?sourceTitle,
    });
  }

  /// Pushes a free word-layer explanation state into the currently-shown overlay (Phase 1): [phase] is
  /// `'loading'` (fetch in flight), `'ready'`, `'failed'`, `'not_a_word'`, or `'lang_unsupported'`.
  /// Driven by the app after a `/explain` fetch; a no-op natively if no overlay is up.
  ///
  /// For `'ready'`, pass [readings] as DISPLAY-READY, LAYOUT-READY blocks (computed Dart-side by
  /// capecho_app_core's `computeSenseLayout` + `pronunciationParts`):
  /// `[{pronunciations: [{label: 'US'|null, display: '/…/'}], isIdiom: bool,
  ///    pos: [{partOfSpeech: 'noun', senses: ['…'], note: '…'}]}]`,
  /// where `note` (may be '') is a form note shared by every sense, shown once at the front. Every
  /// sense is shown (no cap, no "more" hint — the overlay scrolls if tall). The native renderer is
  /// presentational: it never re-derives a cap or hard-codes an accent label.
  Future<void> updateOverlayExplanation({
    required String phase,
    List<Map<String, Object?>>? readings,
  }) {
    return CaptureNativePlatform.instance.updateOverlayExplanation({
      'phase': phase,
      'readings': ?readings,
    });
  }

  /// Pushes an in-context preview state into the overlay's ready card (E2): [phase] is `'loading'`
  /// (the metered fetch is in flight), `'ready'` (with the combined in-context gloss [meaning] — the
  /// unit's meaning here AND what the whole sentence is saying), `'quota'` (the shared daily
  /// context-explanation cap is spent), `'login'` (the account-only endpoint 401'd because the caller is
  /// signed out — a prompt to sign in for the free daily allowance), or `'failed'`. Driven by the app
  /// after a `POST /explain/context/preview`; a no-op natively unless the same word's ready card is
  /// still shown.
  Future<void> updateOverlayContextPreview({required String phase, String? meaning}) {
    return CaptureNativePlatform.instance.updateOverlayContextPreview({
      'phase': phase,
      'meaning': ?meaning,
    });
  }

  /// Fires after the native overlay durably saves a capture; the app drains the
  /// journal into the local store in response.
  Stream<SavedRef> get saved => CaptureNativePlatform.instance.saved;

  /// §14 capture-lifecycle signals from the native overlay (CEO-10) — presented / abandoned /
  /// durably saved, with the monotonic capture-time split. The app's MetricsRecorder
  /// turns these into metric events; carries durations / enums / bools only, never captured text (T8).
  Stream<CaptureLifecycleEvent> get captureLifecycle =>
      CaptureNativePlatform.instance.captureLifecycle;

  /// Whether Screen Recording permission has already been granted.
  Future<bool> hasScreenRecordingPermission() =>
      CaptureNativePlatform.instance.hasScreenRecordingPermission();

  /// Prompts for Screen Recording permission; returns the resulting state.
  Future<bool> requestScreenRecordingPermission() =>
      CaptureNativePlatform.instance.requestScreenRecordingPermission();

  /// Fires when something native (the menu-bar "Welcome" item) asks to re-show the
  /// onboarding flow, regardless of the completion flag.
  Stream<void> get showOnboardingRequests => CaptureNativePlatform.instance.showOnboardingRequests;

  /// Fires when something native asks to open a top-level surface — the menu-bar
  /// Review / Word Book / Settings items or the global ⌥R / ⌥B hotkeys. The value
  /// is the surface name (`"review"` | `"wordBook"` | `"settings"`).
  Stream<String> get showSurfaceRequests => CaptureNativePlatform.instance.showSurfaceRequests;

  /// Fires when the native overlay needs a fresh free-explanation fetch — an
  /// `Explain in ▾` gloss-language change, a unit edit, or Retry on a failed slot.
  /// The app re-runs `/explain` for the carried unit + (fixed) target + gloss
  /// language and pushes the result back via [updateOverlayExplanation].
  Stream<OverlayExplainRequest> get overlayExplainRequests =>
      CaptureNativePlatform.instance.overlayExplainRequests;

  /// Fires when the user taps the overlay's opt-in "Explain in this sentence" button (E2). The app runs
  /// the metered context preview for the carried unit + sentence and pushes the result back via
  /// [updateOverlayContextPreview].
  Stream<OverlayContextPreviewRequest> get overlayContextPreviewRequests =>
      CaptureNativePlatform.instance.overlayContextPreviewRequests;

  /// Hides the agent's window (orders it out) WITHOUT quitting. A windowed surface (Review / Word
  /// Book / Settings) calls this on Esc / Done so closing it returns to just the menu-bar agent —
  /// the surfaces are full-window routes over a hidden host, so "back" means "hide the window", not
  /// pop to a dev shell. Re-opening a surface from the menu shows the window again.
  Future<void> hideWindow() => CaptureNativePlatform.instance.hideWindow();

  /// Save an exported file (CSV or an Anki `.apkg` deck) to a user-chosen location via the native save
  /// panel, then reveal it in Finder. [suggestedName] seeds the panel's filename. Returns the saved
  /// path, or `null` if the user cancelled. The Word Book "Export" download path.
  Future<String?> saveExportFile({required String suggestedName, required Uint8List bytes}) =>
      CaptureNativePlatform.instance.saveExportFile(suggestedName: suggestedName, bytes: bytes);

  /// Asks the agent to (re)present the onboarding window — resize it to the
  /// onboarding content height and center it, then relay a [showOnboardingRequests]
  /// event so the app routes to the flow. Used when onboarding is replayed from
  /// another surface (Settings → "Get Started"); routing through native
  /// gives the replay the same window sizing as the first-run / "Welcome" path.
  Future<void> requestOnboarding() => CaptureNativePlatform.instance.requestOnboarding();

  /// Whether first-run onboarding is already complete (persisted natively).
  Future<bool> onboardingComplete() => CaptureNativePlatform.instance.onboardingComplete();

  /// Marks first-run onboarding complete (persisted natively).
  Future<void> completeOnboarding() => CaptureNativePlatform.instance.completeOnboarding();

  /// Opens System Settings → Privacy & Security → Screen Recording (US-ON.2
  /// re-enable path).
  Future<void> openScreenRecordingSettings() =>
      CaptureNativePlatform.instance.openScreenRecordingSettings();

  /// Current local global-shortcut preferences.
  Future<List<CapechoShortcut>> shortcuts() => CaptureNativePlatform.instance.shortcuts();

  /// Updates one local global shortcut and immediately re-registers it natively.
  Future<CapechoShortcut> setShortcut({
    required String action,
    required String key,
    required List<String> modifiers,
  }) => CaptureNativePlatform.instance.setShortcut(action: action, key: key, modifiers: modifiers);

  /// Durably saves a capture: the native module appends it to the fsync'd
  /// journal and resolves once it is on disk (the honest "saved" signal). The
  /// app then drains the journal into the local store.
  Future<SavedRef> saveCapture({
    required String surfaceUnit,
    required String targetLanguage,
    String? contextText,
    String? contextLanguage,
    int? spanStart,
    int? spanEnd,
    String source = 'ocr',
    String? sourceApp,
    String? sourceTitle,
    String? detectedLanguage,
    double? detectedLanguageConfidence,
    int? capturedAt,
  }) {
    return CaptureNativePlatform.instance.saveCapture({
      'surfaceUnit': surfaceUnit,
      'targetLanguage': targetLanguage,
      'contextText': contextText,
      'contextLanguage': contextLanguage,
      'spanStart': spanStart,
      'spanEnd': spanEnd,
      'source': source,
      // Capture-source provenance + detected language (all optional). The native journal records them
      // alongside the context so the stored card keeps "where I met this word".
      'sourceApp': sourceApp,
      'sourceTitle': sourceTitle,
      'detectedLanguage': detectedLanguage,
      'detectedLanguageConfidence': detectedLanguageConfidence,
      'capturedAt': capturedAt ?? DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Journal records with `seq > afterSeq` (raw maps for the local-store drain).
  Future<List<Map<String, Object?>>> journalEntries(int afterSeq) =>
      CaptureNativePlatform.instance.journalEntries(afterSeq);

  /// The stable per-device install id.
  Future<String> installId() => CaptureNativePlatform.instance.installId();

  // --- daily review reminder (US-14.1) ---------------------------------------
  // The macOS notification half of capecho_app_core's ReminderNotifications gateway — native
  // UNUserNotificationCenter, so the macOS app stays SwiftPM-pure. The tap→Review route is native.

  /// Ask macOS for notification authorization; returns whether it's (now) granted.
  Future<bool> requestNotificationPermission() =>
      CaptureNativePlatform.instance.requestNotificationPermission();

  /// (Re)arm the daily review reminder at [hour]:[minute] local, repeating, replacing any prior one.
  Future<void> scheduleDailyReminder({
    required int hour,
    required int minute,
    required String title,
    required String body,
  }) => CaptureNativePlatform.instance.scheduleDailyReminder(
    hour: hour,
    minute: minute,
    title: title,
    body: body,
  );

  /// Cancel the daily review reminder if one is armed.
  Future<void> cancelReminder() => CaptureNativePlatform.instance.cancelReminder();

  /// Post a single immediate notification (the "reminders on" confirmation) — distinct from the daily
  /// repeat, so it never replaces an armed reminder.
  Future<void> showImmediateNotification({required String title, required String body}) =>
      CaptureNativePlatform.instance.showImmediateNotification(title: title, body: body);
}
