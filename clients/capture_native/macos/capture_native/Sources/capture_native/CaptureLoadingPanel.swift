//
//  CaptureLoadingPanel.swift
//  capture_native
//
//  The brief "capturing…" loader shown DURING the OCR phase — between the hotkey's
//  screenshot (already secured) and the result overlay (CaptureOverlay). A small
//  warm-glass HUD, centered on the capture screen, whose only content is the brand
//  echo mark — the three concentric ripples ")))" (the app icon's three C's) — pulsing
//  OUTWARD as the working cue.
//
//  CRITICAL: it is shown from the engine's POST-screenshot callback, never before, so
//  it can't land in the OCR shot (the shot captures Capecho's own windows). It is
//  dismissed the instant the result overlay presents, so the handoff loader → overlay
//  is seamless. Shown only on the Screen-Recording OCR path (the slow part); the
//  SR-off direct-clipboard path never calls the engine, so it never shows.
//

import AppKit
import QuartzCore

/// Owns the loading HUD panel + its animated echo mark. One reused instance: `present()`
/// is idempotent (re-centers on the current capture screen, restarts the pulse) and
/// `dismiss()` hides it. Main-thread only (it touches AppKit).
final class CaptureLoadingController {
  private var panel: NSPanel?
  private var echo: EchoPulseView?
  private var safetyDismiss: DispatchWorkItem?

  /// The HUD content size — compact (Spotlight-result small), so it reads as a brief
  /// cue, not a window. Tunable.
  private static let panelSize = NSSize(width: 96, height: 88)
  private static let markSize = NSSize(width: 44, height: 32)

  /// Show the loader centered on the screen under the cursor (the screen the OCR
  /// captured). Idempotent. [safetySeconds] is a backstop auto-dismiss in case the
  /// result overlay somehow never presents (it always does — empty captures route to
  /// the editable overlay — so this only guards a pathological hang).
  func present(safetySeconds: TimeInterval = 6) {
    let panel = ensurePanel()
    let colors = OverlayPalette.resolve(panel.effectiveAppearance)
    applyPalette(colors)
    positionCentered(panel)
    // Non-key + ignores mouse: a transient cue must NOT steal focus from the app the
    // user is capturing, and clicks pass straight through to it.
    panel.orderFrontRegardless()
    echo?.startAnimating()

    safetyDismiss?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.dismiss() }
    safetyDismiss = work
    DispatchQueue.main.asyncAfter(deadline: .now() + safetySeconds, execute: work)
  }

  /// Hide the loader (the result overlay is taking over, or the safety timeout fired).
  /// A no-op if it was never shown (e.g. the SR-off path).
  func dismiss() {
    safetyDismiss?.cancel()
    safetyDismiss = nil
    echo?.stopAnimating()
    panel?.orderOut(nil)
  }

  // MARK: - Panel

  private func ensurePanel() -> NSPanel {
    if let panel { return panel }
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: Self.panelSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true  // system window shadow only (matches the overlay)
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    // Warm-glass surface — the same recipe as the overlay's root: blur + --ovl-tint
    // cast + --ovl-edge hairline, rounded to --ovl-radius.
    let root = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
    root.wantsLayer = true
    root.layer?.cornerRadius = OverlayMetrics.radius
    root.layer?.masksToBounds = true
    root.layer?.borderWidth = 1

    let blur = NSVisualEffectView(frame: root.bounds)
    blur.autoresizingMask = [.width, .height]
    blur.material = .hudWindow
    blur.blendingMode = .behindWindow
    blur.state = .active
    root.addSubview(blur)

    let tint = NSView(frame: root.bounds)
    tint.autoresizingMask = [.width, .height]
    tint.wantsLayer = true
    root.addSubview(tint)
    self.tintView = tint

    let echo = EchoPulseView(frame: .zero)
    echo.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(echo)
    NSLayoutConstraint.activate([
      echo.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      echo.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      echo.widthAnchor.constraint(equalToConstant: Self.markSize.width),
      echo.heightAnchor.constraint(equalToConstant: Self.markSize.height),
    ])

    panel.contentView = root
    self.panel = panel
    self.echo = echo
    return panel
  }

  private weak var tintView: NSView?

  private func applyPalette(_ colors: OverlayPalette) {
    panel?.contentView?.layer?.borderColor = colors.edge.cgColor
    tintView?.layer?.backgroundColor = colors.tint.cgColor
    echo?.accent = colors.accent
  }

  /// Center on the screen under the mouse, with the SAME slight upward bias as the
  /// result overlay (`positionCentered`) so the loader sits where the overlay will.
  private func positionCentered(_ panel: NSPanel) {
    let mouse = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
      ?? NSScreen.main
      ?? NSScreen.screens.first
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = Self.panelSize
    var origin = NSPoint(
      x: visible.midX - size.width / 2,
      y: visible.midY - size.height / 2 + visible.height * 0.08)
    if origin.y + size.height > visible.maxY { origin.y = visible.maxY - size.height }
    if origin.y < visible.minY { origin.y = visible.minY }
    panel.setFrame(NSRect(origin: origin, size: size), display: true)
  }
}

