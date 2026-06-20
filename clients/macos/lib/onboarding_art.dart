import 'dart:ui' as ui;

import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

import 'capture_shortcut_scope.dart';

/// The onboarding illustrations, ported from the rendered HTML/CSS art in
/// `DESIGN.md` (IL-01, IL-06, and the Step-3
/// rehearsal). No external PNGs — each is drawn from primitives so it tints
/// with the warm palette and reads in light + dark.

// ---------------------------------------------------------------------------
// IL-01 — the capture→review loop vignette (animated product story).
// ---------------------------------------------------------------------------

/// A small fixed-size animated vignette: the Mac shows a sentence, the cursor
/// lands on the target word, a glass overlay surfaces the meaning, the echo
/// mark broadcasts, and a phone review card fills in — the whole capture→echo
/// loop in one frame. Loops every ~7.6s; honors reduced-motion by freezing on
/// a representative frame.
class CaptureLoopVignette extends StatefulWidget {
  const CaptureLoopVignette({super.key, required this.p});
  final OnboardingPalette p;

  @override
  State<CaptureLoopVignette> createState() => _CaptureLoopVignetteState();
}

class _CaptureLoopVignetteState extends State<CaptureLoopVignette>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 7600),
  );

  /// The cursor's tip target on "epiphany" (vignette coords), measured once on first build.
  Offset? _wordTip;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      if (_c.isAnimating) _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
    // Design at a fixed size; FittedBox scales it to the available width so it
    // can never overflow a narrow window. The caller supplies a bounded width.
    return AspectRatio(
      aspectRatio: 520 / 188,
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: 520,
          height: 188,
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final t = reduceMotion ? 0.80 : _c.value;
              // Measured once (font metrics don't change) so the cursor lands on the word.
              _wordTip ??= _epiphanyWordCenter(widget.p) - const Offset(1, 1);
              return _frame(widget.p, t, _wordTip!);
            },
          ),
        ),
      ),
    );
  }
}

/// Fade-in → hold → fade-out envelope across a normalized timeline.
double _env(double t, double inA, double inB, double outA, double outB) {
  if (t < inA) return 0;
  if (t < inB) return ((t - inA) / (inB - inA)).clamp(0.0, 1.0);
  if (t < outA) return 1;
  if (t < outB) return (1 - (t - outA) / (outB - outA)).clamp(0.0, 1.0);
  return 0;
}

double _ease(double v) => Curves.easeInOut.transform(v.clamp(0.0, 1.0));

/// A clamped 0→1 ramp across [a, b].
double _ramp(double t, double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);

/// A 0→1→0 triangular pulse: rises across [a, peak], falls across [peak, b], 0 outside.
double _bump(double t, double a, double peak, double b) {
  if (t <= a || t >= b) return 0;
  return t < peak ? (t - a) / (peak - a) : 1 - (t - peak) / (b - peak);
}

