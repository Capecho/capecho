import 'dart:async';

import 'package:flutter/foundation.dart';

/// The discrete onboarding screens, in forward order.
///
/// [language] sits BEFORE the capture steps so the learning/explanation choice is applied to the
/// session before the guided first capture — the very next ⌥E captures in the chosen target.
///
/// [permissionPending] is the honest macOS in-between: `CGRequestScreenCaptureAccess` returns `false`
/// the instant it shows the system prompt — the grant only applies after the user toggles Capecho on in
/// System Settings and relaunches. So a `false` request is NOT a decline; it lands here (Settings link +
/// re-check). "Use copy & paste instead" skips straight to the [rehearsal] in clipboard mode — there is
/// no separate clipboard-mode screen (it was a third, redundant Screen-Recording prompt; the rehearsal
/// itself carries the ⌘C instructions when OCR isn't armed).
enum OnboardingStep { howItWorks, language, permission, permissionPending, rehearsal, signIn }

/// Default no-op for [OnboardingController.chooseLanguages] / `OnboardingFlow.chooseLanguages`. The
/// language choice is best-effort, so a host that doesn't wire persistence (e.g. a widget test) still
/// finishes onboarding cleanly.
Future<void> _noopChooseLanguages({
  required String explanationLanguage,
  required bool explanationFollowsLearning,
  required String learningLanguage,
}) async {}

/// Pure step/branch logic, decoupled from the widgets ([OnboardingFlow] + its step screens) so it is
/// unit-testable. The platform effects (request permission, open settings, persist completion) are
/// injected callbacks.
class OnboardingController extends ChangeNotifier {
  OnboardingController({
    required this.requestPermission,
    required this.checkPermission,
    required this.openSettings,
    required this.complete,
    OnboardingStep initialStep = OnboardingStep.howItWorks,
    this.chooseLanguages = _noopChooseLanguages,
    String initialNativeLanguage = 'en',
  }) : _step = initialStep,
       _explanationLanguage = initialNativeLanguage {
    if (_step == OnboardingStep.permission) {
      unawaited(_refreshPermissionStatus());
    }
  }

  /// Prompts for Screen Recording (`CGRequestScreenCaptureAccess`). Returns
  /// `true` only if access is *already* held; on a fresh ask it shows the
  /// system prompt and returns `false` immediately (the grant needs a relaunch).
  final Future<bool> Function() requestPermission;

  /// Non-prompting preflight (`CGPreflightScreenCaptureAccess`): the current
  /// status, used to detect an already-granted Mac and to re-check after the
  /// user enables it in System Settings.
  final Future<bool> Function() checkPermission;

  final Future<void> Function() openSettings;
  final Future<void> Function() complete;

  /// Persists the language choice (US-ON.1 §9). Injected so the controller stays pure +
  /// unit-testable; the host applies it to the session capture-target language and (when signed in)
  /// the account. Best-effort — a failure here never traps the user in onboarding.
  final Future<void> Function({
    required String explanationLanguage,
    required bool explanationFollowsLearning,
    required String learningLanguage,
  })
  chooseLanguages;

  OnboardingStep _step;
  OnboardingStep get step => _step;

  bool _busy = false;
  bool get busy => _busy;

  /// True once OCR was armed (Screen Recording granted). False in clipboard
  /// mode (skipped or declined). Drives the rehearsal instructions — ⌥E alone
  /// vs ⌘C-then-⌥E (CR #2).
  bool _ocrArmed = false;
  bool get ocrArmed => _ocrArmed;

  /// Whether a preflight says Screen Recording is already on. Drives the
  /// permission screen's "already enabled" variant (no need to re-prompt).
  bool _permissionGranted = false;
  bool get permissionGranted => _permissionGranted;

  /// True once a re-check on the pending screen came back still-not-granted, so
  /// the UI can surface the "you may need to relaunch Capecho" hint.
  bool _recheckedNotGranted = false;
  bool get recheckedNotGranted => _recheckedNotGranted;

  // ---- Language (the two axes; its own step ahead of capture; US-ON.1 §9) --
  // `_explanationLanguage` is the NATIVE language meanings are glossed in — seeded from the OS locale
  // (initialNativeLanguage) so it defaults to the user's own language; `_learningLanguage` is the
  // default target language for future captures (never guessed). "Skip" keeps these seeds; "Start
  // capturing" commits whatever is chosen.
  String _explanationLanguage;
  String get explanationLanguage => _explanationLanguage;
  // Lane C: the "Same as learning" immersion option is gone — native language is a direct pick. The
  // flag stays false (vestigial; the host still persists it for wire compatibility).
  bool _explanationFollowsLearning = false;
  bool get explanationFollowsLearning => _explanationFollowsLearning;
  String _learningLanguage = 'en';
  String get learningLanguage => _learningLanguage;

