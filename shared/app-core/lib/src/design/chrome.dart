import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Shared chrome for the onboarding flow — the pieces that recur on every step
/// and carry the design language defined in `DESIGN.md`:
/// the titled mac-window shell, the 5-dot step indicator, the `)))` echo mark,
/// SPEC-KEYCAP key caps, and the warm shadow-edge buttons.
///
/// Colors/type come from `design/tokens.css` (hand-ported into
/// [OnboardingPalette]). The hand-port is kept honest by a drift-guard test
/// (`test/onboarding_palette_tokens_test.dart`) that asserts every field equals
/// the generated Dart token port (`shared/design-tokens/generated/capecho_tokens.dart`,
/// DES-2) for both brightnesses — so a `tokens.css` change that's regenerated but
/// not reflected here fails CI. Consuming the generated file directly (it isn't a
/// Dart package yet) + the native overlay's tokens remain follow-ups.

// Editorial serif stacks. Fraunces/Charter aren't bundled, but the macOS
// fallbacks (Georgia / Charter) carry the warm serif character the mockup uses
// for display + body; chrome stays on the system sans (San Francisco).
const List<String> kDisplayFamily = ['Fraunces', 'Charter', 'Georgia'];
const List<String> kBodyFamily = ['Charter', 'Georgia'];
const List<String> kMonoFamily = ['JetBrains Mono', 'Menlo', 'monospace'];

/// `--shadow-edge-soft` — the design system's "stacked-paper" card lift. It is a
/// crisp warm OFFSET (4px 5px, blur 0), NOT a blurred drop shadow, and is the same
/// rgba(43,35,32,0.13) in light and dark (tokens.css reuses it across modes). Every
/// app card/section (Review card, Settings sections, Word Book context cards) uses it
/// so they read as lifted paper on the warm canvas.
const List<BoxShadow> kSoftEdgeShadow = [BoxShadow(color: Color(0x212B2320), offset: Offset(4, 5))];

/// Shared padding for the app's outlined "pill" buttons so they stay uniform across both clients (bump
/// here, never per screen). [kPillButtonPadding] is the standard outlined pill (Word Book's Explain-here
/// CTA, Delete word); [kPillIconButtonPadding] is the smaller inline icon+label pill (Edit / Remove).
/// Vertical room is deliberately generous — a cramped pill reads as an afterthought.
const EdgeInsets kPillButtonPadding = EdgeInsets.symmetric(horizontal: 16, vertical: 11);
const EdgeInsets kPillIconButtonPadding = EdgeInsets.symmetric(horizontal: 12, vertical: 8);

/// Human label for a BCP-47-ish language code, covering the explanation-language
/// set (`en` / `zh-Hans` / `es`) plus the common review/Word Book targets. Falls
/// back to the upper-cased code. Shared by Review, Word Book, and Settings so the
/// same code never renders two different labels (e.g. `zh` was '中文' in one
/// surface and '简体中文' in another before this was unified).
String langName(String code) {
  switch (code.toLowerCase()) {
    case 'en':
      return 'English';
    case 'es':
      return 'Español';
    case 'de':
      return 'Deutsch';
    case 'it':
      return 'Italiano';
    case 'fr':
      return 'Français';
    case 'pt':
      return 'Português';
    case 'zh':
    case 'zh-hans':
      return '简体中文';
    case 'zh-hant':
      return '繁體中文';
    case 'ja':
      return '日本語';
    case 'ko':
      return '한국어';
    default:
      return code.toUpperCase();
  }
}

/// The warm app palette (`--app-*` + `--ovl-*`), resolved per [Brightness].
class OnboardingPalette {
  const OnboardingPalette({
    required this.dark,
    required this.canvas,
    required this.card,
    required this.titlebar,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.line,
    required this.edge,
    required this.primary,
    required this.primaryFg,
    required this.primarySoft,
    required this.chip,
    required this.chipFg,
    required this.success,
    required this.warning,
    required this.error,
    required this.info,
    required this.ovlTint,
    required this.ovlEdge,
    required this.ovlInk,
    required this.ovlInk2,
    required this.ovlRule,
    required this.ovlDivider,
    required this.ovlAccent,
    required this.ovlSaveEdge,
  });

