import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

import '../backend/distribution.dart';
import '../capture_shortcut_scope.dart';
import '../onboarding_controller.dart';
import 'onboarding_chrome.dart';

// ---- Terminal step — post-capture finish: optional sync (US-ON.1 / US-SY.1) ----

/// The terminal screen after the guided first capture: OPTIONAL sign-in/sync. The provider buttons hide
/// once an account session is active — a signed-in user, incl. one re-running the flow, sees a short
/// "you're all set" confirmation instead. The two language axes live in their own step BEFORE capture
/// (so the first capture uses them), leaving this screen with one job.
/// "Start capturing" re-commits the languages (best-effort — this catches a sign-in that happened here)
/// and finishes onboarding, whether or not you signed in (US-ON.1: "Later = local + English" is simply
/// not signing in here). A fresh in-flow sign-in collapses the provider panel in place; there is no
/// "you're signed in" interstitial.
class FinishStep extends StatefulWidget {
  const FinishStep({
    super.key,
    required this.p,
    required this.auth,
    required this.controller,
    required this.onStart,
  });
  final OnboardingPalette p;
  final AuthController auth;
  final OnboardingController controller;
  final Future<void> Function() onStart;
  @override
  State<FinishStep> createState() => _FinishState();
}

class _FinishState extends State<FinishStep> {
  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final captureDisplay = CaptureShortcutScope.displayOf(context);
    // Rebuilds on BOTH the auth session (to swap the sign-in panel for the "all set" confirmation) and
    // the controller (to spin "Start capturing" while the terminal commit is in flight).
    return AnimatedBuilder(
      animation: Listenable.merge([widget.auth, widget.controller]),
      builder: (context, _) {
        final signedIn = widget.auth.isSignedIn;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (!signedIn) ...[
              Headline('Sync your Word Book', p: p),
              const SizedBox(height: 12),
              Lede(
                'Sign in to back up your captures and review them on your phone — '
                'or skip, and everything stays on your device.',
                p: p,
              ),
              const SizedBox(height: 22),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: SignInPanel(p: p, auth: widget.auth, appleAvailable: isMacAppStoreBuild()),
              ),
              const SizedBox(height: 24),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Container(height: 1, color: p.line),
              ),
              const SizedBox(height: 22),
            ] else ...[
              Headline('You’re all set', p: p),
              const SizedBox(height: 12),
              Lede(
                'Your Word Book will sync to your phone. Press $captureDisplay in any '
                'app to keep a word.',
                p: p,
              ),
              const SizedBox(height: 22),
            ],
            ObPrimaryButton(
              p: p,
              label: 'Start capturing',
              busy: widget.controller.committing,
              onPressed: widget.onStart,
            ),
            if (!signedIn) ...[
              const SizedBox(height: 8),
              Text(
                'Your captures stay on this device until you sign in.',
                style: p.chrome(size: 11.5, color: p.ink3),
              ),
            ],
          ],
        );
      },
    );
  }
}
