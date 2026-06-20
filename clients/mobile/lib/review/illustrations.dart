import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

/// Review rest-state illustrations, translated from DESIGN.md's CSS art into
/// Flutter: fine coffee line-work on the warm canvas with the echo motif. Static (reduced-motion safe).
///
/// IL-04 — "all caught up": a settled echo above a small stack of reviewed cards (front card checked),
/// resting on a closed book. Calm, complete.
class ReviewedStackIllustration extends StatelessWidget {
  const ReviewedStackIllustration({super.key});

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    final cardBorder = Color.alphaBlend(p.primary.withValues(alpha: 0.30), p.line);

    Widget card({bool checked = false}) => Container(
      height: 26,
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: cardBorder, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: p.primary.withValues(alpha: 0.16),
            offset: const Offset(0, 3),
            blurRadius: 6,
          ),
        ],
      ),
      child: checked
          ? Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 7),
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: Color.alphaBlend(p.success.withValues(alpha: 0.18), p.card),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.check_rounded, size: 11, color: p.success),
                ),
              ),
            )
          : null,
    );

    return SizedBox(
      width: 158,
      height: 122,
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          Positioned(
            top: 0,
            child: ObEchoMark(color: p.primary, size: 42, ringOpacities: const [0.45, 0.7, 0.95]),
          ),
          Positioned(bottom: 2, child: _BookBase(p: p, width: 92, height: 30)),
          Positioned(
            bottom: 28,
            child: SizedBox(
              width: 92,
              height: 50,
              child: Stack(
                children: [
                  Positioned(
                    bottom: 12,
                    left: 9,
                    right: 9,
                    child: Opacity(opacity: 0.72, child: card()),
                  ),
                  Positioned(
                    bottom: 6,
                    left: 4,
                    right: 4,
                    child: Opacity(opacity: 0.9, child: card()),
                  ),
                  Positioned(bottom: 0, left: 0, right: 0, child: card(checked: true)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The small closed book IL-04's card stack rests on.
class _BookBase extends StatelessWidget {
  const _BookBase({required this.p, required this.width, required this.height});
  final OnboardingPalette p;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Color.alphaBlend(p.warning.withValues(alpha: 0.05), p.card),
        border: Border(
          top: BorderSide(
            color: Color.alphaBlend(p.primary.withValues(alpha: 0.68), p.line),
            width: 1.4,
          ),
          left: BorderSide(
            color: Color.alphaBlend(p.primary.withValues(alpha: 0.68), p.line),
            width: 1.4,
          ),
          right: BorderSide(
            color: Color.alphaBlend(p.primary.withValues(alpha: 0.68), p.line),
            width: 1.4,
          ),
          bottom: BorderSide(
            color: Color.alphaBlend(p.primary.withValues(alpha: 0.68), p.line),
            width: 2.4,
          ),
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(2),
          bottomLeft: Radius.circular(2),
          topRight: Radius.circular(6),
          bottomRight: Radius.circular(6),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            decoration: BoxDecoration(
              color: Color.alphaBlend(p.primary.withValues(alpha: 0.24), p.card),
              border: Border(right: BorderSide(color: p.primary.withValues(alpha: 0.52))),
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}