/// Centre of the highlighted "epiphany" inside the Mac sentence, in vignette coordinates — measured
/// with the same style + wrap width the screen renders, so the cursor lands on the WORD (not on
/// "Capture"), whatever fallback font the host resolves.
Offset _epiphanyWordCenter(OnboardingPalette p) {
  final tp = TextPainter(
    textDirection: TextDirection.ltr,
    text: TextSpan(
      style: p.body(size: 12, height: 1.45),
      children: const [
        TextSpan(text: 'Capture “'),
        TextSpan(
          text: 'epiphany',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        TextSpan(text: '” in context, echo it back before it fades.'),
      ],
    ),
  )..layout(maxWidth: 162); // 198 macScreen − 20/16 horizontal padding
  final boxes = tp.getBoxesForSelection(
    const TextSelection(baseOffset: 9, extentOffset: 17), // "epiphany"
  );
  final r = boxes.isNotEmpty ? boxes.first.toRect() : const Rect.fromLTWH(60, 0, 48, 14);
  tp.dispose();
  // macScreen origin (26, 18) + its content padding (20, 18).
  return Offset(46 + r.center.dx, 36 + r.center.dy);
}

Widget _frame(OnboardingPalette p, double t, Offset wordTip) {
  // One slow loop, in order: the cursor glides onto "epiphany", the word lights up, the glass
  // overlay pops, the cursor slides down to Save and clicks it, the working echo pulses, and the
  // phone fills with the review card — the capture → save → echo loop.
  final cursorOpacity = _env(t, 0.03, 0.11, 0.88, 0.98);
  final toWord = _ease(_ramp(t, 0.05, 0.20)); // cursor: start → the word
  final toSave = _ease(_ramp(t, 0.27, 0.40)); // cursor: the word → Save
  final savePress = _bump(t, 0.41, 0.44, 0.47); // the click on Save
  final highlight = _env(t, 0.16, 0.22, 0.84, 0.94);
  final overlay = _ease(_env(t, 0.22, 0.30, 0.84, 0.94));
  final echoIn = _ease(_env(t, 0.47, 0.55, 0.82, 0.94));
  final echoProgress = _ramp(t, 0.49, 0.78);
  final phoneIn = _ease(_env(t, 0.66, 0.78, 0.88, 0.98));

  // The cursor lands its tip on the word's centre (measured once), then on the Save button.
  const start = Offset(64, 116);
  const saveTip = Offset(218, 122);
  final cursorPos = t < 0.27
      ? Offset.lerp(start, wordTip, toWord)!
      : Offset.lerp(wordTip, saveTip, toSave)!;

  return DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: p.line),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.alphaBlend(p.primarySoft.withValues(alpha: 0.5), p.card),
          p.canvas,
          Color.alphaBlend(p.primarySoft, p.card),
        ],
        stops: const [0, 0.55, 1],
      ),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: [
          // ---- the Mac ----
          Positioned(left: 26, top: 18, child: _macScreen(p, highlight)),
          // ---- glass overlay popping from the word (opaque so the sentence behind doesn't bleed
          // through); it carries the Save button the cursor clicks ----
          Positioned(
            left: 96,
            top: 46,
            child: Opacity(
              opacity: overlay,
              child: Transform.translate(
                offset: Offset(0, 8 * (1 - overlay)),
                child: Transform.scale(
                  scale: 0.98 + 0.02 * overlay,
                  alignment: Alignment.topLeft,
                  child: _miniOverlay(p, savePress),
                ),
              ),
            ),
          ),
          // ---- echo broadcast — centred in the gap between the overlay and the phone, twice ----
          Positioned(
            left: 263,
            top: 30,
            child: _EchoBroadcast(p: p, opacity: echoIn, progress: echoProgress),
          ),
          // ---- phone with the review card ----
          Positioned(right: 24, top: 18, child: _phone(p, phoneIn)),
          // moving cursor — drawn LAST so it rides on top of the overlay as it slides down to Save.
          Positioned(
            left: cursorPos.dx,
            top: cursorPos.dy,
            child: Opacity(
              opacity: cursorOpacity,
              child: Transform.scale(
                scale: 1 - 0.18 * savePress, // a small dip on the click
                alignment: Alignment.topLeft,
                child: _CursorArrow(color: p.ink, size: 15),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

Widget _macScreen(OnboardingPalette p, double highlight) {
  final sentenceColor = p.dark ? p.ink.withValues(alpha: 0.88) : p.ink2;
  final targetBackground = highlight <= 0
      ? null
      : p.dark
      ? Color.lerp(p.card, p.primary, 0.70 + 0.18 * highlight)
      : p.chip.withValues(alpha: highlight);
  final targetColor = p.dark && highlight > 0 ? p.primaryFg : p.ink;
  return Container(
    width: 198,
    height: 120,
    decoration: BoxDecoration(
      color: p.card,
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(12),
        bottom: Radius.circular(7),
      ),
      border: Border.all(color: p.edge.withValues(alpha: 0.5)),
      boxShadow: [BoxShadow(color: p.edge.withValues(alpha: 0.5), offset: const Offset(2, 2))],
    ),
    padding: const EdgeInsets.fromLTRB(20, 18, 16, 12),
    child: DefaultTextStyle(
      style: p.body(size: 12, height: 1.45, color: sentenceColor),
      child: Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: 'Capture “'),
            TextSpan(
              text: 'epiphany',
              style: p
                  .body(size: 12, height: 1.45, color: targetColor)
                  .copyWith(fontWeight: FontWeight.w600, backgroundColor: targetBackground),
            ),
            const TextSpan(text: '” in context, echo it back before it fades.'),
          ],
        ),
      ),
    ),
  );
}

