import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

import '../onboarding_art.dart';
import 'onboarding_chrome.dart';

// ---- Step 1 — how it works ----

class HowItWorksStep extends StatelessWidget {
  const HowItWorksStep({super.key, required this.p, required this.onStart});
  final OnboardingPalette p;
  final VoidCallback onStart;
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ObWordmark(p: p, withEcho: true, size: 30),
        const SizedBox(height: 26),
        SizedBox(
          width: double.infinity,
          child: CaptureLoopVignette(p: p),
        ),
        const SizedBox(height: 28),
        WelcomeHeadline(p: p),
        const SizedBox(height: 14),
        Lede(
          'Press one shortcut while you’re reading.\nCapecho saves the word with its context, explains it with AI,\nand reminds you to review it before it fades.',
          p: p,
        ),
        const SizedBox(height: 30),
        ObPrimaryButton(p: p, label: 'Get started', onPressed: onStart),
      ],
    );
  }
}