// MARK: - Echo mark (animated)

/// The brand echo mark animated as a loader: three C-shaped ripples (the app icon's
/// filled C's) in the warm --ovl-accent, lit by a coffee band that SWEEPS left → right
/// across the mark and loops — the "working" reading of the echo (DESIGN.md: motion =
/// working). This mirrors the cross-client `ObEchoLoader` so the capture HUD and the
/// app's loaders show one logo, one motion. A horizontal gradient layer (track → bright
/// → track) masked to the three arcs travels across them; Core Animation drives the
/// gradient's position (GPU-smooth, negligible CPU while the OCR runs off-main).
final class EchoPulseView: NSView {
  var accent: NSColor? { didSet { recolor() } }

  // The three C-strokes become a MASK on [clipLayer]; the coffee band lives in
  // [gradientLayer] (a sublayer of clipLayer, wider than the view) and slides left→right
  // underneath the stationary mask, so the band appears to sweep across the logo. A
  // layer's mask clips its whole sublayer subtree, so the moving gradient is clipped to
  // the arc shape while the mask itself stays put.
  private let clipLayer = CALayer()
  private let maskLayer = CAShapeLayer()
  private let gradientLayer = CAGradientLayer()
  private var animating = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    commonInit()
  }
  required init?(coder: NSCoder) {
    super.init(coder: coder)
    commonInit()
  }

  private func commonInit() {
    wantsLayer = true
    maskLayer.fillColor = NSColor.clear.cgColor
    maskLayer.strokeColor = NSColor.black.cgColor  // mask alpha only; colour is the gradient's
    maskLayer.lineCap = .round
    gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
    gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
    clipLayer.mask = maskLayer
    clipLayer.addSublayer(gradientLayer)
    layer?.addSublayer(clipLayer)
  }

  override func layout() {
    super.layout()
    layoutArcs()
  }

  private static let trough: Float = 0.28  // the track (dimmest) — the unfilled C's, never fully off

  // The brand echo mark, 1:1 from web/components/brand/echo-mark.tsx (viewBox 28×28): three
  // elliptical-arc ripples `M(mx,my) a rx ry 0 0 1 dx dy`, each under a per-path translate(tx,ty)
  // inside the group transform `translate(-3.08 -3.5) scale(1.25)`. Order is irrelevant now —
  // all three are unioned into one stationary mask the band sweeps across.
  private struct Ripple { let mx, my, rx, ry, dx, dy, tx, ty: CGFloat }
  private static let ripples: [Ripple] = [
    Ripple(mx: 10.5, my: 13, rx: 2.3, ry: 2.3, dx: 0, dy: -4, tx: -2.2, ty: 3),
    Ripple(mx: 15.5, my: 14.7, rx: 5, ry: 4.1, dx: 0, dy: -7.4, tx: -1.7, ty: 3),
    Ripple(mx: 21, my: 15.7, rx: 6.5, ry: 5.0, dx: 0, dy: -9.4, tx: -0.8, ty: 3),
  ]
  // stroke-width 1.6 on the <svg> × the group's scale(1.25) = 2.0 viewBox units.
  private static let strokeViewBox: CGFloat = 1.6 * 1.25

  /// Build the three brand ripples (in viewBox space), then uniformly fit their union into the view —
  /// centered, aspect-preserved, y-flipped (SVG y-down → layer y-up) — so the mark is a 1:1 replica of
  /// the logo at whatever size the panel/mark is.
  private func layoutArcs() {
    let b = bounds
    guard b.width > 2, b.height > 2 else { return }
    let vbPaths = Self.ripples.map { rippleViewBoxPath($0) }
    var union = CGRect.null
    for p in vbPaths { union = union.union(p.boundingBoxOfPath) }
    guard !union.isNull, union.width > 0, union.height > 0 else { return }
    let pad: CGFloat = 4
    let fit = min((b.width - 2 * pad) / union.width, (b.height - 2 * pad) / union.height)
    let scaledW = union.width * fit, scaledH = union.height * fit
    let offX = (b.width - scaledW) / 2, offY = (b.height - scaledH) / 2
    // viewBox (y-down) → layer (y-up): x' = fit·x + (offX − fit·minX); y' = h − offY − fit·(y − minY).
    var fitT = CGAffineTransform(
      a: fit, b: 0, c: 0, d: -fit,
      tx: offX - fit * union.minX,
      ty: b.height - offY + fit * union.minY)
    // One combined mask path = the three C-strokes (the stationary logo); the sweeping
    // gradient shows through it.
    let combined = CGMutablePath()
    for p in vbPaths { if let cp = p.copy(using: &fitT) { combined.addPath(cp) } }
    maskLayer.path = combined
    maskLayer.frame = b
    maskLayer.lineWidth = Self.strokeViewBox * fit
    clipLayer.frame = b
    // The band layer is 3× the view wide so it always covers the whole mark with at
    // least the track colour as it slides — only its bright middle (the coffee band)
    // crosses the arcs. (Disable implicit position animation so layout never fights the
    // sweep.)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradientLayer.bounds = CGRect(x: 0, y: 0, width: b.width * 3, height: b.height)
    gradientLayer.position = CGPoint(x: b.midX, y: b.midY)
    CATransaction.commit()
    recolor()
    if animating { startSweep() }
  }

  /// One ripple as a CGPath in the 28×28 viewBox space (the group + per-path transforms baked in).
  private func rippleViewBoxPath(_ r: Ripple) -> CGPath {
    let start = CGPoint(x: r.mx, y: r.my)
    let end = CGPoint(x: r.mx + r.dx, y: r.my + r.dy)
    let local = CGMutablePath()
    local.move(to: start)
    Self.appendSVGArc(local, from: start, to: end, rx: r.rx, ry: r.ry, largeArc: false, sweep: true)
    // path-local → viewBox: x' = 1.25·(x + tx) − 3.08 ; y' = 1.25·(y + ty) − 3.5.
    var m = CGAffineTransform(
      a: 1.25, b: 0, c: 0, d: 1.25,
      tx: 1.25 * r.tx - 3.08, ty: 1.25 * r.ty - 3.5)
    return local.copy(using: &m) ?? local
  }

  /// Append an SVG elliptical arc (x-axis-rotation 0) from [p1] to [p2] — the endpoint→center
  /// parameterization (SVG spec F.6.5), drawn as a unit-circle arc warped to the ellipse.
  private static func appendSVGArc(
    _ path: CGMutablePath, from p1: CGPoint, to p2: CGPoint,
    rx rxIn: CGFloat, ry ryIn: CGFloat, largeArc: Bool, sweep: Bool
  ) {
    var rx = abs(rxIn), ry = abs(ryIn)
    if rx == 0 || ry == 0 { path.addLine(to: p2); return }
    let dx2 = (p1.x - p2.x) / 2, dy2 = (p1.y - p2.y) / 2
    let lambda = (dx2 * dx2) / (rx * rx) + (dy2 * dy2) / (ry * ry)
    if lambda > 1 { let s = lambda.squareRoot(); rx *= s; ry *= s }
    let sign: CGFloat = (largeArc != sweep) ? 1 : -1
    let num = max(0, rx * rx * ry * ry - rx * rx * dy2 * dy2 - ry * ry * dx2 * dx2)
    let den = rx * rx * dy2 * dy2 + ry * ry * dx2 * dx2
    let coef = den == 0 ? 0 : sign * (num / den).squareRoot()
    let cxp = coef * (rx * dy2 / ry)
    let cyp = coef * (-ry * dx2 / rx)
    let cx = cxp + (p1.x + p2.x) / 2
    let cy = cyp + (p1.y + p2.y) / 2
    func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
      let dot = ux * vx + uy * vy
      let len = ((ux * ux + uy * uy) * (vx * vx + vy * vy)).squareRoot()
      var a = len == 0 ? 0 : acos(min(1, max(-1, dot / len)))
      if (ux * vy - uy * vx) < 0 { a = -a }
      return a
    }
    let ux = (dx2 - cxp) / rx, uy = (dy2 - cyp) / ry
    let vx = (-dx2 - cxp) / rx, vy = (-dy2 - cyp) / ry
    let theta1 = angle(1, 0, ux, uy)
    var dTheta = angle(ux, uy, vx, vy)
    if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
    if sweep && dTheta < 0 { dTheta += 2 * .pi }
    let ellipse = CGAffineTransform(translationX: cx, y: cy).scaledBy(x: rx, y: ry)
    path.addArc(
      center: .zero, radius: 1, startAngle: theta1, endAngle: theta1 + dTheta,
      clockwise: dTheta < 0, transform: ellipse)
  }

  private func recolor() {
    let bright = accent ?? NSColor.secondaryLabelColor
    let track = bright.withAlphaComponent(CGFloat(Self.trough))  // the unfilled C's
    // track → coffee band → track, the bright concentrated in the middle of the 3×-wide
    // layer so a soft band (~the mark's width) sweeps across the arcs.
    gradientLayer.colors = [track.cgColor, bright.cgColor, track.cgColor]
    gradientLayer.locations = [0.34, 0.5, 0.66]
  }

  func startAnimating() {
    animating = true
    layoutArcs()  // (re)builds the mask + band, then kicks off the sweep via `animating`
  }

  /// Slide the band left → right across the mark, looping. At both ends the bright middle
  /// sits off the mark (only track shows), so the loop's reset is invisible — a seamless
  /// continuous sweep. Mirrors `ObEchoLoader`'s 1.5s cadence.
  private func startSweep() {
    let w = bounds.width
    guard w > 0 else { return }
    gradientLayer.removeAnimation(forKey: "echoSweep")
    let sweep = CABasicAnimation(keyPath: "position.x")
    sweep.fromValue = -0.15 * w  // bright peak just left of the mark
    sweep.toValue = 1.15 * w     // …to just right of it
    sweep.duration = 1.5
    sweep.repeatCount = .infinity
    sweep.timingFunction = CAMediaTimingFunction(name: .linear)
    gradientLayer.add(sweep, forKey: "echoSweep")
  }

  func stopAnimating() {
    animating = false
    gradientLayer.removeAnimation(forKey: "echoSweep")
  }
}