  final bool dark;
  final Color canvas;
  final Color card;
  final Color titlebar;
  final Color ink;
  final Color ink2;
  final Color ink3;
  final Color line;
  final Color edge;
  final Color primary;
  final Color primaryFg;
  final Color primarySoft;
  final Color chip;
  final Color chipFg;
  final Color success;
  final Color warning;

  /// Destructive/error tone (oxblood, `--error`) — Review's "Forget", Settings'
  /// delete-account + "Not saved" states, Word Book's remove/error text.
  final Color error;

  /// Calm informational tone (slate, `--info`) — Review's "Easy", Settings' info
  /// notes, Word Book's context-edit accent.
  final Color info;
  final Color ovlTint;
  final Color ovlEdge;
  final Color ovlInk;
  final Color ovlInk2;
  final Color ovlRule;
  final Color ovlDivider;
  final Color ovlAccent;
  final Color ovlSaveEdge;

  static const _light = OnboardingPalette(
    dark: false,
    canvas: Color(0xFFF6F3EF),
    card: Color(0xFFFFFFFF),
    titlebar: Color(0xFFEFEAE3),
    ink: Color(0xFF2B2320),
    ink2: Color(0xFF6B5D54),
    ink3: Color(0xFFA2958A),
    line: Color(0xFFECE5DC),
    edge: Color(0xFF2B2320),
    primary: Color(0xFF644A40),
    primaryFg: Color(0xFFFFFFFF),
    primarySoft: Color(0x21644A40), // rgba(100,74,64,0.13)
    chip: Color(0xFFFFDFB5),
    chipFg: Color(0xFF582D1D),
    success: Color(0xFF5A6A48),
    warning: Color(0xFFA8741E),
    error: Color(0xFF8A2A1E),
    info: Color(0xFF4A5A6A),
    ovlTint: Color(0xB8F6F2EC), // rgba(246,242,236,0.72)
    ovlEdge: Color(0x94FFFBF5), // rgba(255,251,245,0.58)
    ovlInk: Color(0xFF241C17),
    ovlInk2: Color(0xFF6A5B50),
    ovlRule: Color(0x573E2D22), // rgba(62,45,34,0.34)
    ovlDivider: Color(0x243E2D22), // rgba(62,45,34,0.14)
    ovlAccent: Color(0xFF644A40),
    ovlSaveEdge: Color(0x663E2D22), // rgba(62,45,34,0.40)
  );

  static const _dark = OnboardingPalette(
    dark: true,
    canvas: Color(0xFF221B17),
    card: Color(0xFF2C241F),
    titlebar: Color(0xFF1C1611),
    ink: Color(0xFFF0E9E0),
    ink2: Color(0xFFC3B4A6),
    ink3: Color(0xFF8D7E71),
    line: Color(0xFF3A302A),
    edge: Color(0xFF100C0A),
    primary: Color(0xFFE6C49B),
    primaryFg: Color(0xFF2B1F18),
    primarySoft: Color(0x2EE6C49B), // rgba(230,196,155,0.18)
    chip: Color(0x29E6C49B), // rgba(230,196,155,0.16)
    chipFg: Color(0xFFE6C49B),
    success: Color(0xFF5A6A48),
    warning: Color(0xFFA8741E),
    error: Color(0xFF8A2A1E),
    info: Color(0xFF4A5A6A),
    ovlTint: Color(0xB3221A15), // rgba(34,26,21,0.70)
    ovlEdge: Color(0x29FFF8F0), // rgba(255,248,240,0.16)
    ovlInk: Color(0xFFF1EAE0),
    ovlInk2: Color(0xFFC4B5A7),
    ovlRule: Color(0x66F0E9E0), // rgba(240,233,224,0.40)
    ovlDivider: Color(0x1FF0E9E0), // rgba(240,233,224,0.12)
    ovlAccent: Color(0xFFE6C49B),
    ovlSaveEdge: Color(0x4DF0E9E0), // rgba(240,233,224,0.30)
  );

  static OnboardingPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? _dark : _light;