Widget _miniOverlay(OnboardingPalette p, double savePress) {
  return Container(
    width: 158,
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
    decoration: BoxDecoration(
      // Opaque warm glass — at this size a translucent tint lets the sentence
      // behind it bleed through and muddies the text, so flatten it onto card.
      color: Color.alphaBlend(p.ovlTint, p.card),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: p.dark ? p.ovlEdge : p.line),
      boxShadow: const [BoxShadow(color: Color(0x38000000), blurRadius: 28, offset: Offset(0, 14))],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('epiphany', style: p.display(size: 17, height: 1, color: p.ovlInk)),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Container(height: 1, color: p.ovlRule),
        ),
        Text(
          'A moment of sudden revelation or insight.',
          style: p.body(size: 8.7, height: 1.35, color: p.ovlInk),
        ),
        const SizedBox(height: 9),
        // The Save the cursor clicks — nothing is kept until you confirm (IL-06's promise, in motion).
        Align(alignment: Alignment.centerRight, child: _miniSaveButton(p, savePress)),
      ],
    ),
  );
}

/// The overlay's Save button; [press] (0–1) drives the press-into-shadow as the cursor clicks it.
Widget _miniSaveButton(OnboardingPalette p, double press) {
  return Transform.translate(
    offset: Offset(1.5 * press, 1.5 * press),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: p.primary,
        borderRadius: BorderRadius.circular(6),
        boxShadow: press > 0.5 ? null : [BoxShadow(color: p.edge, offset: const Offset(1.5, 1.5))],
      ),
      child: Text(
        'Save',
        style: p.chrome(size: 9, weight: FontWeight.w700, color: p.primaryFg),
      ),
    ),
  );
}

