import 'package:flutter/material.dart';

import '../design/chrome.dart';

/// The Settings → Appearance picker: a warm three-segment control (System · Light · Dark) shared by
/// both clients. There's no single mockup for it — the mockups demonstrate every screen in *both*
/// modes rather than drawing a picker — so it's built straight from the design tokens: the active
/// segment takes the one restrained coffee accent (`primary`), the inactive segments are quiet ink on
/// a `primary-soft` track, and every color flips with the palette so it reads right in light and dark.
class AppearanceControl extends StatelessWidget {
  const AppearanceControl({
    super.key,
    required this.p,
    required this.mode,
    required this.onChanged,
  });

  final OnboardingPalette p;
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;

  static const _segments = <(ThemeMode, String)>[
    (ThemeMode.system, 'System'),
    (ThemeMode.light, 'Light'),
    (ThemeMode.dark, 'Dark'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: p.primarySoft, borderRadius: BorderRadius.circular(9)),
      child: Row(
        children: [for (final (m, label) in _segments) Expanded(child: _segment(m, label))],
      ),
    );
  }

  Widget _segment(ThemeMode m, String label) {
    final selected = m == mode;
    final seg = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(vertical: 9),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? p.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        label,
        style: p.chrome(
          size: 13,
          weight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? p.primaryFg : p.ink2,
        ),
      ),
    );
    // One merged a11y node per segment: the Text supplies the label, the wrapper adds the
    // button/selected state, and (for the inactive segments) the GestureDetector's tap action — so a
    // screen reader announces e.g. "Dark, selected" once, with the activate action preserved.
    return MergeSemantics(
      child: Semantics(
        button: !selected,
        selected: selected,
        child: selected
            ? seg
            : MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(m),
                  child: seg,
                ),
              ),
      ),
    );
  }
}