  /// The resolved light/dark palettes, exposed for the drift-guard test only
  /// (`test/onboarding_palette_tokens_test.dart`). Production code resolves via
  /// [of]; don't read these directly.
  @visibleForTesting
  static const OnboardingPalette lightForTest = _light;
  @visibleForTesting
  static const OnboardingPalette darkForTest = _dark;

  /// Editorial display serif (Fraunces lineage) — headlines.
  TextStyle display({
    required double size,
    double height = 1.15,
    FontWeight weight = FontWeight.w500,
    double letterSpacing = -0.015 * 28,
    Color? color,
  }) => TextStyle(
    fontFamilyFallback: kDisplayFamily,
    fontSize: size,
    height: height,
    fontWeight: weight,
    letterSpacing: letterSpacing,
    color: color ?? ink,
  );

  /// Body serif (Charter lineage) — ledes, reading copy, explanations.
  TextStyle body({
    required double size,
    double height = 1.55,
    Color? color,
    FontStyle? fontStyle,
    FontWeight? weight,
  }) => TextStyle(
    fontFamilyFallback: kBodyFamily,
    fontSize: size,
    height: height,
    color: color ?? ink2,
    fontStyle: fontStyle,
    fontWeight: weight,
  );

  /// System sans (San Francisco) — chrome: buttons, labels, eyebrows.
  TextStyle chrome({
    required double size,
    double height = 1.3,
    FontWeight weight = FontWeight.w500,
    double letterSpacing = 0,
    Color? color,
  }) => TextStyle(
    fontSize: size,
    height: height,
    fontWeight: weight,
    letterSpacing: letterSpacing,
    color: color ?? ink,
  );

  TextStyle mono({required double size, Color? color}) => TextStyle(
    fontFamilyFallback: kMonoFamily,
    fontSize: size,
    color: color ?? ink3,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

// NOTE: the mockup wraps each step in a fake `.mac-window` (traffic-light
// titlebar) because it is a standalone HTML mockup that must "read as real".
// In the live app this Flutter view fills a real titled `NSWindow` that already
// has the OS traffic lights, so we deliberately render the designed *content*
// on the warm canvas and let the OS supply the window chrome — drawing a second
// titlebar would double it up. The per-step window titles
// ("Welcome to Capecho" / "Try it — capture your first word") are an OS-title
// concern, not painted here.

/// The 5-dot step indicator (`.ob__steps`): done dots fade to 0.42, the current
/// dot is full primary, future dots are the hairline color.
class ObStepDots extends StatelessWidget {
  const ObStepDots({super.key, required this.p, required this.count, required this.current});
  final OnboardingPalette p;
  final int count;
  final int current; // 0-based

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final Color c;
        if (i == current) {
          c = p.primary;
        } else if (i < current) {
          c = p.primary.withValues(alpha: 0.42);
        } else {
          c = p.line;
        }
        return Padding(
          padding: EdgeInsets.only(right: i == count - 1 ? 0 : 7),
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
        );
      }),
    );
  }
}

/// The signature `)))` echo mark — three concentric ripples, a 1:1 port of the brand SVG
/// (`DESIGN.md`), tinted by [color]. [ringOpacities] (outer→inner) drives both the static
/// memory-meter variants and the animated broadcast (the vignette feeds it
/// per-frame values). Default = `echo--full`.
class ObEchoMark extends StatelessWidget {
  const ObEchoMark({
    super.key,
    required this.color,
    this.size = 22,
    this.ringOpacities = const [1, 1, 1],
  });
  final Color color;
  final double size;
  final List<double> ringOpacities;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _EchoPainter(color: color, ringOpacities: ringOpacities),
      ),
    );
  }
}

class _EchoPainter extends CustomPainter {
  _EchoPainter({required this.color, required this.ringOpacities});
  final Color color;
  final List<double> ringOpacities;

