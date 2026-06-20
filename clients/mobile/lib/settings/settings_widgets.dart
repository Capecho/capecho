import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

/// Shared presentation primitives for the mobile Settings surface — the card, the touch rows + their
/// chevron, the Pro status pill, and the save-state pill. Each takes the palette + content explicitly
/// (no controller coupling), so the section builders in `settings_screen.dart` compose them and the
/// file stays focused on wiring. (The group wrapper + save-notice footer stay in the screen — they read
/// the controller's save state.)

/// A card with line border + the stacked-paper soft-edge shadow; rows are split by hairline
/// top-borders.
Widget settingsCard(OnboardingPalette p, List<Widget> rows) {
  return Container(
    decoration: BoxDecoration(
      color: p.card,
      border: Border.all(color: p.line),
      borderRadius: BorderRadius.circular(11),
      boxShadow: kSoftEdgeShadow,
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) Divider(height: 1, color: p.line),
          rows[i],
        ],
      ],
    ),
  );
}

/// A settings row: label (+ optional sub) on the left, a control on the right. ≥48px tall. [onTap] makes
/// the whole row a touch target; [disabled] greys it.
Widget settingsRow(
  OnboardingPalette p, {
  required String label,
  String? sub,
  Widget? trailing,
  VoidCallback? onTap,
  bool disabled = false,
  Color? labelColor,
}) {
  final content = Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 24),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: p.chrome(size: 14, weight: FontWeight.w500, color: labelColor ?? p.ink),
                ),
                if (sub != null) ...[
                  const SizedBox(height: 1),
                  Text(sub, style: p.chrome(size: 11.5, color: p.ink3)),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing],
        ],
      ),
    ),
  );
  final row = onTap == null ? content : InkWell(onTap: onTap, child: content);
  return disabled ? Opacity(opacity: 0.62, child: row) : row;
}

/// The rightward `›` chevron used by the tappable rows; dimmed when [disabled].
Widget settingsChevron(OnboardingPalette p, {bool disabled = false}) => Text(
  '›',
  style: p.chrome(
    size: 17,
    weight: FontWeight.w400,
    color: disabled ? p.ink3.withValues(alpha: 0.5) : p.ink3,
  ),
);

/// A Pro status pill: a tinted dot + label (Active / Free), used by the Subscription group.
Widget settingsStatusPill(OnboardingPalette p, String label, Color tone) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      color: tone.withValues(alpha: p.dark ? 0.20 : 0.13),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: p.chrome(size: 11, weight: FontWeight.w600, color: tone),
        ),
      ],
    ),
  );
}

/// The save-state pill: "Queued" (warning tone) / "Not saved" (error tone).
Widget savePill(OnboardingPalette p, SaveStatus status) {
  final queued = status == SaveStatus.queued;
  final tone = queued ? p.warning : p.error;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      color: tone.withValues(alpha: p.dark ? 0.20 : 0.13),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          queued ? 'Queued' : 'Not saved',
          style: p.chrome(size: 11, weight: FontWeight.w600, color: tone),
        ),
      ],
    ),
  );
}
