import 'dart:typed_data';

import 'package:capecho_capture_core/capecho_capture_core.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'capture_native_method_channel.dart';

/// The platform boundary for the native capture adapter.
///
/// Native (Swift on macOS, C++ on Windows later) produces a platform-neutral
/// [OcrSnapshot]; reconstruction into a `CaptureResult` happens in shared Dart
/// (see [CaptureNative]), not here.
abstract class CaptureNativePlatform extends PlatformInterface {
  CaptureNativePlatform() : super(token: _token);

  static final Object _token = Object();

  static CaptureNativePlatform _instance = MethodChannelCaptureNative();

  static CaptureNativePlatform get instance => _instance;

  static set instance(CaptureNativePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// A broadcast stream of raw OCR snapshots, emitted whenever a capture
  /// completes (via the global hotkey or [triggerCapture]).
  Stream<OcrSnapshot> get snapshots {
    throw UnimplementedError('snapshots has not been implemented.');
  }

  /// Triggers a one-shot capture; the result arrives on [snapshots].
  Future<void> triggerCapture() {
    throw UnimplementedError('triggerCapture() has not been implemented.');
  }

  /// Sets the app-wide native appearance to match the Capecho app's theme ('system' | 'light' | 'dark') —
  /// so native chrome that isn't Flutter (the menu-bar status dropdown, the capture overlay) follows the
  /// app's Light/Dark choice rather than the OS. 'system' clears the override (follow the OS). The host
  /// pushes it at launch + on every Settings → Appearance change.
  Future<void> setAppearanceMode(String mode) {
    throw UnimplementedError('setAppearanceMode() has not been implemented.');
  }

  /// Presents the native capture overlay for a reconstructed capture. The
  /// overlay (native AppKit, never Flutter — DES-3) owns correction + the
  /// `Explain in ▾` gloss-language choice (the target language is fixed); its
  /// Save appends to the durable journal natively and then fires [saved] so the
  /// app drains the local store.
  Future<void> showOverlay(Map<String, Object?> capture) {
    throw UnimplementedError('showOverlay() has not been implemented.');
  }

  /// Pushes a free-explanation state into the currently-shown overlay: a `phase` of `'loading'` /
  /// `'ready'` (+ `readings`) / `'failed'` / `'not_a_word'` / `'lang_unsupported'`. A no-op natively
  /// if no overlay is present.
  Future<void> updateOverlayExplanation(Map<String, Object?> explanation) {
    throw UnimplementedError('updateOverlayExplanation() has not been implemented.');
  }

  /// Pushes an in-context preview state into the overlay's ready card (E2): a `phase` of `'loading'` /
  /// `'ready'` (+ `meaning`) / `'quota'` / `'login'` / `'failed'`. A no-op natively unless the same
  /// word's ready card is still shown.
  Future<void> updateOverlayContextPreview(Map<String, Object?> update) {
    throw UnimplementedError('updateOverlayContextPreview() has not been implemented.');
  }

  /// Fires after the native overlay durably saves a capture (the receipt). The
  /// app listens to this to drain the journal into the local store — the save
  /// itself already happened natively (fsync), so this is the projection signal.
  Stream<SavedRef> get saved {
    throw UnimplementedError('saved has not been implemented.');
  }

  /// Fires on each native capture-lifecycle transition (overlay presented / abandoned-without-save /
  /// durably saved) — the §14 instrumentation (CEO-10). The app's MetricsRecorder
  /// maps these to metric events. Carries durations / enums / bools ONLY, never captured text (T8).
  Stream<CaptureLifecycleEvent> get captureLifecycle {
    throw UnimplementedError('captureLifecycle has not been implemented.');
  }

  /// Whether Screen Recording permission has already been granted.
  Future<bool> hasScreenRecordingPermission() {
    throw UnimplementedError('hasScreenRecordingPermission() has not been implemented.');
  }

  /// Prompts for Screen Recording permission. Returns the resulting state.
  Future<bool> requestScreenRecordingPermission() {
    throw UnimplementedError('requestScreenRecordingPermission() has not been implemented.');
  }

  /// Fires when something native asks the app to (re-)show the onboarding flow
  /// — e.g. the menu-bar "Welcome" item — regardless of the completion flag. The
  /// app routes to [OnboardingFlow] on each event.
  Stream<void> get showOnboardingRequests {
    throw UnimplementedError('showOnboardingRequests has not been implemented.');
  }

  /// Fires when something native asks the app to open a top-level surface: the
  /// menu-bar Review / Word Book / Settings items, or the global ⌥R / ⌥B hotkeys.
  /// The payload is the surface name (`"review"` | `"wordBook"` | `"settings"`);
  /// the app navigates to it (collapsing any already-open surface first).
  Stream<String> get showSurfaceRequests {
    throw UnimplementedError('showSurfaceRequests has not been implemented.');
  }

  /// Fires when the native overlay needs a fresh free-explanation fetch: an
  /// `Explain in ▾` gloss-language change, a unit edit, or a Retry on a failed
  /// slot. The app re-runs `/explain` for the carried unit + (fixed) target +
  /// gloss language and pushes the result back via [updateOverlayExplanation].
  /// Without this, a gloss-language change would leave the slot blank and Retry
  /// would be inert.
  Stream<OverlayExplainRequest> get overlayExplainRequests {
    throw UnimplementedError('overlayExplainRequests has not been implemented.');
  }

  /// Fires when the user taps the overlay's opt-in "Explain in this sentence" button (E2). The app runs
  /// the metered context preview for the carried unit + sentence and pushes the result back via
  /// [updateOverlayContextPreview]. §178: opt-in — never emitted automatically.
  Stream<OverlayContextPreviewRequest> get overlayContextPreviewRequests {
    throw UnimplementedError('overlayContextPreviewRequests has not been implemented.');
  }

  /// Hides the agent's window (orders it out; does not quit). Called when a windowed surface is
  /// dismissed so the app returns to the menu-bar agent rather than a window with no way back.
  Future<void> hideWindow() {
    throw UnimplementedError('hideWindow() has not been implemented.');
  }

  /// Asks the native agent to (re)present the onboarding window (resize + center)
  /// and relay a [showOnboardingRequests] event. See [MethodChannelCaptureNative].
  Future<void> requestOnboarding() {
    throw UnimplementedError('requestOnboarding() has not been implemented.');
  }

  /// Whether the first-run onboarding has been completed (persisted natively,
  /// shared with the agent shell's launch-window decision).
  Future<bool> onboardingComplete() {
    throw UnimplementedError('onboardingComplete() has not been implemented.');
  }

  /// Marks first-run onboarding complete (persisted natively).
  Future<void> completeOnboarding() {
    throw UnimplementedError('completeOnboarding() has not been implemented.');
  }

  /// Opens System Settings → Privacy & Security → Screen Recording (the
  /// re-enable path from onboarding's clipboard-mode branch, US-ON.2).
  Future<void> openScreenRecordingSettings() {
    throw UnimplementedError('openScreenRecordingSettings() has not been implemented.');
  }

  /// Current local global-shortcut preferences (`capture`, `review`, `wordBook`).
  Future<List<CapechoShortcut>> shortcuts() {
    throw UnimplementedError('shortcuts() has not been implemented.');
  }

  /// Updates one local global shortcut and immediately re-registers it natively.
  Future<CapechoShortcut> setShortcut({
    required String action,
    required String key,
    required List<String> modifiers,
  }) {
    throw UnimplementedError('setShortcut() has not been implemented.');
  }

  /// Durably append one capture to the native journal (fsync) and return the
  /// receipt. This is the PERSISTENCE boundary — it resolves only once the write
  /// is on disk, so the caller can show the "saved" ink-dot honestly.
  Future<SavedRef> saveCapture(Map<String, Object?> capture) {
    throw UnimplementedError('saveCapture() has not been implemented.');
  }

  /// Save [bytes] to a user-chosen file via the native save panel (`NSSavePanel` on macOS) + reveal it
  /// in Finder. [suggestedName] seeds the panel's filename (its extension constrains the type when the
  /// OS knows it). Returns the saved path, or `null` if the user cancelled. The Word Book export
  /// download path (CSV / Anki `.apkg`).
  Future<String?> saveExportFile({required String suggestedName, required Uint8List bytes}) {
    throw UnimplementedError('saveExportFile() has not been implemented.');
  }

  /// Read journal records with `seq > afterSeq` (drives the local-store drain).
  Future<List<Map<String, Object?>>> journalEntries(int afterSeq) {
    throw UnimplementedError('journalEntries() has not been implemented.');
  }

  /// The stable per-device install id (persisted natively).
  Future<String> installId() {
    throw UnimplementedError('installId() has not been implemented.');
  }

  // --- daily review reminder (US-14.1) ---------------------------------------
  // The macOS half of capecho_app_core's ReminderNotifications gateway: native UNUserNotificationCenter
  // scheduling, so the macOS app stays SwiftPM-pure (no flutter_local_notifications). The shared
  // ReminderScheduler owns the policy; these are just the OS plumbing. The tap→Review route is handled
  // natively (the notification posts the same `capecho.showSurface` "review" the menu-bar item does).

  /// Ask macOS for notification authorization; returns whether it's (now) granted.
  Future<bool> requestNotificationPermission() {
    throw UnimplementedError('requestNotificationPermission() has not been implemented.');
  }

  /// (Re)arm the daily review reminder at [hour]:[minute] local, repeating, replacing any prior one.
  Future<void> scheduleDailyReminder({
    required int hour,
    required int minute,
    required String title,
    required String body,
  }) {
    throw UnimplementedError('scheduleDailyReminder() has not been implemented.');
  }

  /// Cancel the daily review reminder if one is armed.
  Future<void> cancelReminder() {
    throw UnimplementedError('cancelReminder() has not been implemented.');
  }

  /// Post a single immediate notification (the "reminders on" confirmation), distinct from the daily one.
  Future<void> showImmediateNotification({required String title, required String body}) {
    throw UnimplementedError('showImmediateNotification() has not been implemented.');
  }
}

/// One local global shortcut preference.
class CapechoShortcut {
  const CapechoShortcut({
    required this.action,
    required this.title,
    required this.key,
    required this.modifiers,
    required this.display,
  });