  // The app echo mark — the CURRENT brand mark: three growing C-shaped ripples opening right (small +
  // left → large + right), NOT the older concentric ")))". Ported 1:1 from the brand SVG that the macOS
  // app icon, the native status-menu glyph (`AppDelegate.capechoStatusImage`), and the web mark
  // (`web/components/brand/echo-mark.tsx`) all share — so every surface reads as one logo. Each ring is
  // [startX, startY, endX, endY, rx, ry] in a 28×28 viewBox, drawn under the shared group transform in
  // `paint`. Ring order stays outer→inner (largest/right → smallest/left, radii 6.5 → 5 → 2.3) so
  // [ringOpacities] keeps its memory-meter contract (the loading echo animates these same rings).
  static const double _viewBox = 28;
  static const List<List<double>> _rings = [
    [20.2, 18.7, 20.2, 9.3, 6.5, 5.0],
    [13.8, 17.7, 13.8, 10.3, 5.0, 4.1],
    [8.3, 16.0, 8.3, 12.0, 2.3, 2.3],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    // Scale the 28-unit square viewBox to the widget size, then apply the brand SVG's shared group
    // transform (translate -3.08,-3.5 · scale 1.25) that centers the three C's. The stroke (1.6 in the
    // scaled space) keeps the brand's weight ratio at every size.
    canvas
      ..save()
      ..scale(size.width / _viewBox, size.height / _viewBox)
      ..translate(-3.08, -3.5)
      ..scale(1.25, 1.25);
    for (var i = 0; i < 3; i++) {
      final r = _rings[i];
      final path = Path()
        ..moveTo(r[0], r[1])
        ..arcToPoint(Offset(r[2], r[3]), radius: Radius.elliptical(r[4], r[5]), clockwise: true);
      final op = (i < ringOpacities.length ? ringOpacities[i] : 1.0).clamp(0.0, 1.0);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: op),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EchoPainter old) =>
      old.color != color || !_listEq(old.ringOpacities, ringOpacities);

  static bool _listEq(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The brand echo mark animated as the app's ONE loading indicator — a coffee band
/// sweeping the three C's left → right, looping. This is the "working" reading of the
/// [[echo mark]] (DESIGN.md's disambiguation rule: **motion = working**, static
/// fill-level = memory state — so this MUST animate and the memory-meter [ObEchoMark]
/// must not). Replaces `CircularProgressIndicator` everywhere so every surface shows
/// one logo. The native macOS capture HUD (`CaptureLoadingPanel.swift`) mirrors this
/// same left→right sweep.
///
/// [color] tints the band (coffee `--app-primary` in-app / latte on dark, or
/// `primaryFg` on a filled button); the unfilled C's sit underneath at [trackOpacity].
/// Honours `MediaQuery.disableAnimations` — reduced-motion shows the static mark.
class ObEchoLoader extends StatefulWidget {
  const ObEchoLoader({super.key, required this.color, this.size = 28, this.trackOpacity = 0.16});
  final Color color;
  final double size;
  final double trackOpacity;

  @override
  State<ObEchoLoader> createState() => _ObEchoLoaderState();
}

class _ObEchoLoaderState extends State<ObEchoLoader> with SingleTickerProviderStateMixin {
  // 1.5s per sweep matches the HTML prototype + the native HUD's cadence.
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Drive the sweep only when the system allows animation — under reduced-motion the
    // controller stays idle (and the build holds the still mark), so nothing keeps a
    // moving echo on screen.
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Reduced motion: hold the still mark in the band colour (no sweep) — a moving echo
    // must never appear when the user has asked the system to suppress animation.
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      return ObEchoMark(color: widget.color, size: widget.size);
    }
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => CustomPaint(
          painter: _EchoSweepPainter(
            color: widget.color,
            trackOpacity: widget.trackOpacity,
            t: _c.value,
          ),
        ),
      ),
    );
  }
}

class _EchoSweepPainter extends CustomPainter {
  _EchoSweepPainter({required this.color, required this.trackOpacity, required this.t});
  final Color color;
  final double trackOpacity;
  final double t;

  // Same geometry + group transform as [_EchoPainter] — the three brand C-arcs in the
  // 28-unit viewBox — so the loader is the identical logo, just lit by a moving band.
  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..scale(size.width / _EchoPainter._viewBox, size.height / _EchoPainter._viewBox)
      ..translate(-3.08, -3.5)
      ..scale(1.25, 1.25);

