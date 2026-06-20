import 'dart:async';

import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

import 'onboarding_controller.dart';
import 'review/review_screen.dart';
import 'settings/capture_source_prefs.dart';
import 'settings/settings_controller.dart' show LoadShortcuts, SaveShortcut;
import 'settings/settings_screen.dart';
import 'surface_transitions.dart';
import 'word_book/word_book_screen.dart';
import 'word_book/word_book_widgets.dart' show ExportFileSaver;

OnboardingStep firstRunOnboardingInitialStep({
  required bool onboardingDone,
  required bool screenRecordingGranted,
}) => !onboardingDone && screenRecordingGranted
    ? OnboardingStep.permission
    : OnboardingStep.howItWorks;

/// The native surface-request routing decision (PR #28: menu-bar items + the global ⌥R / ⌥B
/// hotkeys), lifted out of the shell so it can be unit-tested directly. The shell can't be pumped
/// in a widget test because `_init` builds a live [CapechoApi] (real HTTP transport) + a file-backed
/// session with no injection seam; this function takes its collaborators explicitly instead.
///
/// Takes a [BuildContext] — not a bare `NavigatorState` — because the signed-out path shows a
/// snackbar via `ScaffoldMessenger.of(context)`, exactly as the per-surface openers do.
///
/// Behavior: ignored unless [onboardingDone] and [ready] (the shell past first-run with repo + auth
/// constructed). The target is resolved BEFORE collapsing, so an unknown [surface] is a clean no-op
/// that never pops an already-open surface to home. Otherwise any already-open surface is collapsed
/// (pop to the home route) and the resolved surface opened — so a repeated request (or a menu
/// key-equivalent firing alongside its global hotkey) never stacks duplicate routes. All three
/// surfaces open signed-out: Review shows a "sign in to review" state and Word Book the pre-login
/// banner on a 401 (each surface handles no-session itself), and Settings carries the
/// capture-permission + signed-out account surfaces. [checkPermission] / [openSystemSettings] are the
/// Settings permission seams (the repo's, null until it's built — the [ready] gate returns before
/// they're read).
void routeSurfaceRequest(
  BuildContext context,
  AuthController? auth,
  String surface, {
  required bool onboardingDone,
  required bool ready,
  required AppearanceController appearance,
  required LanguagePrefsController languagePrefs,
  required CaptureSourceController captureSource,
  Future<bool> Function()? checkPermission,
  Future<void> Function()? openSystemSettings,
  Future<void> Function()? hideWindow,
  VoidCallback? onReplayOnboarding,
  LoadShortcuts? loadShortcuts,
  SaveShortcut? saveShortcut,
  LocalWordBook? localWordBook,
  ExportFileSaver? saveExportFile,
  ProPurchaseController? purchases,
}) {
  if (!onboardingDone || !ready || auth == null) return;
  // `final` locals so the `when`-guard null-promotion holds when captured by the closure.
  final cp = checkPermission;
  final oss = openSystemSettings;
  // Closing a surface (Esc / Done) hides the agent window — there's no shell to pop back to. Null
  // (e.g. in tests) leaves the surfaces on their `Navigator.maybePop` fallback.
  final VoidCallback? onClose = hideWindow == null ? null : () => unawaited(hideWindow());
  // Resolve the target BEFORE collapsing, so an unknown surface name is a clean no-op.
  final VoidCallback? open = switch (surface) {
    'review' => () => _openReviewSurface(
      context,
      auth,
      languagePrefs: languagePrefs,
      onClose: onClose,
    ),
    'wordBook' => () => _openWordBookSurface(
      context,
      auth,
      languagePrefs: languagePrefs,
      onClose: onClose,
      localWordBook: localWordBook,
      saveExportFile: saveExportFile,
    ),
    'settings' when cp != null && oss != null => () => _openSettingsSurface(
      context,
      auth,
      appearance: appearance,
      languagePrefs: languagePrefs,
      captureSource: captureSource,
      checkPermission: cp,
      openSystemSettings: oss,
      onClose: onClose,
      onReplayOnboarding: onReplayOnboarding,
      loadShortcuts: loadShortcuts,
      saveShortcut: saveShortcut,
      saveExportFile: saveExportFile,
      purchases: purchases,
    ),
    // The capture overlay's "Sign in" button: open Settings already scrolled to the Account section's
    // sign-in controls (signed out, that section IS the SignInPanel) — same surface, focused landing.
    'signIn' when cp != null && oss != null => () => _openSettingsSurface(
      context,
      auth,
      appearance: appearance,
      languagePrefs: languagePrefs,
      captureSource: captureSource,
      checkPermission: cp,
      openSystemSettings: oss,
      onClose: onClose,
      onReplayOnboarding: onReplayOnboarding,
      loadShortcuts: loadShortcuts,
      saveShortcut: saveShortcut,
      saveExportFile: saveExportFile,
      purchases: purchases,
      scrollToAccount: true,
    ),
    _ => null,
  };
  if (open == null) return;
  Navigator.of(context).popUntil((route) => route.isFirst);
  open();
}