Widget _phone(OnboardingPalette p, double fill) {
  return Container(
    width: 96,
    height: 150,
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: const Color(0xFF0A0A0A),
      borderRadius: BorderRadius.circular(10),
      boxShadow: const [BoxShadow(color: Color(0x4D281910), blurRadius: 30, offset: Offset(0, 14))],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ColoredBox(
        color: p.canvas,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(7, 16, 7, 10),
              child: Opacity(
                opacity: fill,
                child: Transform.translate(
                  offset: Offset(0, 5 * (1 - fill)),
                  child: _reviewMini(p),
                ),
              ),
            ),
            // dynamic island
            Positioned(
              top: 4,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  width: 30,
                  height: 8,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0A0A),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _reviewMini(OnboardingPalette p) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text('3 / 12', style: p.mono(size: 6, color: p.ink3)),
          const SizedBox(width: 4),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: Container(
                height: 2,
                color: p.line,
                child: FractionallySizedBox(
                  widthFactor: 0.25,
                  alignment: Alignment.centerLeft,
                  child: ColoredBox(color: p.primary),
                ),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 5),
      Expanded(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(8, 9, 8, 9),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: p.line),
          ),
          // Kept deliberately short (word + meaning) so the card never
          // overflows the tiny phone screen; clipped as a final guard.
          child: ClipRect(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('epiphany', style: p.display(size: 12, height: 1, color: p.ink)),
                const SizedBox(height: 5),
                Flexible(
                  child: Text(
                    'A moment of sudden revelation or insight.',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: p.body(size: 7, height: 1.35, color: p.ink2),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

/// The macOS pointer arrow.
class _CursorArrow extends StatelessWidget {
  const _CursorArrow({required this.color, required this.size});
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _CursorPainter(color));
}

class _CursorPainter extends CustomPainter {
  _CursorPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 16;
    final path = Path()
      ..moveTo(1 * s, 1 * s)
      ..lineTo(6.5 * s, 14 * s)
      ..lineTo(8.4 * s, 8.8 * s)
      ..lineTo(13.6 * s, 7 * s)
      ..close();
    canvas.drawShadow(path, const Color(0xFF000000), 1.5, false);
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_CursorPainter old) => old.color != color;
}

/// The working echo mark: the mark's own three arcs pulse inner→outer. No external circular ripple is
/// drawn here; a moving echo means the app is working, not a memory-state broadcast.
class _EchoBroadcast extends StatelessWidget {
  const _EchoBroadcast({required this.p, required this.opacity, required this.progress});
  final OnboardingPalette p;
  final double opacity;
  final double progress; // 0..1 across the working beat

  @override
  Widget build(BuildContext context) {
    if (opacity <= 0) return const SizedBox(width: 120, height: 120);
    return Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: SizedBox(
        width: 120,
        height: 120,
        child: Center(
          child: ObEchoMark(
            color: p.primary,
            size: 58,
            ringOpacities: _workingEchoOpacities(progress),
          ),
        ),
      ),
    );
  }
}

List<double> _workingEchoOpacities(double progress) {
  return [
    _workingRingOpacity(progress, 0.32), // outer
    _workingRingOpacity(progress, 0.16), // middle
    _workingRingOpacity(progress, 0.00), // inner
  ];
}

double _workingRingOpacity(double progress, double delay) {
  const span = 0.62;
  final local = (progress - delay) / span;
  if (local < 0 || local > 1) return 0;
  if (local < 0.35) {
    return ui.lerpDouble(0.15, 1, local / 0.35)!;
  }
  return ui.lerpDouble(1, 0, (local - 0.35) / 0.65)!;
}

// ---------------------------------------------------------------------------
// IL-06 — the trust card (you review + edit before anything is saved).
// ---------------------------------------------------------------------------

/// `.tc--mac`: a small captured-result card showing the headword, a sage
/// shield tick, a masked context line (privacy), and Save / Edit — the proof
/// that nothing is saved until you confirm.
class PermissionTrustCard extends StatelessWidget {
  const PermissionTrustCard({super.key, required this.p, this.showEdit = true});
  final OnboardingPalette p;
  final bool showEdit;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 256,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 15),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Color.alphaBlend(p.primary.withValues(alpha: 0.32), p.line)),
        boxShadow: [
          BoxShadow(
            color: p.dark ? const Color(0x8C000000) : p.primary.withValues(alpha: 0.28),
            blurRadius: 22,
            offset: const Offset(0, 10),
            spreadRadius: -12,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  'epiphany',
                  style: p
                      .display(size: 22, height: 1, color: p.primary)
                      .copyWith(fontStyle: FontStyle.italic),
                ),
              ),
              _ShieldTick(color: p.success),
            ],
          ),
          const SizedBox(height: 11),
          Text.rich(
            TextSpan(
              style: p.body(size: 12.5, height: 1.55, color: p.ink.withValues(alpha: 0.6)),
              children: [
                const TextSpan(text: 'a sudden '),
                TextSpan(
                  text: 'epiphany',
                  style: p
                      .body(size: 12.5, height: 1.55, color: p.ink.withValues(alpha: 0.85))
                      .copyWith(
                        fontStyle: FontStyle.italic,
                        fontWeight: FontWeight.w600,
                        backgroundColor: p.warning.withValues(alpha: 0.3),
                      ),
                ),
                const TextSpan(text: ' in the note to '),
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: _Mask(p: p),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _tcAction(p, 'Save', primary: true),
              if (showEdit) ...[const SizedBox(width: 9), _tcAction(p, 'Edit', primary: false)],
            ],
          ),
        ],
      ),
    );
  }

  Widget _tcAction(OnboardingPalette p, String label, {required bool primary}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
      decoration: BoxDecoration(
        color: primary ? p.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: primary ? null : Border.all(color: p.line),
      ),
      child: Text(
        label,
        style: p.chrome(
          size: 12,
          weight: primary ? FontWeight.w600 : FontWeight.w500,
          color: primary ? p.primaryFg : p.ink2,
        ),
      ),
    );
  }
}

