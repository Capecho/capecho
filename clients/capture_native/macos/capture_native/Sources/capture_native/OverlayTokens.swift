//
//  OverlayTokens.swift
//  capture_native
//
//  Warm-glass palette + metrics for the native overlay. TRANSCRIBED from
//  shared/design-tokens/generated/CapechoDesignTokens.swift — keep in sync until
//  the generator pipeline is wired into the native build (follow-up). Do NOT
//  hand-tune values; the TS generator + its drift test are the source of truth.
//

import AppKit

/// The `--ovl-*` warm-glass colors for one appearance (light or dark).
struct OverlayPalette {
  let tint: NSColor
  let edge: NSColor
  let ink: NSColor
  let ink2: NSColor
  let ink3: NSColor
  let divider: NSColor
  let rule: NSColor
  let saveEdge: NSColor
  let activeFg: NSColor
  let activeBg: NSColor
  let accent: NSColor
  /// Semantic error/alert tone (the `--error` token, #8a2a1e) — the overlay's
  /// one non-warm accent, used ONLY for the "Word or phrase required"
  /// validation (eyebrow + field border). Same value in both appearances, per
  /// the design tokens.
  let alert: NSColor

  static let light = OverlayPalette(
    tint: srgb(0.9647, 0.949, 0.9255, 0.72),
    edge: srgb(1, 0.9843, 0.9608, 0.58),
    ink: srgb(0.1412, 0.1098, 0.0902, 1),
    ink2: srgb(0.4157, 0.3569, 0.3137, 1),
    ink3: srgb(0.6118, 0.5529, 0.502, 1),
    divider: srgb(0.2431, 0.1765, 0.1333, 0.14),
    rule: srgb(0.2431, 0.1765, 0.1333, 0.34),
    saveEdge: srgb(0.2431, 0.1765, 0.1333, 0.4),
    activeFg: srgb(0.1725, 0.1294, 0.102, 1),
    activeBg: srgb(0.2431, 0.1765, 0.1333, 0.1),
    accent: srgb(0.3922, 0.2902, 0.251, 1),
    alert: srgb(0.5412, 0.1647, 0.1176, 1))

  static let dark = OverlayPalette(
    tint: srgb(0.1333, 0.102, 0.0824, 0.7),
    edge: srgb(1, 0.9725, 0.9412, 0.16),
    ink: srgb(0.9451, 0.9176, 0.8784, 1),
    ink2: srgb(0.7686, 0.7098, 0.6549, 1),
    ink3: srgb(0.5569, 0.498, 0.4471, 1),
    divider: srgb(0.9412, 0.9137, 0.8784, 0.12),
    rule: srgb(0.9412, 0.9137, 0.8784, 0.4),
    saveEdge: srgb(0.9412, 0.9137, 0.8784, 0.3),
    activeFg: srgb(0.9647, 0.9373, 0.902, 1),
    activeBg: srgb(0.9412, 0.9137, 0.8784, 0.12),
    accent: srgb(0.902, 0.7686, 0.6078, 1),
    alert: srgb(0.5412, 0.1647, 0.1176, 1))

  /// Resolves the palette for the overlay's effective appearance.
  static func resolve(_ appearance: NSAppearance) -> OverlayPalette {
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
  }

  /// The warm text-selection tint for the overlay's fields — DERIVED from `accent` (not a transcribed
  /// token yet; the B-final design replaces the saturated system-blue selection, the loudest colour on
  /// the "warm-tinted, not colourful" glass, DESIGN.md §Overlay). Slightly stronger on dark so the
  /// latte tint reads over the espresso glass. Formalizing this as `--ovl-selection` in design/tokens.css
  /// + the generator is a follow-up.
  var selectionTint: NSColor {
    accent.withAlphaComponent(accent.brightnessComponent > 0.5 ? 0.30 : 0.22)
  }

  private static func srgb(
    _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat
  ) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
  }
}

/// Overlay layout metrics (the `--ovl-*` / spacing / type-size scalars used by
/// the overlay), mirroring `CapechoDimens` from the generated tokens.
enum OverlayMetrics {
  static let padLr: CGFloat = 28
  static let padTop: CGFloat = 28
  static let padBottom: CGFloat = 22
  static let gapHeader: CGFloat = 16
  static let gapBottom: CGFloat = 22
  static let radius: CGFloat = 16

  /// Max height of the (scrollable) explanation region — past it the senses scroll instead of growing
  /// the panel off-screen (uncapped senses + a heteronym can run tall).
  static let explanationMaxHeight: CGFloat = 220

  static let displaySize: CGFloat = 32       // tDisplaySize
  static let bodySize: CGFloat = 16          // tBodySize — "overlay core meaning" (the headline definition)
  static let bodySmallSize: CGFloat = 15     // tBodySSize
  static let chromeSmallSize: CGFloat = 13   // tChromeSSize
  static let chromeMetaSize: CGFloat = 12    // tChromeMetaSize
  static let metaPillSize: CGFloat = 11      // tMetaPillSize
  static let metaTagSize: CGFloat = 10       // tMetaTagSize — captions (the footer AI credit)

  static let space2: CGFloat = 8
  static let space3: CGFloat = 12
  static let space4: CGFloat = 16
}