    // The coffee band: a horizontal gradient (track → bright → track) whose centre
    // travels left→right across the mark's x-extent (the arcs live at x≈8..21 in this
    // local space). It enters from the left of the mark and exits past the right, then
    // the controller loops — a continuous sweep with no hard reset.
    final track = color.withValues(alpha: trackOpacity);
    final center = ui.lerpDouble(2.0, 27.0, t)!;
    const half = 7.0;
    final shader = ui.Gradient.linear(
      Offset(center - half, 0),
      Offset(center + half, 0),
      [track, color, track],
      [0.0, 0.5, 1.0],
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..shader = shader;

    for (final r in _EchoPainter._rings) {
      final path = Path()
        ..moveTo(r[0], r[1])
        ..arcToPoint(Offset(r[2], r[3]), radius: Radius.elliptical(r[4], r[5]), clockwise: true);
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EchoSweepPainter old) =>
      old.t != t || old.color != color || old.trackOpacity != trackOpacity;
}

/// The "Capecho." wordmark with the primary-tinted period. [size] is the wordmark cap height (the
/// `Capecho.` type size); the trailing echo mark rides a touch larger (×1.18) so the brand glyph reads
/// as prominent as the word beside it — the onboarding welcome uses a larger [size] than the agent-home
/// header.
class ObWordmark extends StatelessWidget {
  const ObWordmark({super.key, required this.p, this.withEcho = false, this.size = 22});
  final OnboardingPalette p;
  final bool withEcho;
  final double size;
  @override
  Widget build(BuildContext context) {
    final mark = Text.rich(
      TextSpan(
        text: 'Capecho',
        style: p.display(
          size: size,
          height: 1.0,
          weight: FontWeight.w600,
          letterSpacing: -0.01 * size,
          color: p.ink,
        ),
        children: [
          TextSpan(
            text: '.',
            style: TextStyle(color: p.primary),
          ),
        ],
      ),
    );
    if (!withEcho) return mark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        SizedBox(width: size * 0.42),
        ObEchoMark(color: p.primary, size: size * 1.18),
      ],
    );
  }
}

/// SPEC-KEYCAP: rectangular cap, fixed 24px height, single glyphs become 24×24
/// squares; 5px radius, mono glyph, shadow-edge-sm offset.
class ObKeyCap extends StatelessWidget {
  const ObKeyCap({super.key, required this.p, required this.label});
  final OnboardingPalette p;
  final String label;
  @override
  Widget build(BuildContext context) {
    // A single glyph (⌥, E, ⏎, a digit) is a FIXED 24×24 square — pin the width so a wide glyph
    // like ⌥ can't render a hair wider than its E / digit siblings (the option-vs-E mismatch). Multi-
    // char caps (Space, Esc) keep the min-width + 7px side padding and grow with their label.
    final single = label.runes.length == 1;
    return Container(
      height: 24,
      width: single ? 24 : null,
      constraints: single ? null : const BoxConstraints(minWidth: 24),
      padding: single ? null : const EdgeInsets.symmetric(horizontal: 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: p.edge.withValues(alpha: p.dark ? 0.9 : 1)),
        boxShadow: [BoxShadow(color: p.edge, offset: const Offset(2, 2))],
      ),
      child: Text(label, style: p.mono(size: 12, color: p.ink)),
    );
  }
}

/// A hotkey combo row, e.g. ⌥ + E or ⌘ C then ⌥ E. [parts] interleaves caps
/// (single tokens) with connector words rendered in muted chrome.
class ObKeyCombo extends StatelessWidget {
  const ObKeyCombo({super.key, required this.p, required this.parts});
  final OnboardingPalette p;

  /// Each entry: a 1–2 char cap label, or a connector like '+' / 'then'.
  final List<String> parts;

