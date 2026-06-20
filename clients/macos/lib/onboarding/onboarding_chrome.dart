import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

/// Shared chrome for the onboarding flow — the constants, test keys, and small
/// presentation primitives (the centered headline + lede, the welcome headline,
/// the vertically-centering step frame) that every step and the orchestrator
/// reuse. Lives apart from the step widgets so each step file depends on this
/// rather than on the orchestrator (`onboarding.dart`).

const onboardingMaxWidth = 720.0;
const onboardingPadding = EdgeInsets.symmetric(horizontal: 40, vertical: 44);

/// Tags the per-step content subtree so widget tests can assert its vertical
/// placement directly (step 1 is top-anchored; every later step is centered) —
/// font-independent, unlike measuring absolute pixel positions against fonts
/// that aren't bundled in the test environment.
@visibleForTesting
const Key onboardingStepContentKey = Key('onboarding-step-content');

/// Tags the scrollable step region (everything above the bottom nav bar) — keyed onto the real scroll
/// view in [OnboardingFlow] (production), and located by the layout tests, which measure step content
/// against THIS region rather than the whole window. (Not `@visibleForTesting`: the orchestrator that
/// attaches it lives in a different library, so it's a genuine cross-library production key.)
const Key onboardingScrollRegionKey = Key('onboarding-scroll-region');

class OnboardingStepFrame extends StatelessWidget {
  const OnboardingStepFrame({super.key, required this.viewportHeight, required this.child});

  final double viewportHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final content = KeyedSubtree(key: onboardingStepContentKey, child: child);

    // Every step (incl. how-it-works) centers vertically in the window; the
    // scroll view keeps a tall step reachable when the window is short.
    final minHeight = viewportHeight.isFinite
        ? (viewportHeight - onboardingPadding.vertical).clamp(0.0, double.infinity)
        : 0.0;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Center(child: content),
    );
  }
}

/// A centered headline in the editorial display serif.
class Headline extends StatelessWidget {
  const Headline(this.text, {super.key, required this.p});
  final String text;
  final OnboardingPalette p;
  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: p.display(
        size: 28,
        height: 1.15,
        weight: FontWeight.w500,
        letterSpacing: -0.015 * 28,
        color: p.ink,
      ),
    );
  }
}

/// A centered lede paragraph, held to a comfortable reading measure.
class Lede extends StatelessWidget {
  const Lede(this.text, {super.key, required this.p});
  final String text;
  final OnboardingPalette p;
  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: p.body(size: 17, height: 1.6, color: p.ink2),
      ),
    );
  }
}

/// The welcome headline — the brand sentence with `Capture` + `echo` lifted into
/// primary italic (the same gesture as the web hero). Broken into two clause
/// lines (the `echo` clause on the second) with NO em-dash, held to a wide
/// measure so the first clause sits on one line.
class WelcomeHeadline extends StatelessWidget {
  const WelcomeHeadline({super.key, required this.p});
  final OnboardingPalette p;
  @override
  Widget build(BuildContext context) {
    final emphasis = TextStyle(color: p.primary, fontStyle: FontStyle.italic);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: 'Capture', style: emphasis),
            // Hard line break before the second clause so `echo` opens line two; no em-dash.
            const TextSpan(text: ' now, '),
            TextSpan(text: 'echo', style: emphasis),
            const TextSpan(text: ' later'),
          ],
        ),
        textAlign: TextAlign.center,
        style: p.display(
          size: 28,
          height: 1.28,
          weight: FontWeight.w500,
          letterSpacing: -0.015 * 28,
          color: p.ink,
        ),
      ),
    );
  }
}

/// Split the Capture shortcut [display] into [ObKeyCombo] parts.
///
/// [withPlus] true (the big coachmark on the permission cards): each glyph is
/// joined with a '+' connector — "⌥E" → ['⌥', '+', 'E'], "⌘⇧F" → ['⌘', '+',
/// '⇧', '+', 'F']. false (the compact "⌘C then ⌥E" strip in clipboard mode):
/// glyphs sit adjacent — "⌥E" → ['⌥', 'E'], "⌘⇧F" → ['⌘', '⇧', 'F'].
List<String> captureKeyComboParts(String display, {bool withPlus = true}) {
  final parts = <String>[];
  for (var i = 0; i < display.length; i++) {
    if (withPlus && parts.isNotEmpty) parts.add('+');
    parts.add(display[i]);
  }
  return parts;
}