  void setExplanationLanguage(String code) {
    if (!_explanationFollowsLearning && code == _explanationLanguage) return;
    _explanationLanguage = code;
    _explanationFollowsLearning = false;
    notifyListeners();
  }

  void setLearningLanguage(String code) {
    if (code == _learningLanguage) return;
    _learningLanguage = code;
    notifyListeners();
  }

  // The terminal commit is latched twice: `_committing` drives the spinner while the persist is in
  // flight (reset once it settles, so a still-mounted flow never spins forever); `_committed` is the
  // one-shot terminal guard so the choice can't be committed twice (idempotent even standalone —
  // independent of the `_busy` the permission flow uses).
  bool _committing = false;
  bool get committing => _committing;
  bool _committed = false;

  bool _disposed = false;
  bool _persisted = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _go(OnboardingStep next) {
    if (_disposed || _step == next) return;
    _step = next;
    // Persist once the user reaches the end of the REQUIRED flow — the guided first
    // capture is done by the time the terminal sign-in/finish screen shows, and
    // sign-in itself is optional (US-ON.1: "Later = local + English"). So closing the
    // window there still counts as done (CR #10); the explicit finish() is idempotent.
    if (next == OnboardingStep.signIn && !_persisted) {
      _persisted = true;
      complete();
    }
    notifyListeners();
  }

  /// "Get started": move to the language step (the first decision — what you're learning).
  void getStarted() => _go(OnboardingStep.language);

  /// Leave the language step: apply the chosen languages to the session (so the rehearsal capture, two
  /// steps on, uses them) and advance to the permission step. Best-effort + fire-and-forget; the host
  /// persists device-local synchronously (the next ⌥E picks it up), so navigation never waits on it.
  void continueFromLanguage() {
    if (_step != OnboardingStep.language) return;
    unawaited(applyLanguageChoice());
    _enterPermission();
  }

  void _enterPermission() {
    _go(OnboardingStep.permission);
    // Preflight (no prompt) so a Mac that already granted Screen Recording sees
    // the "already on" variant instead of being asked again. Fire-and-forget;
    // the screen flips reactively when it resolves.
    unawaited(_refreshPermissionStatus());
  }

  /// Apply the chosen languages to the live session — device-local always, the account too when already
  /// signed in. Best-effort + idempotent: called on leaving the language step (so the next capture uses
  /// the choice) AND re-run by [commitLanguages] at the terminal step (to catch a first-run sign-in that
  /// happened after the language step). A failure here never blocks navigation.
  Future<void> applyLanguageChoice() async {
    try {
      await chooseLanguages(
        explanationLanguage: _explanationLanguage,
        explanationFollowsLearning: _explanationFollowsLearning,
        learningLanguage: _learningLanguage,
      );
    } catch (_) {
      // Best-effort: a persistence failure must not trap the user mid-flow.
    }
  }

  // ---- Bottom navigation (the ← / → arrows on every step) ------------------
  // Back is pure navigation (no side effects, no un-persist); forward mirrors the step's primary
  // "advance/skip" path so the arrows form a complete spine alongside each step's CTA.

  void _set(OnboardingStep step) {
    if (_disposed || _step == step) return;
    _step = step;
    notifyListeners();
  }

  /// Whether the ← arrow is active (every step has a previous one except the first; blocked while the
  /// terminal commit is in flight).
  bool get canGoBack => _step != OnboardingStep.howItWorks && !_committing;

  /// Whether the → arrow is active (blocked only while a permission request or the terminal commit is in
  /// flight). On the terminal step forward means "Start capturing" — the widget routes it to the commit.
  bool get canGoForward => !_busy && !_committing;

  /// ← : step back one screen. `permissionPending` and `rehearsal` both fold back to `permission` (their
  /// shared parent decision); `signIn` folds back to `rehearsal`.
  void goBack() {
    if (_disposed || _committing) return;
    switch (_step) {
      case OnboardingStep.howItWorks:
        return;
      case OnboardingStep.language:
        _set(OnboardingStep.howItWorks);
      case OnboardingStep.permission:
        _set(OnboardingStep.language);
      case OnboardingStep.permissionPending:
        _set(OnboardingStep.permission);
      case OnboardingStep.rehearsal:
        _set(OnboardingStep.permission);
      case OnboardingStep.signIn:
        _set(OnboardingStep.rehearsal);
    }
  }

  /// → : advance via the step's non-destructive default. On `permission`/`permissionPending` that is the
  /// clipboard-capture skip (an already-granted Mac arms OCR instead); on `rehearsal` it skips the
  /// guided capture. The terminal `signIn` forward is handled by the widget (it commits + finishes).
  void goForward() {
    if (_disposed || _busy || _committing) return;
    switch (_step) {
      case OnboardingStep.howItWorks:
        getStarted();
      case OnboardingStep.language:
        continueFromLanguage();
      case OnboardingStep.permission:
        if (_permissionGranted) {
          unawaited(enableScreenRecording()); // granted → arms OCR → rehearsal (no prompt)
        } else {
          useClipboardCapture();
        }
      case OnboardingStep.permissionPending:
        useClipboardCapture();
      case OnboardingStep.rehearsal:
        skipRehearsal();
      case OnboardingStep.signIn:
        return;
    }
  }