  final String action;
  final String title;
  final String key;
  final List<String> modifiers;
  final String display;

  factory CapechoShortcut.fromMap(Map<dynamic, dynamic> map) => CapechoShortcut(
    action: map['action'] as String,
    title: map['title'] as String,
    key: map['key'] as String,
    modifiers: (map['modifiers'] as List).cast<String>(),
    display: map['display'] as String,
  );

  CapechoShortcut copyWith({String? key, List<String>? modifiers, String? display}) =>
      CapechoShortcut(
        action: action,
        title: title,
        key: key ?? this.key,
        modifiers: modifiers ?? this.modifiers,
        display: display ?? this.display,
      );
}

/// A request from the native overlay to (re)fetch the free explanation for the
/// shown [unit] — emitted on an `Explain in ▾` gloss-language change, a unit edit,
/// or a Retry on a failed slot. Carries the FIXED [targetLanguage] (the language
/// being learned, which gates the allowlist + cache) and the chosen
/// [explanationLanguage] (the gloss language a meaning is rendered IN). The app
/// responds by re-running `/explain` and pushing the result via
/// `updateOverlayExplanation`.
class OverlayExplainRequest {
  const OverlayExplainRequest({
    required this.unit,
    required this.targetLanguage,
    required this.explanationLanguage,
  });