class _Mask extends StatelessWidget {
  const _Mask({required this.p});
  final OnboardingPalette p;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: p.ink.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        '••••••',
        style: TextStyle(fontSize: 9.5, letterSpacing: 1, color: p.ink.withValues(alpha: 0.5)),
      ),
    );
  }
}

class _ShieldTick extends StatelessWidget {
  const _ShieldTick({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(20, 23), painter: _ShieldPainter(color));
}

class _ShieldPainter extends CustomPainter {
  _ShieldPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 16, sy = size.height / 18;
    final shield = Path()
      ..moveTo(8 * sx, 1.4 * sy)
      ..lineTo(14 * sx, 3.6 * sy)
      ..lineTo(14 * sx, 8.2 * sy)
      ..cubicTo(14 * sx, 12.4 * sy, 11.2 * sx, 15.4 * sy, 8 * sx, 16.8 * sy)
      ..cubicTo(4.8 * sx, 15.4 * sy, 2 * sx, 12.4 * sy, 2 * sx, 8.2 * sy)
      ..lineTo(2 * sx, 3.6 * sy)
      ..close();
    canvas.drawPath(shield, Paint()..color = color.withValues(alpha: 0.1));
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    canvas.drawPath(shield, stroke);
    final check = Path()
      ..moveTo(5.4 * sx, 8.6 * sy)
      ..lineTo(7.2 * sx, 10.4 * sy)
      ..lineTo(10.8 * sx, 6.6 * sy);
    canvas.drawPath(check, stroke);
  }

  @override
  bool shouldRepaint(_ShieldPainter old) => old.color != color;
}

// ---------------------------------------------------------------------------
// Step 3 — the guided first-capture rehearsal surface.
// ---------------------------------------------------------------------------

/// A simulated reading page (`.desktop-backdrop`) with the focused word
/// highlighted, a coachmark cueing the hotkey, and — below it — the Capture-shortcut editor (so the
/// user can make the hotkey theirs before the real first capture). [ocrArmed] flips the
/// coachmark/instruction between ⌥E-alone and ⌘C-then-⌥E (CR #2).
class RehearsalSurface extends StatelessWidget {
  const RehearsalSurface({super.key, required this.p, required this.ocrArmed, this.onEditShortcut});
  final OnboardingPalette p;
  final bool ocrArmed;

  /// Opens the Capture-shortcut recorder (wired by the host). Null → the on-card shortcut is shown
  /// read-only (tests / no host). Saving republishes the binding via [CaptureShortcutScope], so the
  /// coachmark above and the caps here update together.
  final VoidCallback? onEditShortcut;