/// Open the Review window (US-1.1). Opens signed-out too: the Review controller shows a calm gated
/// state with INLINE sign-in (FSRS is server-authoritative, so the schedule needs an account —
/// scheduling lives in the cloud so a review streak syncs across devices), rather than blocking the
/// window from opening. Reuses the (possibly anonymous) client + the account's explanation language.
void _openReviewSurface(
  BuildContext context,
  AuthController auth, {
  required LanguagePrefsController languagePrefs,
  VoidCallback? onClose,
}) {
  // A top-level surface opened from the menu bar / a hotkey: it appears instantly (no slide) and is
  // held fixed when a child page is pushed over it — see `rootSurfaceRoute`.
  Navigator.of(context).push(
    rootSurfaceRoute(
      ReviewScreen(
        api: auth.api,
        auth: auth,
        // Signed in the account's resolved gloss language wins; signed out fall back to the device-local
        // choice (not a hardcoded English) so glosses render in the user's explanation language.
        explanationLanguage:
            auth.account?.explanationLanguage ?? languagePrefs.effectiveExplanationLanguage,
        onClose: onClose,
      ),
    ),
  );
}

/// Open the Word Book. Opens signed-out too: signed out it reads the on-device ANONYMOUS catalog via
/// [localWordBook] (no account, no server round-trip); signed in it reads `/words`. Account-synced
/// rows never appear signed-out (the `claimed` isolation in the local store). [auth] also drives the
/// signed-out "Sign in" dialog + the signed-in "Sync N words" banner.
void _openWordBookSurface(
  BuildContext context,
  AuthController auth, {
  required LanguagePrefsController languagePrefs,
  VoidCallback? onClose,
  LocalWordBook? localWordBook,
  ExportFileSaver? saveExportFile,
}) {
  // A top-level surface (root): instant, fixed under any pushed detail — see `rootSurfaceRoute`.
  Navigator.of(context).push(
    rootSurfaceRoute(
      WordBookScreen(
        api: auth.api,
        local: localWordBook,
        auth: auth,
        // Signed out the local anonymous catalog glosses in the device-local explanation language (not a
        // hardcoded English); signed in the account's resolved value wins.
        explanationLanguage:
            auth.account?.explanationLanguage ?? languagePrefs.effectiveExplanationLanguage,
        onClose: onClose,
        saveExportFile: saveExportFile,
      ),
    ),
  );
}

/// Open Settings (US-SET.1). Reachable signed-out too — the capture-permission surface and the
/// signed-out account notice both apply before sign-in, so this one isn't gated on a session.
void _openSettingsSurface(
  BuildContext context,
  AuthController auth, {
  required AppearanceController appearance,
  required LanguagePrefsController languagePrefs,
  required CaptureSourceController captureSource,
  required Future<bool> Function() checkPermission,
  required Future<void> Function() openSystemSettings,
  VoidCallback? onClose,
  VoidCallback? onReplayOnboarding,
  LoadShortcuts? loadShortcuts,
  SaveShortcut? saveShortcut,
  ExportFileSaver? saveExportFile,
  ProPurchaseController? purchases,
  bool scrollToAccount = false,
}) {
  // A top-level surface (root): instant, fixed under any pushed child (e.g. the Word Book it opens).
  Navigator.of(context).push(
    rootSurfaceRoute(
      // The signed-out Account section signs in IN PLACE via SignInPanel (the shared Apple/Google/email
      // panel) — no menu-bar "Welcome" detour. `languagePrefs` backs the signed-out Language section.
      SettingsScreen(
        auth: auth,
        appearance: appearance,
        languagePrefs: languagePrefs,
        captureSource: captureSource,
        checkPermission: checkPermission,
        openSystemSettings: openSystemSettings,
        loadShortcuts: loadShortcuts,
        saveShortcut: saveShortcut,
        onClose: onClose,
        onReplayOnboarding: onReplayOnboarding,
        saveExportFile: saveExportFile,
        purchases: purchases,
        scrollToAccount: scrollToAccount,
      ),
    ),
  );
}
