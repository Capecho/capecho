import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'design/chrome.dart';

/// Top inset reserved on macOS for the immersive title bar's floating traffic-light strip. The native
/// window runs the warm canvas edge to edge (transparent, full-size-content title bar), so the
/// red/amber/green cluster floats over the top-left of the canvas. Rather than crowd the header's
/// leading control (back chevron / echo mark) up beside the lights on one line — where the small mark
/// reads as squeezed between the coloured lights and the title — we drop the whole header row BELOW
/// the lights: the top ~strip stays clean draggable canvas for the lights, the header sits under it on
/// its own line at the normal left inset. Zero on every other platform (mobile has no title bar).
const double _kMacTitleBarStrip = 22;

/// True only in the macOS desktop client, where the immersive title bar floats traffic lights over
/// the canvas. Uses [defaultTargetPlatform] (not `dart:io`) so this file stays web-safe.
bool get _macImmersiveTitleBar => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// The top inset a surface must reserve for the immersive title bar's floating traffic lights when it
/// renders its OWN top chrome instead of a [SurfaceHeader] — e.g. the Review card's progress header,
/// which can't stack the full header without overflowing the window's min height. Zero on every other
/// platform. [SurfaceHeader] already bakes this in; callers only need it for bespoke top chrome.
double get macTitleBarInset => _macImmersiveTitleBar ? _kMacTitleBarStrip : 0.0;

/// The one header every windowed surface wears (Review · Word Book · Settings · their nested
/// detail / recently-deleted pages), so the top of every page reads identically: a full-bleed bar
/// on the warm canvas with a hairline bottom rule.
///
/// The leading slot is the navigation anchor and switches on depth:
/// - **Root** page (opened straight from the menu bar / a hotkey) → the echo mark, no back button
///   (dismiss is Esc / the window close button).
/// - **Nested** page (pushed on top of another surface) → a **back button** (chevron + [backLabel])
///   wired to [onBack]; the echo mark moves to the right so it's still present.
///
/// [title] is the surface's name in the editorial serif (e.g. "Review", "Settings"); [trailing] is
/// the right-aligned slot for per-surface affordances or a small meta label. The bar itself never
/// scrolls — it's a sibling above the surface's scrolling body, fixed in place.
class SurfaceHeader extends StatelessWidget {
  const SurfaceHeader({
    super.key,
    required this.p,
    this.onBack,
    this.backLabel = 'Back',
    this.title,
    this.trailing,
    this.showBrand = true,
  });

  final OnboardingPalette p;

  /// When non-null this is a nested page: the leading slot shows a back button wired to this, and
  /// the echo mark (if [showBrand]) moves to the right. Null → a root page (mark leads, no back).
  final VoidCallback? onBack;

  /// The label beside the back chevron — usually the parent page's name ("Word Book"), else "Back".
  final String backLabel;

  /// The surface name, rendered in the editorial serif right after the leading anchor.
  final String? title;

  /// A right-aligned affordance / meta slot (search + export, "N due today", a "Review" label, …).
  final Widget? trailing;

  /// Whether to render the echo mark at all (left on root, right on nested). A page that supplies its
  /// own brand treatment can turn this off.
  final bool showBrand;

  @override
  Widget build(BuildContext context) {
    final nested = onBack != null;
    final brand = ObEchoMark(color: p.primary, size: 20);
    // Tighter left inset when the chevron leads, so the back button sits where the eye expects it.
    final leftInset = nested ? 12.0 : 20.0;
    // On macOS, drop the row below the floating traffic lights (see [_kMacTitleBarStrip]) so the
    // leading control sits clear of them on its own line, at the normal left inset.
    final topInset = _macImmersiveTitleBar ? 13.0 + _kMacTitleBarStrip : 13.0;
    return Container(
      padding: EdgeInsets.fromLTRB(leftInset, topInset, 20, 13),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: Row(
        children: [
          if (nested)
            _BackButton(p: p, label: backLabel, onPressed: onBack!)
          else if (showBrand)
            brand,
          // The title claims the row's slack so [trailing] sits flush right. (A
          // Flexible title beside a Spacer split the free space 50/50 — a short
          // title used only part of its half, stranding the trailing meta
          // mid-row instead of right-aligned.)
          if (title != null)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(left: nested ? 12 : 14),
                child: Text(
                  title!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: p.display(size: 20, color: p.ink),
                ),
              ),
            )
          else
            const Spacer(),
          ?trailing,
          // On a nested page the brand rides on the right so the back button can own the left.
          if (nested && showBrand) ...[const SizedBox(width: 14), brand],
        ],
      ),
    );
  }
}

/// The shared top-left back affordance: a chevron + label, quiet ink, generous hit target.
class _BackButton extends StatelessWidget {
  const _BackButton({required this.p, required this.label, required this.onPressed});
  final OnboardingPalette p;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(Icons.chevron_left, size: 18, color: p.ink2),
      label: Text(
        label,
        style: p.chrome(size: 13, weight: FontWeight.w500, color: p.ink2),
      ),
      style: TextButton.styleFrom(
        foregroundColor: p.ink2,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