  @override
  Widget build(BuildContext context) {
    final paper = p.dark ? p.card : const Color(0xFFFBFAF7);
    final paperInk = p.dark ? p.ink : const Color(0xFF2A2622);
    final paperInk2 = p.dark ? p.ink2 : const Color(0xFF2A2622).withValues(alpha: 0.72);
    return Container(
      decoration: BoxDecoration(
        color: paper,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.line),
      ),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Try & Capture', style: p.display(size: 22, height: 1.2, color: paperInk)),
          const SizedBox(height: 14),
          // coachmark anchored above the focused word
          _Coachmark(p: p, ocrArmed: ocrArmed),
          const SizedBox(height: 9),
          // REAL selectable text — the rehearsal asks the user to capture a
          // word from this very surface, so it must be selectable (clipboard
          // mode: select + ⌘C) and OCR-readable (hover + ⌥E). The focused word
          // is highlighted via a text-native background, not a WidgetSpan box.
          SelectableText.rich(
            TextSpan(
              style: p.body(size: 15, height: 1.6, color: paperInk2),
              children: [
                const TextSpan(text: 'The history of science is studded with moments of '),
                TextSpan(
                  text: 'serendipity',
                  style: p
                      .body(size: 15, height: 1.6, color: paperInk)
                      .copyWith(
                        fontWeight: FontWeight.w600,
                        backgroundColor: p.dark
                            ? const Color(0x33E6C49B)
                            : p.warning.withValues(alpha: 0.18),
                      ),
                ),
                const TextSpan(
                  text:
                      ' — a stray observation, an accident in the lab, a '
                      'misfiled note that turns out to matter.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          // The Capture-shortcut editor (replaces the old illustrative result overlay): the current
          // binding as key-caps + a "Change…" affordance. Saving republishes it via
          // CaptureShortcutScope, so the coachmark above and these caps move together.
          _RehearsalShortcutEditor(p: p, onEdit: onEditShortcut),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _Coachmark extends StatelessWidget {
  const _Coachmark({required this.p, required this.ocrArmed});
  final OnboardingPalette p;
  final bool ocrArmed;
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Natural size in a real window; scales down only if the surface is
          // too narrow (e.g. a small/resized window) rather than overflowing.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              decoration: BoxDecoration(
                color: p.primary,
                borderRadius: BorderRadius.circular(999),
                boxShadow: [BoxShadow(color: p.edge, offset: const Offset(3, 3))],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    ocrArmed ? 'Hover a word and press ' : 'Copy a word, then ',
                    style: p.chrome(size: 13, weight: FontWeight.w600, color: p.primaryFg),
                  ),
                  if (!ocrArmed) ...[
                    _coachCap(p, '⌘'),
                    const SizedBox(width: 5),
                    _coachCap(p, 'C'),
                    const SizedBox(width: 6),
                    Text(
                      'then ',
                      style: p.chrome(size: 13, weight: FontWeight.w600, color: p.primaryFg),
                    ),
                  ],
                  ..._captureCaps(p, CaptureShortcutScope.displayOf(context)),
                ],
              ),
            ),
          ),
          // downward beak (pulled up under the pill via a translate — Container
          // forbids a negative margin)
          Padding(
            padding: const EdgeInsets.only(left: 22),
            child: Transform.translate(
              offset: const Offset(0, -5),
              child: Transform.rotate(
                angle: 0.785398, // 45°
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: p.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _coachCap(OnboardingPalette p, String label) {
    return Container(
      height: 22,
      constraints: const BoxConstraints(minWidth: 22),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(color: p.primaryFg, borderRadius: BorderRadius.circular(5)),
      child: Text(label, style: p.mono(size: 12, color: p.primary)),
    );
  }

  /// One [_coachCap] per character of the Capture display ("⌥E" → ⌥ · E,
  /// "⌘⇧F" → ⌘ · ⇧ · F), with the same 5px gap the original two-cap layout used.
  List<Widget> _captureCaps(OnboardingPalette p, String display) {
    final widgets = <Widget>[];
    for (var i = 0; i < display.length; i++) {
      if (widgets.isNotEmpty) widgets.add(const SizedBox(width: 5));
      widgets.add(_coachCap(p, display[i]));
    }
    return widgets;
  }
}

/// The Capture-shortcut editor shown in the rehearsal — it replaces the old illustrative result
/// overlay. Shows the current Capture hotkey as key-caps + a "Change…" affordance that opens the same
/// recorder Settings uses. [onEdit] null (tests / no host) → read-only caps. Saving republishes the
/// binding via [CaptureShortcutScope], so the coachmark above and these caps update in lockstep.
class _RehearsalShortcutEditor extends StatelessWidget {
  const _RehearsalShortcutEditor({required this.p, required this.onEdit});
  final OnboardingPalette p;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final display = CaptureShortcutScope.displayOf(context);
    // One cap per glyph for ObKeyCombo: "⌥E" → [⌥, E], "⌘⇧F" → [⌘, ⇧, F].
    final parts = [for (var i = 0; i < display.length; i++) display[i]];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.line),
        boxShadow: kSoftEdgeShadow,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Capture shortcut',
                  style: p.chrome(size: 14, weight: FontWeight.w600, color: p.ink),
                ),
                const SizedBox(height: 4),
                Text(
                  'Press it in any app to capture the word you’re reading — make it yours.',
                  style: p
                      .chrome(size: 12.5, weight: FontWeight.w400, color: p.ink2)
                      .copyWith(height: 1.45),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          ObKeyCombo(p: p, parts: parts),
          if (onEdit != null) ...[
            const SizedBox(width: 12),
            ObQuietButton(p: p, label: 'Change…', onPressed: onEdit!),
          ],
        ],
      ),
    );
  }
}
