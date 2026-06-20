import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

/// Loading skeleton — the "Syncing your settings…" working-echo card + shimmer rows,
/// shown while Settings fetches the account. The `Capecho.` masthead lives in the fixed SurfaceHeader
/// above this.
class SettingsSkeleton extends StatefulWidget {
  const SettingsSkeleton({super.key});
  @override
  State<SettingsSkeleton> createState() => _SettingsSkeletonState();
}

class _SettingsSkeletonState extends State<SettingsSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    // The `Capecho.` masthead now lives in the fixed SurfaceHeader above; the skeleton is just the
    // syncing card + shimmer rows.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(p, [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 8),
            child: Row(
              children: [
                ObEchoLoader(color: p.primary, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Syncing your settings…',
                  style: p.chrome(size: 13, weight: FontWeight.w400, color: p.ink2),
                ),
              ],
            ),
          ),
          _skelRow(p, avatar: false),
        ]),
        const SizedBox(height: 16),
        _card(p, [_skelRow(p, avatar: false)]),
        const SizedBox(height: 16),
        _card(p, [_skelRow(p, avatar: true)]),
      ],
    );
  }

  Widget _card(OnboardingPalette p, List<Widget> children) => Container(
    decoration: BoxDecoration(
      color: p.card,
      border: Border.all(color: p.line),
      borderRadius: BorderRadius.circular(11),
      boxShadow: kSoftEdgeShadow,
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
  );

  Widget _bar(OnboardingPalette p, double widthFactor, double height) => FractionallySizedBox(
    alignment: Alignment.centerLeft,
    widthFactor: widthFactor,
    child: AnimatedBuilder(
      animation: _pulse,
      builder: (_, _) => Container(
        height: height,
        decoration: BoxDecoration(
          color: p.line.withValues(alpha: 0.45 + 0.55 * _pulse.value),
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    ),
  );

  Widget _skelRow(OnboardingPalette p, {required bool avatar}) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
    child: Row(
      children: [
        if (avatar) ...[
          AnimatedBuilder(
            animation: _pulse,
            builder: (_, _) => Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: p.line.withValues(alpha: 0.45 + 0.55 * _pulse.value),
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [_bar(p, 0.5, 11), const SizedBox(height: 8), _bar(p, 0.7, 11)],
          ),
        ),
        const SizedBox(width: 14),
        SizedBox(width: 92, child: _bar(p, 1, 25)),
      ],
    ),
  );
}
