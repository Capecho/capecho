import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

/// Shared presentation primitives for the macOS Settings surface — the sectioned card, the
/// title/desc-left + control-right rows, the language selectbox, the status/save pills, the callout
/// notice, and the danger button. Each takes the palette + content explicitly (no controller
/// coupling), so the section builders in `settings_screen.dart` compose them and the file stays
/// focused on wiring rather than chrome.

/// A titled section card: an uppercase header over [rows] separated by hairlines.
Widget settingsSection(OnboardingPalette p, String title, List<Widget> rows) {
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
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                title.toUpperCase(),
                style: p.chrome(
                  size: 12,
                  weight: FontWeight.w600,
                  color: p.ink2,
                  letterSpacing: 0.96,
                ),
              ),
            ],
          ),
        ),
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) Divider(height: 1, color: p.line),
          rows[i],
        ],
      ],
    ),
  );
}

/// A title/description-left, control-right setting row. [disabled] dims it.
Widget settingRow(
  OnboardingPalette p, {
  String? title,
  String? desc,
  Widget? control,
  bool descMuted = false,
  bool disabled = false,
  Color? titleColor,
}) {
  final row = Padding(
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title != null)
                Text(
                  title,
                  style: p.chrome(size: 14, weight: FontWeight.w500, color: titleColor ?? p.ink),
                ),
              if (desc != null) ...[
                if (title != null) const SizedBox(height: 3),
                Text(
                  desc,
                  style: p
                      .chrome(size: 13, weight: FontWeight.w400, color: descMuted ? p.ink3 : p.ink2)
                      .copyWith(height: 1.45),
                ),
              ],
            ],
          ),
        ),
        if (control != null) ...[const SizedBox(width: 14), control],
      ],
    ),
  );
  return disabled ? Opacity(opacity: 0.55, child: row) : row;
}

/// A stacked row: title/desc, then a full-width control. Used by Appearance,
/// whose segmented theme control is too wide to sit inline at the row's right.
Widget settingStackRow(
  OnboardingPalette p, {
  required String title,
  required String desc,
  required Widget control,
}) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: p.chrome(size: 14, weight: FontWeight.w500, color: p.ink),
        ),
        const SizedBox(height: 3),
        Text(
          desc,
          style: p.chrome(size: 13, weight: FontWeight.w400, color: p.ink2).copyWith(height: 1.45),
        ),
        const SizedBox(height: 12),
        Align(alignment: Alignment.centerLeft, child: control),
      ],
    ),
  );
}

/// A native-style popup button (value + chevron) that opens a language menu over
/// [codes].
Widget settingsSelectbox(
  OnboardingPalette p, {
  required List<String> codes,
  required String label,
  required ValueChanged<String> onSelect,
  String tooltip = 'Choose language',
}) {
  return PopupMenuButton<String>(
    tooltip: tooltip,
    onSelected: onSelect,
    itemBuilder: (context) => [
      for (final code in codes)
        PopupMenuItem<String>(
          value: code,
          child: Text(langName(code), style: p.chrome(size: 13, color: p.ink)),
        ),
    ],
    // Fixed width so the inner Expanded has a bounded width — the control slot itself is unbounded
    // (shrink-wrap).
    child: SizedBox(
      width: 184,
      child: Container(
        padding: const EdgeInsets.fromLTRB(13, 7, 10, 7),
        decoration: BoxDecoration(
          color: p.card,
          border: Border.all(color: p.line),
          borderRadius: BorderRadius.circular(8),
          boxShadow: [BoxShadow(color: p.edge, offset: const Offset(2, 2))],
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: p.chrome(size: 14, weight: FontWeight.w500, color: p.ink),
              ),
            ),
            const SizedBox(width: 8),
            Text('▾', style: p.chrome(size: 11, color: p.ink3)),
          ],
        ),
      ),
    ),
  );
}

/// A status pill: a tinted dot + label, used for the capture-permission + Pro states.
Widget settingsPill(OnboardingPalette p, String label, Color tone) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
    decoration: BoxDecoration(
      color: tone.withValues(alpha: 0.13),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: p.chrome(size: 12, weight: FontWeight.w600, color: tone),
        ),
      ],
    ),
  );
}

/// A callout box: a toned icon + [body], on the primary-soft wash (or a [background] override) — the
/// info/warning/error section notes.
Widget settingsNotice(
  OnboardingPalette p, {
  required Color tone,
  required Widget body,
  IconData icon = Icons.info_outline,
  Color? background,
}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      // The base notice uses the coffee `--app-primary-soft` wash; info notices tint by tone.
      color: background ?? tone.withValues(alpha: p.dark ? 0.18 : 0.10),
      border: Border.all(color: p.line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 17, color: tone),
        const SizedBox(width: 10),
        Expanded(child: body),
      ],
    ),
  );
}

/// A save-state pill: "Queued" (warning tone) or "Not saved" (error tone).
Widget savePill(OnboardingPalette p, SaveStatus status) {
  final queued = status == SaveStatus.queued;
  final tone = queued ? p.warning : p.error;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: tone.withValues(alpha: p.dark ? 0.20 : 0.12),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          queued ? 'Queued' : 'Not saved',
          style: p.chrome(size: 12, weight: FontWeight.w600, color: tone),
        ),
      ],
    ),
  );
}

/// An outlined oxblood (NOT coffee-primary) destructive button.
Widget dangerButton(OnboardingPalette p, String label, {required VoidCallback onPressed}) {
  return OutlinedButton(
    style: OutlinedButton.styleFrom(
      foregroundColor: p.error,
      side: BorderSide(color: p.error),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      textStyle: p.chrome(size: 14, weight: FontWeight.w600),
    ),
    onPressed: onPressed,
    child: Text(label),
  );
}
