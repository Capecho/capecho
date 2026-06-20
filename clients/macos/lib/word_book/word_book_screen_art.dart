import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

/// The macOS Word Book catalog's loading skeleton. The empty-catalog invite uses the shared
/// [WordBookEmptyArt] (the open, blank-book illustration) directly. Kept beside the catalog screen so
/// `word_book_screen.dart` stays focused on the catalog + its toolbar/banners.

/// Loading skeleton — masthead/toolbar already render; rows shimmer.
class WordBookSkeletonList extends StatefulWidget {
  const WordBookSkeletonList({super.key});
  @override
  State<WordBookSkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<WordBookSkeletonList> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    final widths = [0.62, 0.44, 0.7];
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: [for (var i = 0; i < 3; i++) _skelRow(p, widths[i])],
        ),
      ),
    );
  }

  Widget _skelRow(OnboardingPalette p, double unitWidth) {
    Widget bar(double w, double h) => FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: w,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (_, _) => Container(
          height: h,
          decoration: BoxDecoration(
            color: p.line.withValues(alpha: 0.45 + 0.55 * _pulse.value),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: Container(
        decoration: BoxDecoration(
          color: p.card,
          border: Border.all(color: p.line),
          borderRadius: BorderRadius.circular(11),
          boxShadow: kSoftEdgeShadow,
        ),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 30, child: bar(0.6, 12)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  bar(unitWidth.clamp(0.0, 0.5), 18),
                  const SizedBox(height: 10),
                  bar(0.82, 11),
                  const SizedBox(height: 7),
                  bar(0.6, 11),
                ],
              ),
            ),
            const SizedBox(width: 14),
            SizedBox(width: 48, child: bar(1, 11)),
          ],
        ),
      ),
    );
  }
}
