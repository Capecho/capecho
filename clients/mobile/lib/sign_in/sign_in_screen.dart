import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

/// The signed-out landing surface (US-ON.3 / IL-03): a brand-forward welcome — the settled echo + the
/// "Capecho." wordmark + the tagline — over the shared [SignInPanel] (Apple on iOS / Google / email).
/// First-run onboarding + reminder setup are a follow-up; this is the minimal "bring your words to this
/// phone" entry.
class SignInScreen extends StatelessWidget {
  const SignInScreen({super.key, required this.auth});

  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    return Scaffold(
      backgroundColor: p.canvas,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(26, 36, 26, 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // IL-03 welcome hero: the settled echo mark above the wordmark.
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ObEchoMark(color: p.primary, size: 40, ringOpacities: const [0.7, 0.85, 1]),
                        const SizedBox(height: 14),
                        Text.rich(
                          TextSpan(
                            text: 'Capecho',
                            style: p.display(
                              size: 38,
                              height: 1,
                              weight: FontWeight.w600,
                              letterSpacing: -0.02 * 38,
                              color: p.ink,
                            ),
                            children: [
                              TextSpan(
                                text: '.',
                                style: TextStyle(color: p.primary),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 30),
                  Text(
                    'Capture the new words\nyou’re reading — and echo\nthem back before they fade.',
                    textAlign: TextAlign.center,
                    style: p.display(size: 25, height: 1.15, color: p.ink),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 300),
                      // Mobile is review-only at MVP, so the copy uses the accurate sync framing rather
                      // than a "capture it here, too" line.
                      child: Text(
                        'Review each word right before you’d forget it — in the sentence you met it. '
                        'Everything you capture on your Mac arrives here to review.',
                        textAlign: TextAlign.center,
                        style: p.body(size: 14, height: 1.55, color: p.ink2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 34),
                  Center(
                    child: SignInPanel(p: p, auth: auth),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Your Word Book syncs across every device you sign in on.',
                    textAlign: TextAlign.center,
                    style: p.chrome(size: 12, color: p.ink3, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
