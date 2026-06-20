import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

import '../onboarding_controller.dart';
import 'onboarding_chrome.dart';

// ---- Step 2 — language (set BEFORE capture, so the first capture uses it; US-ON.1 §9) ----

/// The language step, split out of the old terminal screen and moved ahead of the capture steps so the
/// learning/explanation choice is applied to the session before the guided first capture. Just the
/// headline + the two-axis [LanguageStrip] + Continue — sign-in is now its own terminal step.
class LanguageStep extends StatelessWidget {
  const LanguageStep({
    super.key,
    required this.p,
    required this.controller,
    required this.onContinue,
  });
  final OnboardingPalette p;
  final OnboardingController controller;
  final VoidCallback onContinue;
  @override
  Widget build(BuildContext context) {
    // Rebuild as the axes change so the picker reflects each pick.
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Headline('Which language are you learning?', p: p),
            const SizedBox(height: 12),
            Lede(
              'Pick the language you’re learning, \n and your own language for explanations.',
              p: p,
            ),
            const SizedBox(height: 26),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: LanguageStrip(p: p, controller: controller),
            ),
            const SizedBox(height: 30),
            ObPrimaryButton(p: p, label: 'Continue', onPressed: onContinue),
          ],
        );
      },
    );
  }
}

/// A COMPACT two-axis language picker for the language step. The two axes — explanation/native (how
/// meanings are glossed) and the current learning/target language (the default for future captures,
/// never guessed) — read + write the [OnboardingController]; "Continue" applies them to the session
/// (so the guided first capture uses them) and the terminal "Start capturing" re-commits to the account.
class LanguageStrip extends StatelessWidget {
  const LanguageStrip({super.key, required this.p, required this.controller});
  final OnboardingPalette p;
  final OnboardingController controller;

  // The native (explanation) picker shows app-core's shared [explanationLanguages] (all nine
  // backend-supported gloss languages); the learning (capture-target) picker shows app-core's shared
  // [learningLanguages] (only the generation-ENABLED targets — a target outside the registry's enabled
  // set gets no explanations at all, so offering it here would onboard the user into a broken core
  // loop). Both lists are owned in app-core; extend the learning set only when a new language passes
  // its paid eval gate.

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _axisRow(
          accent: p.primary,
          glyph: ObEchoMark(color: p.primary, size: 13),
          label: 'I’m learning',
          field: _learnField(),
        ),
        const SizedBox(height: 10),
        _axisRow(
          accent: p.success,
          glyph: Icon(Icons.subject, size: 13, color: p.success),
          label: 'My language',
          field: _explainField(),
        ),
        const SizedBox(height: 8),
        Text(
          'Change any time in Settings; '
          'existing words re-fetch in the new language.',
          style: p.chrome(size: 11, weight: FontWeight.w400, color: p.ink3).copyWith(height: 1.4),
        ),
      ],
    );
  }

  /// One labelled axis row: an accent eyebrow on the left, the popup field filling the rest.
  Widget _axisRow({
    required Color accent,
    required Widget glyph,
    required String label,
    required Widget field,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 132,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              glyph,
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: p.chrome(size: 13, weight: FontWeight.w600, color: accent),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: field),
      ],
    );
  }

  // AXIS B — current learning / target language (primary accent).
  Widget _learnField() {
    final current = controller.learningLanguage;
    return PopupMenuButton<String>(
      tooltip: 'Choose learning language',
      position: PopupMenuPosition.under,
      padding: EdgeInsets.zero,
      onSelected: controller.setLearningLanguage,
      itemBuilder: (_) => [
        for (final code in learningLanguages)
          PopupMenuItem<String>(
            value: code,
            child: Row(
              children: [
                Expanded(
                  child: Text(langName(code), style: p.chrome(size: 13, color: p.ink)),
                ),
                if (code == current) Icon(Icons.check, size: 14, color: p.primary),
              ],
            ),
          ),
      ],
      child: _fieldBox(accent: p.primary, fill: p.primarySoft, label: langName(current)),
    );
  }

  // AXIS A — native (explanation) language (success accent): a direct pick (Lane C — the "Same as
  // learning" immersion sentinel is gone).
  Widget _explainField() {
    final current = controller.explanationLanguage;
    return PopupMenuButton<String>(
      tooltip: 'Choose your native language',
      position: PopupMenuPosition.under,
      padding: EdgeInsets.zero,
      onSelected: controller.setExplanationLanguage,
      itemBuilder: (_) => [
        for (final code in explanationLanguages)
          PopupMenuItem<String>(
            value: code,
            child: Row(
              children: [
                Expanded(
                  child: Text(langName(code), style: p.chrome(size: 13, color: p.ink)),
                ),
                if (code == current) Icon(Icons.check, size: 14, color: p.success),
              ],
            ),
          ),
      ],
      child: _fieldBox(
        accent: p.success,
        fill: p.success.withValues(alpha: 0.12),
        label: langName(current),
      ),
    );
  }

  Widget _fieldBox({required Color accent, required Color fill, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: p.chrome(size: 13.5, weight: FontWeight.w500, color: p.ink),
            ),
          ),
          Icon(Icons.expand_more, size: 17, color: accent),
        ],
      ),
    );
  }
}