  final String unit;
  final String targetLanguage;
  final String explanationLanguage;

  factory OverlayExplainRequest.fromMap(Map<dynamic, dynamic> map) => OverlayExplainRequest(
    unit: map['unit'] as String? ?? '',
    targetLanguage: map['targetLanguage'] as String? ?? '',
    explanationLanguage: map['explanationLanguage'] as String? ?? '',
  );
}

/// A request from the native overlay to explain the shown [unit] IN its [contextText] sentence (E2) —
/// emitted when the user taps the opt-in "Explain in this sentence" button. The app responds by running
/// the metered `POST /explain/context/preview` and pushing the result back via
/// `updateOverlayContextPreview`. The sentence rides along so the gloss matches what a later Save would
/// persist (the backend's adoption guard requires the sentences to match).
class OverlayContextPreviewRequest {
  const OverlayContextPreviewRequest({
    required this.unit,
    required this.contextText,
    required this.targetLanguage,
    required this.explanationLanguage,
    this.contextLanguage,
    this.spanStart,
    this.spanEnd,
  });

  final String unit;
  final String contextText;
  final String targetLanguage;
  final String explanationLanguage;

  /// The TEXT's language, present only when its script made it certain natively
  /// (`UnitLanguage.scriptCertainLanguage`); null = unknown — the backend then says
  /// "the text below" and must NOT default the label to [targetLanguage] (the unit's
  /// language and the sentence's genuinely diverge, e.g. a zh unit in an English article).
  final String? contextLanguage;

