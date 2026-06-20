import 'dart:typed_data';

import 'package:flutter/material.dart';

/// macOS-only Word Book extras that can't live in the shared app-core view: the native save-panel
/// `ExportFileSaver` seam and the pre-login dashed-row border painter. The shared presentational
/// helpers (the memory meter, the POS chip, the in-sentence highlight, the terse date) come from
/// `capecho_app_core`'s `word_book_view`.

/// Saves exported bytes to a user-chosen file (the native save panel) and reveals it in Finder,
/// returning the saved path or `null` if cancelled. Injected from the app shell (the macOS client's
/// `capture_native` save panel) so the Word Book stays decoupled from the native plugin — null in
/// hosts/tests without one. Signature matches `CaptureNative.saveExportFile`.
typedef ExportFileSaver =
    Future<String?> Function({required String suggestedName, required Uint8List bytes});

/// Strokes a dashed rounded-rect outline — Flutter's `Border` only does solid, so pre-login rows draw
/// their dashed edge here as a foreground painter.
class DashedRRectPainter extends CustomPainter {
  DashedRRectPainter({required this.color, this.radius = 11});
  final Color color;
  final double radius;

  static const double _dash = 5, _gap = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    ).deflate(0.5); // keep the 1px stroke inside the bounds
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final src = Path()..addRRect(rrect);
    for (final metric in src.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final next = (d + _dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(d, next), paint);
        d = next + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(DashedRRectPainter old) => old.color != color || old.radius != radius;
}
