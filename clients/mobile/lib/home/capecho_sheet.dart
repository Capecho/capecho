import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

/// Raises [builder]'s widget as a near-full-screen warm **popover** from the bottom — Capecho mobile's
/// secondary-surface idiom now that the home is the live Review and there's no tab bar. Word Book and
/// Settings are reached from the home's corner buttons and presented here: a modal bottom sheet sized to
/// ~93% of the screen, with a rounded top, a grabber, and a close button, over a scrim that keeps a peek
/// of the dimmed Review home behind it.
///
/// Drag the sheet down, tap the scrim, or tap Close to dismiss. The surface's own pushes (the Word Book
/// detail, the export / confirm / language sub-sheets) layer above this on the root navigator, so they
/// keep working unchanged — a reminder tap pops back to the first route, revealing Review (see `app.dart`).
Future<T?> showCapechoSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  String? semanticLabel,
}) {
  final p = OnboardingPalette.of(context);
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true, // let the sheet grow past the default ~half-height cap
    // Fill the full width: override Material 3's default 640dp max-width cap, which would otherwise
    // center the sheet with side margins on a wide screen (iPad / landscape / resized window).
    constraints: const BoxConstraints(maxWidth: double.infinity),
    backgroundColor: Colors.transparent, // the shell paints its own rounded warm surface
    barrierColor: Colors.black.withValues(alpha: p.dark ? 0.52 : 0.34),
    builder: (sheetContext) => _CapechoSheetShell(
      semanticLabel: semanticLabel,
      child: Builder(builder: builder),
    ),
  );
}

/// The popover chrome: a ~93%-tall rounded warm card lifted off the bottom, with a grabber + a Close
/// affordance, the surface filling the rest. Re-resolves its palette from the live theme so an Appearance
/// flip made *inside* an open Settings popover repaints the chrome too.
class _CapechoSheetShell extends StatelessWidget {
  const _CapechoSheetShell({required this.child, this.semanticLabel});

  final Widget child;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    return FractionallySizedBox(
      heightFactor: 0.93,
      child: Container(
        decoration: BoxDecoration(
          color: p.canvas,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: p.line),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: p.dark ? 0.5 : 0.16),
              blurRadius: 30,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            _grabBar(context, p),
            // The surface (Word Book / Settings) fills the rest, padded clear of the home indicator.
            Expanded(child: SafeArea(top: false, child: child)),
          ],
        ),
      ),
    );
  }

  /// A 40px bar carrying a centered grabber pill and a top-right Close button. The whole bar is a drag
  /// handle (the modal route's own drag-to-dismiss); Close is the explicit, discoverable path.
  Widget _grabBar(BuildContext context, OnboardingPalette p) {
    return SizedBox(
      height: 40,
      child: Stack(
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: Semantics(
              label: semanticLabel,
              container: true,
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: p.ink3.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 4,
            child: IconButton(
              icon: Icon(Icons.close, size: 20, color: p.ink3),
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).maybePop(),
              constraints: const BoxConstraints(minWidth: 44, minHeight: 40),
              padding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }
}