  /// UTF-16 `[start, end)` of [unit] within [contextText], present only when the unit
  /// occurs exactly once (`UnitSpanResolver` on the CURRENT text) — lets the backend mark
  /// the asked-about occurrence in the prompt. Null = ambiguous/absent: the prompt falls
  /// back to naming the unit.
  final int? spanStart;
  final int? spanEnd;

  factory OverlayContextPreviewRequest.fromMap(Map<dynamic, dynamic> map) =>
      OverlayContextPreviewRequest(
        unit: map['unit'] as String? ?? '',
        contextText: map['contextText'] as String? ?? '',
        targetLanguage: map['targetLanguage'] as String? ?? '',
        explanationLanguage: map['explanationLanguage'] as String? ?? '',
        contextLanguage: map['contextLanguage'] as String?,
        spanStart: map['spanStart'] as int?,
        spanEnd: map['spanEnd'] as int?,
      );
}

/// The durable-write receipt from [CaptureNativePlatform.saveCapture]: the
/// per-save UUID (== the local store's context row id) and the journal sequence
/// (the drain cursor key).
class SavedRef {
  const SavedRef({required this.clientRowId, required this.seq});

  final String clientRowId;
  final int seq;

  factory SavedRef.fromMap(Map<dynamic, dynamic> map) =>
      SavedRef(clientRowId: map['clientRowId'] as String, seq: (map['seq'] as num).toInt());
}

/// A §14 capture-lifecycle signal from the native overlay (CEO-10), mapped to a metric event by the
/// app's MetricsRecorder. [phase] is `presented` | `abandoned` | `completed` (native) or
/// `failed` (emitted Dart-side on a cascade error). Optional fields are populated per the phase's
/// contract: durations (ms, monotonic) / `source` / `hasContext` / `langOverride` / `clientRowId`
/// (completed) / `errorKind` (failed). Never carries unit or context text (T8).
class CaptureLifecycleEvent {
  const CaptureLifecycleEvent({
    required this.phase,
    this.selToPanelMs,
    this.panelToSaveMs,
    this.totalMs,
    this.source,
    this.hasContext,
    this.langOverride,
    this.clientRowId,
    this.errorKind,
  });

  final String phase;
  final int? selToPanelMs;
  final int? panelToSaveMs;
  final int? totalMs;
  final String? source;
  final bool? hasContext;
  final bool? langOverride;
  final String? clientRowId;
  final String? errorKind;

  factory CaptureLifecycleEvent.fromMap(Map<dynamic, dynamic> map) => CaptureLifecycleEvent(
    phase: map['phase'] as String,
    selToPanelMs: (map['selToPanelMs'] as num?)?.toInt(),
    panelToSaveMs: (map['panelToSaveMs'] as num?)?.toInt(),
    totalMs: (map['totalMs'] as num?)?.toInt(),
    source: map['source'] as String?,
    hasContext: map['hasContext'] as bool?,
    langOverride: map['langOverride'] as bool?,
    clientRowId: map['clientRowId'] as String?,
    errorKind: map['errorKind'] as String?,
  );
}