  static const _connectors = {'+', 'then', '·'};

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) children.add(const SizedBox(width: 7));
      final part = parts[i];
      if (_connectors.contains(part)) {
        children.add(Text(part, style: p.chrome(size: 13, color: p.ink3)));
      } else {
        children.add(ObKeyCap(p: p, label: part));
      }
    }
    // A shrink-wrapping Row (NOT a Wrap): caps must size to their glyph. In a
    // Wrap the bounded width + ObKeyCap's center alignment made each cap expand
    // to full width and stack vertically. FittedBox keeps it on one line even
    // in a narrow/resized window.
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: children,
      ),
    );
  }
}

/// The single restrained accent button (`.btn-primary`): primary fill,
/// shadow-edge offset, press translates into the shadow.
class ObPrimaryButton extends StatefulWidget {
  const ObPrimaryButton({
    super.key,
    required this.p,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.fullWidth = false,
    this.filled = true,
  });
  final OnboardingPalette p;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final bool fullWidth;

  /// When false, renders the SAME shape (padding, radius, press shadow-edge) in a
  /// muted secondary tone — a soft primary-tinted fill with the primary as the
  /// label colour — for a de-emphasised choice that still reads as the same button
  /// family (e.g. the onboarding "use copy & paste instead" escape).
  final bool filled;

  @override
  State<ObPrimaryButton> createState() => _ObPrimaryButtonState();
}

class _ObPrimaryButtonState extends State<ObPrimaryButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final enabled = !widget.busy && widget.onPressed != null;
    final offset = _pressed ? 1.0 : 3.0;
    // The muted (secondary) tone keeps the primary's geometry + press shadow-edge
    // but swaps the strong fill for a soft primary tint with the primary as label.
    final bg = widget.filled ? p.primary : p.card;
    final fg = widget.filled ? p.primaryFg : p.ink;
    final child = AnimatedContainer(
      duration: const Duration(milliseconds: 90),
      transform: Matrix4.translationValues(_pressed ? 2 : 0, _pressed ? 2 : 0, 0),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        // Muted (secondary) = an outlined card button (the warm "Open System
        // Settings" look); the filled primary keeps the press shadow-edge.
        border: widget.filled ? null : Border.all(color: p.line),
        boxShadow: widget.filled
            ? [BoxShadow(color: p.edge, offset: Offset(offset, offset))]
            : null,
      ),
      child: widget.busy
          ? ObEchoLoader(color: fg, size: 20)
          : Text(
              widget.label,
              style: p.chrome(size: 14, weight: FontWeight.w600, color: fg),
            ),
    );
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: enabled ? widget.onPressed : null,
        child: Semantics(
          button: true,
          label: widget.label,
          enabled: enabled,
          child: widget.fullWidth
              ? Row(
                  children: [Expanded(child: Center(child: child))],
                )
              : child,
        ),
      ),
    );
  }
}

/// `.btn-ghost.btn-block` — a quiet outlined button with a primary label and a
/// dimmer subcopy line, left-aligned. Used for the reduced-mode choice.
class ObGhostBlockButton extends StatelessWidget {
  const ObGhostBlockButton({
    super.key,
    required this.p,
    required this.label,
    required this.sub,
    required this.onPressed,
  });
  final OnboardingPalette p;
  final String label;
  final String sub;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        backgroundColor: Colors.transparent,
        side: BorderSide(color: p.line),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        alignment: Alignment.centerLeft,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: onPressed,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: p.chrome(size: 14, weight: FontWeight.w600)),
          const SizedBox(height: 3),
          Text(
            sub,
            style: p
                .chrome(size: 12, weight: FontWeight.w400, color: p.ink2)
                .copyWith(height: 1.35),
          ),
        ],
      ),
    );
  }
}

/// A plain quiet text button (`.btn-ghost` without the block subcopy / border).
class ObQuietButton extends StatelessWidget {
  const ObQuietButton({
    super.key,
    required this.p,
    required this.label,
    required this.onPressed,
    this.enabled = true,
  });
  final OnboardingPalette p;
  final String label;
  final VoidCallback onPressed;

  /// When false the button dims + ignores taps (e.g. a sibling primary action is in flight).
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: TextButton.styleFrom(
        foregroundColor: p.ink2,
        textStyle: p.chrome(size: 14, weight: FontWeight.w500),
      ),
      onPressed: enabled ? onPressed : null,
      child: Text(label),
    );
  }
}
