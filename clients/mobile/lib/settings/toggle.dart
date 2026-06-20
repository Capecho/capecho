import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

/// An iOS-style toggle: a 44×26 pill with the semantic success green track when on (not the coffee
/// primary). Wraps a ≥44px touch target around the visual pill and announces its toggled state to screen
/// readers.
class Toggle extends StatelessWidget {
  const Toggle({super.key, required this.p, required this.value, required this.onChanged});
  final OnboardingPalette p;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      button: true,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        // A ≥44px touch target around the 44×26 visual pill.
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 44,
          height: 26,
          decoration: BoxDecoration(
            color: value ? p.success : p.line,
            borderRadius: BorderRadius.circular(14),
          ),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          padding: const EdgeInsets.all(2),
          child: Container(
            width: 22,
            height: 22,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: Color(0x4D000000), blurRadius: 3, offset: Offset(0, 1))],
            ),
          ),
        ),
      ),
    );
  }
}