  Future<void> _refreshPermissionStatus() async {
    bool granted;
    try {
      granted = await checkPermission();
    } catch (_) {
      granted = false;
    }
    if (_disposed || granted == _permissionGranted) return;
    _permissionGranted = granted;
    notifyListeners();
  }

  /// "Allow on-device capture". If permission is already held, arm OCR and go
  /// straight to rehearsal. Otherwise prompt: a `true` result arms OCR; a
  /// `false` does NOT mean declined (the OS just showed its prompt and the
  /// grant needs a relaunch) → the pending screen, never the clipboard wall.
  /// A thrown call is the only path that still falls back to clipboard (CR #8).
  Future<void> enableScreenRecording() async {
    if (_busy || _disposed) return;
    if (_permissionGranted) {
      _ocrArmed = true;
      _go(OnboardingStep.rehearsal);
      return;
    }
    _busy = true;
    notifyListeners();
    bool granted;
    var threw = false;
    try {
      granted = await requestPermission();
    } catch (_) {
      granted = false;
      threw = true; // a thrown permission call counts as not-granted
    } finally {
      _busy = false;
    }
    if (_disposed) return;
    if (granted) {
      _permissionGranted = true;
      _ocrArmed = true;
      _go(OnboardingStep.rehearsal);
    } else if (threw) {
      // A thrown request can't reach the OS prompt — fall straight back to clipboard capture (CR #8).
      _ocrArmed = false;
      _go(OnboardingStep.rehearsal);
    } else {
      // Prompt shown but not yet applied — wait for the user to enable it.
      _ocrArmed = false;
      _go(OnboardingStep.permissionPending);
    }
  }

  /// On the pending screen: re-preflight after the user says they enabled it.
  /// Granted → arm OCR → rehearsal; still not granted → stay put and surface
  /// the relaunch hint (the grant often only applies on the next launch).
  Future<void> recheckPermission() async {
    if (_busy || _disposed) return;
    _busy = true;
    _recheckedNotGranted = false;
    notifyListeners();
    bool granted;
    try {
      granted = await checkPermission();
    } catch (_) {
      granted = false;
    } finally {
      _busy = false;
    }
    if (_disposed) return;
    _permissionGranted = granted;
    if (granted) {
      _ocrArmed = true;
      _go(OnboardingStep.rehearsal);
    } else {
      _recheckedNotGranted = true;
      notifyListeners();
    }
  }

  /// "Use copy & paste instead": skip Screen Recording and go straight to the guided first capture in
  /// the supported clipboard mode (US-ON.2). There is no separate clipboard-mode interstitial — it was a
  /// third, redundant Screen-Recording prompt; the rehearsal carries the ⌘C-then-⌥E instructions itself
  /// when [ocrArmed] is false.
  void useClipboardCapture() {
    _ocrArmed = false;
    _go(OnboardingStep.rehearsal);
  }

  Future<void> openScreenRecordingSettings() => openSettings();

  /// The real first capture landed (observed via the `saved` stream) — advance
  /// past the rehearsal to the terminal sign-in/finish screen.
  void onFirstCaptureSaved() {
    if (_step == OnboardingStep.rehearsal) _go(OnboardingStep.signIn);
  }

  /// Escape hatch so a user who can't capture right now isn't stuck.
  void skipRehearsal() {
    if (_step == OnboardingStep.rehearsal) _go(OnboardingStep.signIn);
  }

  /// Persist completion (idempotent with the on-`signIn` write in `_go`).
  Future<void> finish() => complete();

  /// "Start capturing" (terminal finish step): re-commit the chosen languages, then finish onboarding.
  /// The languages were already applied to the session when the user left the language step; this
  /// re-applies them so a sign-in that happened HERE (the terminal step) also pushes them to the new
  /// account — [applyLanguageChoice] is idempotent device-local and only reaches the account when signed
  /// in. One-shot (the `_committed` latch makes a second call a no-op) and re-entrancy-safe (the
  /// `_committing` guard blocks a tap while the persist is in flight); best-effort throughout — a
  /// failure doesn't trap the user (the choice still applies to the session; Settings can re-sync).
  Future<void> commitLanguages() async {
    if (_step != OnboardingStep.signIn || _committing || _committed || _disposed) {
      return;
    }
    _committing = true;
    notifyListeners();
    await applyLanguageChoice(); // best-effort (swallows its own errors)
    _committing = false; // stop the spinner so a still-mounted flow doesn't spin forever
    _committed = true; // terminal: the choice is committed (success or best-effort), never re-run
    if (_disposed) return;
    notifyListeners();
    await finish();
  }
}
