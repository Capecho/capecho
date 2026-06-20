import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

import '../onboarding_art.dart';

// ---- Step 4 — guided first capture ----

class RehearsalStep extends StatelessWidget {
  const RehearsalStep({
    super.key,
    required this.p,
    required this.ocrArmed,
    required this.onSkip,
    this.onEditShortcut,
  });
  final OnboardingPalette p;
  final bool ocrArmed;
  final VoidCallback onSkip;
  final VoidCallback? onEditShortcut;
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        RehearsalSurface(p: p, ocrArmed: ocrArmed, onEditShortcut: onEditShortcut),
        const SizedBox(height: 16),
        ObQuietButton(p: p, label: 'I’ll try this later', onPressed: onSkip),
      ],
    );
  }
}
