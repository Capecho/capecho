import 'dart:async';

import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'onboarding/finish_step.dart';
import 'onboarding/how_it_works_step.dart';
import 'onboarding/language_step.dart';
import 'onboarding/onboarding_chrome.dart';
import 'onboarding/onboarding_nav.dart';
import 'onboarding/permission_step.dart';
import 'onboarding/rehearsal_step.dart';
import 'onboarding_controller.dart';

export 'package:capecho_app_core/capecho_app_core.dart' show OnboardingPalette;
export 'onboarding/onboarding_chrome.dart' show onboardingScrollRegionKey, onboardingStepContentKey;

/// The default privacy-info action: open the public privacy explainer in the browser. Injected via
/// [OnboardingFlow.openPrivacyInfo] so a widget test can override it (and never hit url_launcher).
Future<void> _launchPrivacyInfo() async {
  await launchUrl(Uri.parse(CapechoLinks.privacyExplainer), mode: LaunchMode.externalApplication);
}

/// Progressive first-run onboarding (US-ON.1 + US-ON.2), macOS. Drives [OnboardingController] and
/// renders one warm step per screen; [savedSignal] is wired by the host to the capture `saved`
/// stream, and [onDone] fires after completion is persisted.
///
/// Five steps (five dots): how-it-works → language (the two axes, applied to the session HERE so the
/// first capture uses them) → Screen-Recording explainer + enable/skip → guided first capture (the real
/// ⌥E → native overlay → save, detected via the capture `saved` stream) → a terminal "finish" screen
/// that confirms the save and offers OPTIONAL sign-in/sync. A fixed bottom nav bar (← / →) rides every
/// step: Back is pure navigation; Forward mirrors the step's advance/skip path (on the terminal it is
/// "Start capturing").
///
/// The permission step has three honest branches: a preflight that already holds
/// Screen Recording shows a "ready" variant (no re-prompt); a fresh request only
/// shows the OS prompt (it returns false until the user enables it and relaunches)
/// so it goes to a *pending* screen — and "use copy & paste instead" (or a thrown
/// request) skips straight to the guided capture in clipboard mode (the rehearsal
/// carries the ⌘C instructions itself; there is no separate clipboard-mode screen).
///
/// The terminal step is sign-in only (the language axes moved to their own step ahead of capture). Email
/// works end-to-end against the live backend (native Apple/Google too); sign-in is OPTIONAL — "Start
/// capturing" finishes whether or not you signed in ("Later = local + English"). The provider panel is
/// hidden once an account session is active, so a signed-in user — e.g. one re-running the flow from
/// Settings → "Get Started" — sees a short "you're all set" confirmation with no provider buttons (a
/// fresh in-flow sign-in simply collapses the panel, with no "you're signed in" card). "Start capturing"
/// re-commits the languages (best-effort) to catch a sign-in that happened here, then finishes.
///
/// Layout, illustrations (IL-01 capture loop, IL-06 trust card, the rehearsal coachmark + glass overlay),
/// step dots, key caps, copy and the warm palette are ported from the `DESIGN.md` system +
/// `design/tokens.css` (see `onboarding_art.dart`). A fake window titlebar is intentionally NOT
/// reproduced — the live window supplies the OS chrome. The chosen languages are
/// persisted by the host via the injected `chooseLanguages` — the session capture-target language
/// applies immediately (on leaving the language step); pushing the explanation + learning language to a
/// signed-in account lands with the Settings persistence.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({
    super.key,
    required this.requestPermission,
    required this.checkPermission,
    required this.openScreenRecordingSettings,
    required this.completeOnboarding,
    required this.authController,
    required this.savedSignal,
    required this.onDone,
    required this.chooseLanguages,
    this.openPrivacyInfo = _launchPrivacyInfo,
    this.onEditCaptureShortcut,
    this.initialStep = OnboardingStep.howItWorks,
    this.initialNativeLanguage = 'en',
  });

  final Future<bool> Function() requestPermission;
  final Future<bool> Function() checkPermission;
  final Future<void> Function() openScreenRecordingSettings;
  final Future<void> Function() completeOnboarding;

  /// First screen to show. First-run normally starts with the overview, but a relaunch after macOS
  /// applies Screen Recording should resume at the capture-permission step instead of replaying page 1.
  final OnboardingStep initialStep;

  /// The native (explanation) language the language step starts on — seeded from the OS locale by the
  /// host (Lane C) so a fresh user defaults to their own language. Defaults to English in tests.
  final String initialNativeLanguage;

  /// Persists the language choice (the session capture-target language + the account when signed in).
  /// Injected by the host; see [OnboardingController.chooseLanguages].
  final Future<void> Function({
    required String explanationLanguage,
    required bool explanationFollowsLearning,
    required String learningLanguage,
  })
  chooseLanguages;

  /// Opens the privacy explainer (the permission screen's "Why does macOS call this 'Screen
  /// Recording'?" link). Defaults to launching https://capecho.com/privacy; overridable in tests.
  final Future<void> Function() openPrivacyInfo;

  /// Opens the Capture-shortcut recorder from the rehearsal step's editor (wired by the host →
  /// recorder dialog → persist → republish to [CaptureShortcutScope], which updates the coachmark +
  /// the on-card caps). Null hides the "Change…" affordance (tests / a host that doesn't wire it).
  final VoidCallback? onEditCaptureShortcut;

  /// Drives the terminal sign-in step. Owned by the host so the session
  /// outlives onboarding (a returning user is restored before the flow even runs).
  final AuthController authController;

  /// Fires once per durable capture save (the host forwards `capture.saved`).
  final Stream<void> savedSignal;

  /// Called after the flow finishes and completion is persisted.
  final VoidCallback onDone;

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  late final OnboardingController _c;
  StreamSubscription<void>? _savedSub;

  // Carousel transition bookkeeping: the last rendered step's ordinal + the direction of the most
  // recent change. `_forward` only flips when the step actually changes (not on every controller
  // notify), so a mid-slide rebuild — e.g. a busy/committing tick — never reverses an in-flight slide.
  late int _lastStepIndex;
  bool _forward = true;

  @override
  void initState() {
    super.initState();
    _c = OnboardingController(
      requestPermission: widget.requestPermission,
      checkPermission: widget.checkPermission,
      openSettings: widget.openScreenRecordingSettings,
      complete: widget.completeOnboarding,
      initialStep: widget.initialStep,
      chooseLanguages: widget.chooseLanguages,
      initialNativeLanguage: widget.initialNativeLanguage,
    );
    _lastStepIndex = _c.step.index;
    _savedSub = widget.savedSignal.listen((_) => _c.onFirstCaptureSaved());
  }

  @override
  void dispose() {
    _savedSub?.cancel();
    _c.dispose();
    super.dispose();
  }

  /// "Start capturing": commit the chosen languages (best-effort persist + finish), then exit.
  Future<void> _startCapturing() async {
    await _c.commitLanguages();
    if (mounted) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    return Scaffold(
      backgroundColor: p.canvas,
      body: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          // Update the slide direction only when the step actually changes (a no-op rebuild keeps the
          // current direction, so an in-flight slide never flips).
          final idx = _c.step.index;
          if (idx != _lastStepIndex) {
            _forward = idx > _lastStepIndex;
            _lastStepIndex = idx;
          }
          // Honor reduced-motion: collapse the slide to an instant swap.
          final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
          // The flow is a vertical stack: the scrollable, vertically-centered step region fills the
          // window above a fixed bottom nav bar (← / →) that rides every step.
          return Column(
            children: [
              Expanded(
                // Clip the off-screen page during the carousel slide.
                child: ClipRect(
                  child: LayoutBuilder(
                    builder: (context, viewport) {
                      // Steps slide like a carousel — the new page enters from the travel direction and
                      // the old exits the opposite way — instead of a hard cut. Each page fills the
                      // viewport so a ±100% slide fully clears it; vertical centering lives inside.
                      return AnimatedSwitcher(
                        duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 340),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) {
                          final incoming =
                              (child.key as ValueKey<OnboardingStep>?)?.value == _c.step;
                          final dir = _forward ? 1.0 : -1.0;
                          // Incoming enters from the travel side; outgoing exits the opposite side.
                          final begin = Offset(incoming ? dir : -dir, 0);
                          return SlideTransition(
                            position: Tween(begin: begin, end: Offset.zero).animate(animation),
                            child: child,
                          );
                        },
                        child: KeyedSubtree(
                          key: ValueKey(_c.step),
                          // The scroll view spans the full width so the scrollbar rides the real window
                          // edge; the content is centered + measure-capped inside. Scrollable so a
                          // short/resized window never clips a tall step.
                          child: SingleChildScrollView(
                            key: onboardingScrollRegionKey,
                            child: Center(
                              child: ConstrainedBox(
                                // Window padding (40 h) lives INSIDE this cap, so the content
                                // column is maxWidth - 80 (~640) — wide enough to fill the window.
                                constraints: const BoxConstraints(maxWidth: onboardingMaxWidth),
                                child: Padding(
                                  padding: onboardingPadding,
                                  child: OnboardingStepFrame(
                                    viewportHeight: viewport.maxHeight,
                                    child: _screenFor(_c.step, p),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              OnboardingNav(
                p: p,
                canBack: _c.canGoBack,
                canForward: _c.canGoForward,
                forwardTooltip: _forwardTooltip(_c.step),
                onBack: _c.goBack,
                // The terminal step's forward IS "Start capturing" (commit + finish); every other step
                // delegates to the controller's forward (advance / skip).
                onForward: _c.step == OnboardingStep.signIn ? _startCapturing : _c.goForward,
                dotIndex: _dotIndexFor(_c.step),
                dotCount: 5,
              ),
            ],
          );
        },
      ),
    );
  }

  /// The → arrow's tooltip, named for what advancing actually does on each step.
  String _forwardTooltip(OnboardingStep step) {
    switch (step) {
      case OnboardingStep.howItWorks:
        return 'Get started';
      case OnboardingStep.language:
        return 'Continue';
      case OnboardingStep.permission:
        return _c.permissionGranted ? 'Continue' : 'Skip — use copy & paste';
      case OnboardingStep.permissionPending:
        return 'Skip — use copy & paste';
      case OnboardingStep.rehearsal:
        return 'Skip for now';
      case OnboardingStep.signIn:
        return 'Start capturing';
    }
  }

  /// The bottom-bar dot to light for [step] (5 dots; the pending branch shares the permission dot).
  int _dotIndexFor(OnboardingStep step) {
    switch (step) {
      case OnboardingStep.howItWorks:
        return 0;
      case OnboardingStep.language:
        return 1;
      case OnboardingStep.permission:
      case OnboardingStep.permissionPending:
        return 2;
      case OnboardingStep.rehearsal:
        return 3;
      case OnboardingStep.signIn:
        return 4;
    }
  }

  Widget _screenFor(OnboardingStep step, OnboardingPalette p) {
    switch (step) {
      case OnboardingStep.howItWorks:
        return HowItWorksStep(p: p, onStart: _c.getStarted);
      case OnboardingStep.language:
        return LanguageStep(p: p, controller: _c, onContinue: _c.continueFromLanguage);
      case OnboardingStep.permission:
        return PermissionStep(
          p: p,
          busy: _c.busy,
          alreadyGranted: _c.permissionGranted,
          onEnable: _c.enableScreenRecording,
          onSkip: _c.useClipboardCapture,
          onOpenPrivacy: widget.openPrivacyInfo,
        );
      case OnboardingStep.permissionPending:
        return PermissionPendingStep(
          p: p,
          busy: _c.busy,
          notDetectedYet: _c.recheckedNotGranted,
          onRecheck: _c.recheckPermission,
          onOpenSettings: _c.openScreenRecordingSettings,
          onSkip: _c.useClipboardCapture,
        );
      case OnboardingStep.rehearsal:
        return RehearsalStep(
          p: p,
          ocrArmed: _c.ocrArmed,
          onSkip: _c.skipRehearsal,
          onEditShortcut: widget.onEditCaptureShortcut,
        );
      case OnboardingStep.signIn:
        return FinishStep(
          p: p,
          auth: widget.authController,
          controller: _c,
          onStart: _startCapturing,
        );
    }
  }
}
