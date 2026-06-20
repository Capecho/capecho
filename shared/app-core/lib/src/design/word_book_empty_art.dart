import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'chrome.dart';

/// The empty-Word-Book illustration, shared by both clients (macOS catalog + mobile Word Book /
/// "nothing captured yet" Review). An **open book with blank pages** — the brand's warm-library motif,
/// but OPEN to empty cream pages with only a faint dotted writing-guide, so it reads as *empty, waiting
/// for the first word* (a closed book read as "a book", not "empty"). The echo mark settles, centered,
/// above the spine — the first word will echo into these pages.
///
/// Self-contained + palette-driven (reads [OnboardingPalette.of]); static, so reduced-motion safe. The
/// book covers carry their own warm tan (a leather/cloth cover reads on either canvas); the pages derive
/// from the palette so they sit right in light + dark.
class WordBookEmptyArt extends StatelessWidget {
  const WordBookEmptyArt({super.key, this.width = 200});

  /// The illustration width; height follows the 200×168 artboard (×0.84).
  final double width;

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    return SizedBox(
      width: width,
      height: width * 168 / 200,
      child: CustomPaint(painter: _EmptyBookPainter(p)),
    );
  }
}

class _EmptyBookPainter extends CustomPainter {
  _EmptyBookPainter(this.p);
  final OnboardingPalette p;

  // The artboard the paths below are authored in (the approved prototype). The canvas is scaled to the
  // widget size, so every coordinate/stroke is in these 200×168 units.
  static const double _vbW = 200, _vbH = 168;

  Color _mix(Color a, Color b, double t) => Color.alphaBlend(a.withValues(alpha: t), b);

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..scale(size.width / _vbW, size.height / _vbH);

    _paintEcho(canvas);
    _paintBook(canvas);

