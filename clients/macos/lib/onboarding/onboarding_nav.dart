import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

/// The persistent bottom nav that rides every onboarding step: a Back arrow (left, hidden but
/// space-reserving on the first step), the step dots dead-centre, and a Forward arrow (right). The dots
/// live here — fixed chrome that updates as you move — rather than at the top of each page, so they sit
/// with the arrows instead of sliding away with the carousel. The arrows mirror each step's advance/skip
/// path, forming a complete navigation spine alongside the per-step CTA; Back is pure navigation.
class OnboardingNav extends StatelessWidget {
  const OnboardingNav({
    super.key,
    required this.p,
    required this.canBack,
    required this.canForward,
    required this.forwardTooltip,
    required this.onBack,
    required this.onForward,
    required this.dotIndex,
    required this.dotCount,
  });
  final OnboardingPalette p;
  final bool canBack;
  final bool canForward;
  final String forwardTooltip;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final int dotIndex;
  final int dotCount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 20),
      child: Row(
        children: [
          // Reserve the Back arrow's footprint on the first step (where it's hidden) so the dots stay
          // dead-centre and the Forward arrow keeps its right-edge position — the bar never jumps.
          Visibility(
            visible: canBack,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: NavArrow(
              p: p,
              icon: Icons.arrow_back_rounded,
              tooltip: 'Back',
              enabled: canBack,
              onTap: onBack,
            ),
          ),
          // The dots sit in the symmetric middle (equal-width arrows flank it), so they're truly centred.
          Expanded(
            child: Center(
              child: ObStepDots(p: p, count: dotCount, current: dotIndex),
            ),
          ),
          NavArrow(
            p: p,
            icon: Icons.arrow_forward_rounded,
            tooltip: forwardTooltip,
            enabled: canForward,
            onTap: onForward,
          ),
        ],
      ),
    );
  }
}

/// A single round nav arrow — a warm-glass circle with a chevron, dimmed + non-interactive when
/// [enabled] is false. Carries a [tooltip] (also its a11y label) naming what the arrow does on this step.
class NavArrow extends StatelessWidget {
  const NavArrow({
    super.key,
    required this.p,
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });
  final OnboardingPalette p;
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final circle = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: p.card,
        shape: BoxShape.circle,
        border: Border.all(color: p.line),
      ),
      child: Icon(icon, size: 19, color: enabled ? p.ink2 : p.ink3.withValues(alpha: 0.5)),
    );
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            onTap: enabled ? onTap : null,
            child: Opacity(opacity: enabled ? 1 : 0.55, child: circle),
          ),
        ),
      ),
    );
  }
}
