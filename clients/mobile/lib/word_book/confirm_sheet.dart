import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

/// A touch confirm bottom sheet — the phone stand-in for the macOS hover-menu/dialog destructive
/// confirms (delete word, remove sentence). Mirrors the Settings delete-account sheet's treatment:
/// a circled danger glyph, a centered title + body, then a solid-oxblood confirm over a ghost cancel.
class ConfirmSheet extends StatelessWidget {
  const ConfirmSheet({
    super.key,
    required this.p,
    required this.title,
    required this.body,
    required this.confirmLabel,
    required this.onConfirm,
  });

  final OnboardingPalette p;
  final String title;
  final String body;
  final String confirmLabel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: p.error.withValues(alpha: p.dark ? 0.14 : 0.12),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.delete_outline, size: 22, color: p.error),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: p.display(size: 19, color: p.ink),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                body,
                textAlign: TextAlign.center,
                style: p
                    .chrome(size: 12.5, weight: FontWeight.w400, color: p.ink2)
                    .copyWith(height: 1.55),
              ),
              const SizedBox(height: 18),
              _dangerBlockButton(p, confirmLabel, onPressed: onConfirm),
              const SizedBox(height: 8),
              _ghostBlockButton(p, 'Cancel', onPressed: () => Navigator.of(context).maybePop()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dangerBlockButton(OnboardingPalette p, String label, {required VoidCallback onPressed}) {
    return Material(
      color: p.error,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Container(
          constraints: const BoxConstraints(minHeight: 46),
          alignment: Alignment.center,
          child: Text(
            label,
            style: p.chrome(size: 14, weight: FontWeight.w600, color: Colors.white),
          ),
        ),
      ),
    );
  }

  Widget _ghostBlockButton(OnboardingPalette p, String label, {required VoidCallback onPressed}) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Container(
          constraints: const BoxConstraints(minHeight: 46),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: p.line),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: p.chrome(size: 14, weight: FontWeight.w500, color: p.ink),
          ),
        ),
      ),
    );
  }
}