    canvas.restore();
  }

  // ── The echo mark, settled + faded, centered over the spine (x=100) ──────────────────────────────
  // 1:1 from the brand SVG: outer ring brightest, inner faintest — the echo coming to rest.
  void _paintEcho(Canvas canvas) {
    canvas
      ..save()
      ..translate(81, 0) // centers the 38-unit mark on x=100
      ..scale(38 / 28)
      ..translate(-3.08, -3.5)
      ..scale(1.25, 1.25);
    // [tx, ty, mx, my, ex, ey, rx, ry, opacity] — inner→outer.
    const rings = <List<double>>[
      [-2.2, 3, 10.5, 13, 10.5, 9, 2.3, 2.3, 0.30],
      [-1.7, 3, 15.5, 14.7, 15.5, 7.3, 5.0, 4.1, 0.48],
      [-0.8, 3, 21, 15.7, 21, 6.3, 6.5, 5.0, 0.68],
    ];
    for (final r in rings) {
      canvas
        ..save()
        ..translate(r[0], r[1]);
      final path = Path()
        ..moveTo(r[2], r[3])
        ..arcToPoint(Offset(r[4], r[5]), radius: Radius.elliptical(r[6], r[7]), clockwise: true);
      canvas
        ..drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.55
            ..strokeCap = StrokeCap.round
            ..color = p.primary.withValues(alpha: r[8]),
        )
        ..restore();
    }
    canvas.restore();
  }

  // ── The open book ────────────────────────────────────────────────────────────────────────────────
  void _paintBook(Canvas canvas) {
    // Cover tans: a warm leather/cloth cover with its own identity (like the original closed book), tuned
    // per brightness so it reads on both canvases. top→bottom gradient gives the cover its lift.
    final coverTop = p.dark ? const Color(0xFF7C5A3F) : const Color(0xFFB98B53);
    final coverBottom = p.dark ? const Color(0xFFA87B4C) : const Color(0xFF7C5A3F);
    // Pages: warm cream derived from the palette (page slightly lighter than the stack/edge).
    final page = _mix(p.warning, p.card, p.dark ? 0.16 : 0.035);
    final page2 = _mix(p.warning, p.card, p.dark ? 0.06 : 0.10);

    // Soft contact shadow.
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(100, 150), width: 148, height: 18),
      Paint()..color = p.ink.withValues(alpha: 0.13),
    );

    final coverShader = ui.Gradient.linear(const Offset(0, 58), const Offset(0, 136), [
      coverTop,
      coverBottom,
    ]);
    final pageShader = ui.Gradient.linear(const Offset(0, 58), const Offset(0, 125), [
      page,
      page2.withValues(alpha: 1),
    ]);

    // Cover (open) + its two undersides (the thickness you see beneath the pages).
    canvas
      ..drawPath(
        _p()
          ..moveTo(100, 70)
          ..cubicTo(70, 58, 40, 58, 22, 66)
          ..lineTo(22, 74)
          ..cubicTo(40, 66, 70, 66, 100, 78)
          ..cubicTo(130, 66, 160, 66, 178, 74)
          ..lineTo(178, 66)
          ..cubicTo(160, 58, 130, 58, 100, 70)
          ..close(),
        Paint()..shader = coverShader,
      )
      ..drawPath(
        _p()
          ..moveTo(22, 66)
          ..lineTo(22, 132)
          ..cubicTo(40, 124, 70, 124, 100, 136)
          ..lineTo(100, 78)
          ..cubicTo(70, 66, 40, 66, 22, 74)
          ..close(),
        Paint()..color = coverBottom.withValues(alpha: 0.55),
      )
      ..drawPath(
        _p()
          ..moveTo(178, 66)
          ..lineTo(178, 132)
          ..cubicTo(160, 124, 130, 124, 100, 136)
          ..lineTo(100, 78)
          ..cubicTo(130, 66, 160, 66, 178, 74)
          ..close(),
        Paint()..color = coverBottom.withValues(alpha: 0.55),
      );

    // Page-edge stack (paper thickness, the cream sliver between cover and the top page).
    final stackPaint = Paint()..color = page2;
    canvas
      ..drawPath(
        _p()
          ..moveTo(100, 74)
          ..cubicTo(71, 62, 42, 62, 26, 69)
          ..lineTo(26, 124)
          ..cubicTo(42, 117, 71, 117, 100, 129)
          ..close(),
        stackPaint,
      )
      ..drawPath(
        _p()
          ..moveTo(100, 74)
          ..cubicTo(129, 62, 158, 62, 174, 69)
          ..lineTo(174, 124)
          ..cubicTo(158, 117, 129, 117, 100, 129)
          ..close(),
        stackPaint,
      );

    // The blank spread (the two empty pages) + a hairline edge.
    final pageStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = p.primary.withValues(alpha: 0.34);
    final leftPage = _p()
      ..moveTo(100, 70)
      ..cubicTo(72, 58, 44, 58, 29, 65)
      ..lineTo(29, 120)
      ..cubicTo(44, 113, 72, 113, 100, 125)
      ..close();
    final rightPage = _p()
      ..moveTo(100, 70)
      ..cubicTo(128, 58, 156, 58, 171, 65)
      ..lineTo(171, 120)
      ..cubicTo(156, 113, 128, 113, 100, 125)
      ..close();
    canvas
      ..drawPath(leftPage, Paint()..shader = pageShader)
      ..drawPath(rightPage, Paint()..shader = pageShader)
      ..drawPath(leftPage, pageStroke)
      ..drawPath(rightPage, pageStroke);

    // Spine valley + a faint lit highlight beside it.
    canvas
      ..drawLine(
        const Offset(100, 70),
        const Offset(100, 125),
        Paint()
          ..strokeWidth = 1.4
          ..color = p.primary.withValues(alpha: 0.30),
      )
      ..drawLine(
        const Offset(101.2, 70),
        const Offset(101.2, 125),
        Paint()
          ..strokeWidth = 0.6
          ..color = page.withValues(alpha: 0.5),
      );

    // Faint dotted writing-guide — one stronger line + one fainter per page; the rest of the page stays
    // blank, which is what reads as "empty".
    final guideStrong = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round
      ..color = p.ink3.withValues(alpha: 0.55);
    final guideFaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round
      ..color = p.ink3.withValues(alpha: 0.30);
    _dash(
      canvas,
      _p()
        ..moveTo(40, 80)
        ..cubicTo(60, 75, 82, 75, 92, 78),
      guideStrong,
    );
    _dash(
      canvas,
      _p()
        ..moveTo(108, 78)
        ..cubicTo(120, 75, 142, 75, 160, 80),
      guideStrong,
    );
    _dash(
      canvas,
      _p()
        ..moveTo(40, 92)
        ..cubicTo(60, 87, 80, 87, 90, 89),
      guideFaint,
    );
    _dash(
      canvas,
      _p()
        ..moveTo(110, 89)
        ..cubicTo(124, 87, 144, 87, 158, 92),
      guideFaint,
    );
  }

  Path _p() => Path();

  /// Stroke [path] as a dotted line (dash 1.5, gap 4 — matches the prototype's `stroke-dasharray`).
  void _dash(Canvas canvas, Path path, Paint paint) {
    const dash = 1.5, gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, math.min(d + dash, metric.length)), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_EmptyBookPainter old) => old.p.dark != p.dark;
}
