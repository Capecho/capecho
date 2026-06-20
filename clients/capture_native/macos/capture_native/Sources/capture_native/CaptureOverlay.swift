//
//  CaptureOverlay.swift
//  capture_native
//
//  The native warm-glass capture overlay (two-field + inline edit). Renders one
//  capture in a floating, key-able NSPanel styled from the shared `--ovl-*` design
//  tokens (OverlayTokens). Implements (per US-5.1 / CAP-1 / CAP-2 / OVL-1/2/3/8):
//
//    - Two fields: UNIT (word/phrase, required) + CONTEXT (sentence, optional)
//      (CAP-1) — both visually-quiet inline-edit text controls (OVL-2/OVL-8).
//    - Save is always actionable; attempting to save with an empty unit reveals
//      the alert-toned "Word or phrase required" eyebrow + a field border until
//      a unit is typed; a context-less save is allowed (CAP-1).
//    - Tab focus chain: unit → context → target chip (when shown) → Save (OVL-3); Enter saves
//      (in any field; Option-Enter inserts a newline in the context view);
//      Esc dismisses.
//    - Select-in-context → unit (CAP-2): a non-empty selection inside the
//      context surfaces a small "set as word" chip — centered BELOW the
//      selection — that, on click, promotes the trimmed/snapped span into the
//      unit field. The chip hides when the sentence loses focus or the selection
//      collapses. Trim leading/trailing whitespace + punctuation;
//      punctuation-only/empty = no-op; space-delimited targets snap to word
//      boundaries, CJK/no-space targets take the trimmed span as-is.
//    - Target-language chip — shows the capture's target and (Phase 2) a one-tap
//      switch when the span was detected as a different same-script language. The
//      gloss (explanation) language follows the account setting; the per-capture
//      `Explain in ▾` picker was removed (users never changed it per-capture).
//    - Saved confirmation: brief "● Saved" dwell (~700ms), then auto-dismiss.
//
//  Flutter-agnostic on purpose: the plugin hands this controller plain values
//  + closures. Auto-routing of a single captured blob into unit vs context
//  (the "shape-routing" of CAP-1) happens in the SHARED Dart reconstruction
//  core; this controller only renders what it is given and returns the user's
//  corrections in OverlaySaveRequest.
//

import AppKit

/// The immutable model the plugin hands the overlay for one capture.
struct OverlayCapture {
  let unit: String
  let context: String
  let source: String  // "ocr" | "selection" | "clipboard"
  /// BCP-47 TARGET tag — the language being learned, the default for this capture. The target chip
  /// can switch it (Phase 2) when [suggestedTargetLanguage] (or the user) picks another; gates the
  /// explanation allowlist + cache and is what Save persists. The user's configured learning language
  /// is unchanged — a switch is per-capture.
  let defaultTargetLanguage: String
  /// BCP-47 CONFIGURED learning-language tag (pre script-auto-switch). The overlay re-derives the capture
  /// target from THIS whenever the unit changes (a "set as word" promotion or an inline edit), so
  /// attribution follows the word the user ends up with — not the originally-captured one. Distinct from
  /// [defaultTargetLanguage], the initial (possibly already-auto-switched) target.
  let learningLanguage: String
  /// BCP-47 EXPLANATION (gloss) tag — the language a meaning is rendered IN — from the account/device
  /// setting. Fixed for the capture (the per-capture picker was removed); a target switch re-fetches
  /// `/explain` in this gloss language for the new target. The captured `defaultTargetLanguage` is
  /// separate (what is being learned).
  let defaultExplanationLanguage: String
  /// True when this unit is already in the user's Word Book (Dart checked the
  /// local store before presenting) — the overlay surfaces an "already saved"
  /// cue so a re-capture isn't indistinguishable from a first capture (bug #6).
  /// Save stays active: re-saving adds this sentence as a new context (the unit
  /// is immutable, contexts are 1:N).
  let alreadySaved: Bool
  /// A target language the captured SPAN was confidently detected to be, when it
  /// differs from [defaultTargetLanguage] (Phase 2 — e.g. reading a Spanish passage
  /// while learning English). The target chip surfaces it as a one-tap switch
  /// suggestion; nil = no suggestion. Never auto-applied — the user confirms.
  let suggestedTargetLanguage: String?
  /// The captured SPAN's confidently-detected BCP-47 language + [0,1] confidence (from capture-time
  /// recognition). Cached so the overlay can re-evaluate the same-script suggestion when the unit changes
  /// (set as word / edit) without re-running detection; nil language → none detected.
  let detectedSpanLanguage: String?
  let detectedSpanLanguageConfidence: Double
  /// Capture-source provenance ("where I met this word"): the owning app's name and the captured
  /// window's title. Display-neutral metadata the overlay carries verbatim into Save (it never edits
  /// or shows them); nil when the capture couldn't resolve them.
  let sourceApp: String?
  let sourceTitle: String?
}

/// The values the overlay returns when the user commits Save (post-edit).
struct OverlaySaveRequest {
  let unit: String
  let context: String?
  let targetLanguage: String
  let source: String
  /// Capture-time provenance + detected language, copied straight from the capture (NOT user-edited)
  /// so Save persists where the word was met alongside the (possibly edited) unit/context.
  let sourceApp: String?
  let sourceTitle: String?
  let detectedLanguage: String?
  let detectedLanguageConfidence: Double?
}

// MARK: - Panel

/// A borderless panel that can still become key, so the overlay receives the
/// Save (⏎) / dismiss (Esc) key events even though the app is an agent.
final class CaptureOverlayPanel: NSPanel {
  /// Invoked when the user presses Esc (the standard `cancelOperation:` path).
  var onCancel: (() -> Void)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  // Esc → dismiss. AppKit routes the Escape key to `cancelOperation(_:)` on
  // the key window's responder chain; a HIDDEN button's key-equivalent never
  // fires, so we handle it on the panel itself (PR3b-1 review: both models).
  override func cancelOperation(_ sender: Any?) {
    onCancel?()
  }

  // A click on the overlay's empty background — anything not a field, button, or
  // the "set as word" chip, all of which consume their own clicks — bubbles up
  // the responder chain to the window. Resign first responder so clicking away
  // from an input defocuses it (and, via the sentence view's focus-change hook,
  // clears its selection + hides the chip). super still runs so dragging the
  // window by its background (isMovableByWindowBackground) keeps working.
  override func mouseDown(with event: NSEvent) {
    makeFirstResponder(nil)
    super.mouseDown(with: event)
  }
}

// MARK: - Quiet inline-edit primitives (OVL-2)

/// A single-line NSTextField that looks like plain text at rest and reveals a
/// subtle warm-tinted background when focused. The "quiet inline edit"
/// affordance per OVL-2: visually de-emphasized correction, available but
/// non-shouting, because most captures are correct.
final class QuietTextField: NSTextField {
  /// Notified with the new focus state on become-first-responder / end-editing. The controller uses it to
  /// intensify the unit's wrapping inset box (Variant B, #3/#4) on focus — the box, not the field, carries
  /// the fill + border, so the field itself stays transparent and borderless.
  var onFocusChange: ((Bool) -> Void)?

  /// A vertically-CENTRED placeholder rendered as a sibling label, NOT NSTextField's own
  /// `placeholderString` — the native placeholder draws at the large 32pt field-font baseline, so a small
  /// 19pt prompt reads as low / not centred (#4) AND its size clashed with the field-editor caret on focus
  /// (the "line-height wrong on activation" jump). This label is sized to the prompt, centred in the field,
  /// and shown only when the field is empty + unfocused — so focusing simply hides it (no 19-vs-32 clash).
  var centeredPlaceholder: NSAttributedString? {
    didSet {
      rebuildPlaceholderLabel()
      updatePlaceholderVisibility()
    }
  }
  private var placeholderLabel: NSTextField?
  private var focusedNow = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configure()
  }
  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }

  private func configure() {
    isBordered = false
    isBezeled = false
    drawsBackground = false
    focusRingType = .none
    // Single-line mode stabilises the field editor's vertical metrics (part of the #6 line-height fix).
    usesSingleLineMode = true
  }

  override func becomeFirstResponder() -> Bool {
    let ok = super.becomeFirstResponder()
    if ok {
      focusedNow = true
      updatePlaceholderVisibility()
      onFocusChange?(true)
    }
    return ok
  }

  override func textDidEndEditing(_ notification: Notification) {
    super.textDidEndEditing(notification)
    focusedNow = false
    updatePlaceholderVisibility()
    onFocusChange?(false)
  }

  /// Show the centred placeholder only when empty + unfocused. NSTextField has no `didChangeText` hook, so
  /// the controller also calls this from `controlTextDidChange`.
  func updatePlaceholderVisibility() {
    placeholderLabel?.isHidden = focusedNow || !stringValue.isEmpty
  }

  private func rebuildPlaceholderLabel() {
    placeholderLabel?.removeFromSuperview()
    guard let ph = centeredPlaceholder else {
      placeholderLabel = nil
      setAccessibilityPlaceholderValue(nil)
      return
    }
    setAccessibilityPlaceholderValue(ph.string)
    let label = NSTextField(labelWithAttributedString: ph)
    label.setAccessibilityElement(false)  // the field exposes the placeholder via the a11y attribute
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor),
      // Cap the label to the field width so a narrow field (wide language chip) truncates rather than
      // overflowing into the picker.
      label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    placeholderLabel = label
  }

  // The placeholder label sits above the editable area; forward a click on it to the field so the empty
  // field still focuses (mirrors QuietTextView).
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === placeholderLabel ? self : hit
  }
}

/// A multi-line NSTextView that wraps without a visible scroll view, sizes
/// itself to its content so the overlay panel can grow to fit, and shows a
/// focused-state background tint matching QuietTextField. Supports a quiet
/// placeholder (hidden when the view has text OR is focused). Enter (Return)
/// is intercepted by the controller's delegate and dispatched as Save.
final class QuietTextView: NSTextView {
  var palette: OverlayPalette? { didSet { applyFocusBackground(isFocusedNow) } }
  var placeholderString: String? {
    didSet { setupPlaceholderIfNeeded(); updatePlaceholderVisibility() }
  }
  /// Notified with the new focus state on become/resign first responder. The
  /// controller uses the resign edge to dismiss the floating "set as word" chip
  /// when the sentence loses focus (overlay UX #2).
  var onFocusChange: ((Bool) -> Void)?

  private var isFocusedNow = false
  private var placeholderLabel: NSTextField?

  override var intrinsicContentSize: NSSize {
    guard let lm = layoutManager, let tc = textContainer else {
      return NSSize(width: NSView.noIntrinsicMetric, height: 30)
    }
    lm.ensureLayout(for: tc)
    let used = lm.usedRect(for: tc)
    return NSSize(
      width: NSView.noIntrinsicMetric,
      height: ceil(used.height) + textContainerInset.height * 2 + 2)
  }

  override func becomeFirstResponder() -> Bool {
    let ok = super.becomeFirstResponder()
    if ok {
      isFocusedNow = true
      applyFocusBackground(true)
      updatePlaceholderVisibility()
      onFocusChange?(true)
    }
    return ok
  }

  override func resignFirstResponder() -> Bool {
    let ok = super.resignFirstResponder()
    if ok {
      isFocusedNow = false
      applyFocusBackground(false)
      updatePlaceholderVisibility()
      onFocusChange?(false)
    }
    return ok
  }

  override func didChangeText() {
    super.didChangeText()
    invalidateIntrinsicContentSize()
    updatePlaceholderVisibility()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    // The placeholder label sits above the editable text view. If it receives
    // the click, AppKit treats it as a dead label instead of focusing the empty
    // sentence field, so forward that hit back to the text view.
    if hit === placeholderLabel {
      return self
    }
    return hit
  }

  private func applyFocusBackground(_ focused: Bool) {
    // Variant B (#3/#4): the wrapping scroll's inset box now carries the fill + border, so the text view no
    // longer paints its own focus background — doing both would stack two fills inside the one box.
    wantsLayer = true
    layer?.cornerRadius = 6
  }

  private func setupPlaceholderIfNeeded() {
    guard placeholderString != nil, placeholderLabel == nil else { return }
    let label = NSTextField(labelWithString: placeholderString ?? "")
    label.font = self.font
    label.textColor = NSColor.placeholderTextColor
    label.translatesAutoresizingMaskIntoConstraints = false
    // VoiceOver should ignore the sibling label — the text view itself
    // exposes the placeholder via NSAccessibility.placeholderValue below.
    label.setAccessibilityElement(false)
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(
        equalTo: leadingAnchor, constant: textContainerInset.width + 2),
      label.topAnchor.constraint(
        equalTo: topAnchor, constant: textContainerInset.height + 1),
    ])
    placeholderLabel = label
  }

  private func updatePlaceholderVisibility() {
    let placeholder = placeholderString ?? ""
    // a11y: NSTextView surfaces the placeholder via the standard
    // `placeholderValue` accessibility attribute, which VoiceOver reads as
    // the field's placeholder when value is empty (subagent review M4).
    setAccessibilityPlaceholderValue(placeholder)
    guard let label = placeholderLabel else { return }
    label.stringValue = placeholder
    label.isHidden = !string.isEmpty || isFocusedNow
  }
}

// MARK: - Pill button (always-visible chip)

/// A flat pill-shaped button with an explicit, solid background — for the
/// "set as word" floating chip near the sentence text. The system `.recessed` /
/// `.inline` styles draw too faint a chrome (or none) for the chip to read
/// against the warm-glass tint with text behind it.
///
/// Fires its action on mouseDown (see `mouseDown`) so the click lands before the
/// focus change it provokes can hide the chip or collapse the selection.
///
/// Foreground is chosen by luminance so the chip stays readable across the
/// light/dark palettes — the accent flips from dark-brown to warm-cream and a
/// fixed text color would lose contrast in one of the modes.
final class PillButton: NSButton {
  private var fillColor: NSColor = .controlAccentColor
  private var textColor: NSColor = .white
  private let horizontalPadding: CGFloat = 10
  private let verticalPadding: CGFloat = 3
  private var trackingArea: NSTrackingArea?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configure()
  }
  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }

  private func configure() {
    isBordered = false
    bezelStyle = .regularSquare
    wantsLayer = true
    setButtonType(.momentaryChange)
    focusRingType = .none
  }

  /// Repaint with the appearance-specific colors + font and refresh the
  /// attributed title. Call AFTER setting the title; calling again with
  /// different colors is safe (e.g. on theme change).
  func style(background: NSColor, font: NSFont) {
    fillColor = background
    textColor = Self.contrastingForeground(for: background)
    self.font = font
    layer?.backgroundColor = background.cgColor
    refreshAttributedTitle()
    invalidateIntrinsicContentSize()
    needsDisplay = true
  }

  override var title: String {
    didSet { refreshAttributedTitle() }
  }

  private func refreshAttributedTitle() {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .foregroundColor: textColor,
        .font: font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        .paragraphStyle: para,
      ])
  }

  override var intrinsicContentSize: NSSize {
    let base = super.intrinsicContentSize
    return NSSize(
      width: base.width + horizontalPadding * 2,
      height: base.height + verticalPadding * 2)
  }

  override func layout() {
    super.layout()
    // Full-pill radius: half the height so the ends are perfect half-circles.
    layer?.cornerRadius = bounds.height / 2
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let existing = trackingArea {
      removeTrackingArea(existing)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    layer?.backgroundColor = fillColor.blended(withFraction: 0.15, of: .white)?.cgColor
      ?? fillColor.cgColor
  }

  override func mouseExited(with event: NSEvent) {
    layer?.backgroundColor = fillColor.cgColor
  }

  // Fire on PRESS, not release. This chip floats over the context text view; a
  // normal click would resign the text view's first responder (collapsing the
  // selection) and trip the blur/selection-change handlers that hide the chip —
  // racing the action. Acting on mouseDown promotes the cached selection BEFORE
  // any of that runs, so the chip can be safely hidden on blur + empty selection
  // (overlay UX #2) without the click ever being eaten.
  override func mouseDown(with event: NSEvent) {
    guard isEnabled, let action = action else { return }
    _ = NSApp.sendAction(action, to: target, from: self)
  }

  /// Pick a high-contrast text color for [bg] using a luminance threshold; lets
  /// one PillButton class work across the light and dark accent values.
  private static func contrastingForeground(for bg: NSColor) -> NSColor {
    let srgb = bg.usingColorSpace(.sRGB) ?? bg
    let lum = 0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent
    return lum > 0.55
      ? NSColor(srgbRed: 0.10, green: 0.08, blue: 0.07, alpha: 1)
      : .white
  }
}

// MARK: - Warm-mono chrome buttons (Save + language)

/// A flat, OUTLINED, warm-mono button — no accent fill — drawn from the `--ovl-*`
/// tokens. The overlay is shadowless warm glass, so the system default-button
/// (accent-filled, pulsing) and the standard push/popup bezels are off-style
/// (DESIGN.md: Save is "ink text, no fill"; the
/// language control is a quiet outlined `.ovl-lang` chip). Subclasses only differ
/// in their attributed title; the chrome (1px ink hairline border, no fill,
/// padding, rounded corners) is shared here.
class OverlayChromeButton: NSButton {
  /// Horizontal / vertical padding added around the title (set by subclasses).
  var hPad: CGFloat = 10
  var vPad: CGFloat = 5
  var corner: CGFloat = 7

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureChrome()
  }
  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureChrome()
  }

  private func configureChrome() {
    isBordered = false
    bezelStyle = .regularSquare
    setButtonType(.momentaryChange)
    wantsLayer = true
    layer?.borderWidth = 1
    layer?.backgroundColor = NSColor.clear.cgColor
    // A focusable control in the Tab chain — keep a focus ring so keyboard users
    // can see where they are (the stock controls drew one; the flat layer would
    // otherwise be silent under keyboard focus).
    focusRingType = .default
  }

  /// Repaint the hairline border for [palette]. Subclasses call this from their
  /// own `apply(palette:)` after setting the attributed title.
  func styleBorder(_ color: NSColor) {
    layer?.borderColor = color.cgColor
  }

  override var intrinsicContentSize: NSSize {
    let base = super.intrinsicContentSize
    return NSSize(width: base.width + hPad * 2, height: base.height + vPad * 2)
  }

  override func layout() {
    super.layout()
    layer?.cornerRadius = corner
  }

  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds, xRadius: corner, yRadius: corner).fill()
  }
  override var focusRingMaskBounds: NSRect { bounds }
}

/// The Save action: an outlined button with the word "Save" + a quiet `⏎` hint and no accent fill.
/// On a successful save it switches to "● Saved" — the brand 6px ink-dot
/// (DESIGN.md §Saved indicator) appears ONLY here, on commit (#7), where it means "saved"; the idle /
/// blocked button carries no dot.
final class OverlaySaveButton: OverlayChromeButton {
  private var colors: OverlayPalette?
  private var saved = false

  func apply(palette: OverlayPalette) {
    colors = palette
    hPad = 14
    vPad = 7
    corner = 8
    restyle()
  }

  /// Switch to the post-save "Saved" rendering (dot stays lit; no ⏎ hint).
  func markSaved() {
    saved = true
    isEnabled = false  // triggers restyle()
  }

  override var isEnabled: Bool {
    didSet { restyle() }
  }

  private func restyle() {
    guard let c = colors else { return }
    styleBorder(isEnabled ? c.saveEdge : c.divider)
    attributedTitle = Self.title(saved: saved, enabled: isEnabled, colors: c)
    invalidateIntrinsicContentSize()
    needsDisplay = true
  }

  private static func title(
    saved: Bool, enabled: Bool, colors c: OverlayPalette
  ) -> NSAttributedString {
    let textColor = enabled ? c.ink : c.ink3
    let hintColor = enabled ? c.ink2 : c.ink3
    let textFont = NSFont.systemFont(ofSize: OverlayMetrics.chromeSmallSize, weight: .semibold)
    let hintFont = NSFont.systemFont(ofSize: OverlayMetrics.metaPillSize, weight: .regular)
    let m = NSMutableAttributedString()
    if saved {
      // The brand "saved" ink-dot (DESIGN.md §Saved indicator) appears ONLY on commit (#7) — here it MEANS
      // "saved". The idle / blocked button is a clean "Save · ⏎" with no dot.
      let dotFont = NSFont.systemFont(ofSize: 9, weight: .black)
      m.append(NSAttributedString(
        string: "●", attributes: [.foregroundColor: c.accent, .font: dotFont, .baselineOffset: 0.5]))
      m.append(NSAttributedString(
        string: "  Saved", attributes: [.foregroundColor: textColor, .font: textFont]))
    } else {
      m.append(NSAttributedString(
        string: "Save", attributes: [.foregroundColor: textColor, .font: textFont]))
      m.append(NSAttributedString(
        string: "   ⏎", attributes: [.foregroundColor: hintColor, .font: hintFont]))
    }
    return m
  }
}

/// The target-language chip, rendered as the quiet `.ovl-lang` chip: a monochrome outlined chip with no
/// accent and no key-hint. Clicking (or Return/Space when focused) pops the target-language menu; the
/// controller owns the menu + selection. (This class also rendered the `Explain in ▾` gloss picker until
/// it was removed — a control users never touched per-capture; the gloss language now follows the
/// account/device setting, and the AI credit moved to a quiet "✨ AI" mark on the explanation.)
final class OverlayLanguageButton: OverlayChromeButton {
  private var colors: OverlayPalette?

  func apply(
    palette: OverlayPalette,
    displayName: String,
    toolTip: String? = nil
  ) {
    colors = palette
    hPad = 9
    vPad = 4
    corner = 7
    styleBorder(palette.saveEdge)
    self.toolTip = toolTip
    setDisplayName(displayName)
  }

  func setDisplayName(_ name: String) {
    guard let c = colors else { return }
    let nameFont = NSFont.systemFont(ofSize: OverlayMetrics.chromeSmallSize, weight: .semibold)
    let m = NSMutableAttributedString()
    // The language name, then an SF Symbol chevron (not the literal "▾", #7) — the name + caret + the
    // hover tooltip carry the control's meaning, so there is no text prefix.
    m.append(NSAttributedString(
      string: name, attributes: [.foregroundColor: c.ink, .font: nameFont]))
    m.append(NSAttributedString(string: " "))
    m.append(Self.caretAttachment(color: c.ink2, font: nameFont))
    attributedTitle = m
    invalidateIntrinsicContentSize()
    needsDisplay = true
  }

  /// Toggle the Phase-2 suggestion accent: a quiet accent-coloured border that draws
  /// the eye to a detected target-language switch. Resting border (saveEdge) when off.
  func setSuggested(_ on: Bool) {
    guard let c = colors else { return }
    styleBorder(on ? c.accent : c.saveEdge)
  }

  /// The dropdown indicator as a small SF Symbol `chevron.down` rendered in [color] — a proper glyph,
  /// since the literal "▾" character read as odd (#7). Falls back to the text caret if the symbol can't
  /// load (it always should on macOS 11+).
  private static func caretAttachment(color: NSColor, font: NSFont) -> NSAttributedString {
    let cfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
      .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    guard
      let img = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg)
    else {
      return NSAttributedString(string: "▾", attributes: [.foregroundColor: color])
    }
    let attach = NSTextAttachment()
    attach.image = img
    // Centre the chevron on the adjacent text's cap-height midpoint — attachments otherwise sit on the
    // baseline, so it read as too low / not centred (#1). `bounds.y` offsets the image bottom from the
    // baseline, so y = (capHeight − imageHeight) / 2 puts the glyph's centre at capHeight/2.
    let y = (font.capHeight - img.size.height) / 2
    attach.bounds = NSRect(x: 0, y: y, width: img.size.width, height: img.size.height)
    return NSAttributedString(attachment: attach)
  }
}

// (OverlayAudioButton removed — tap-to-hear audio is deferred; the overlay shows US/UK IPA only.)

// MARK: - Controller

/// Owns the overlay panel and its (re)build. One controller instance is reused
/// across captures (the plugin calls `present` each time).
final class CaptureOverlayController: NSObject, NSTextFieldDelegate, NSTextViewDelegate {

  /// Called when the user commits Save. The closure validates + durably
  /// appends and reports back `(success, errorMessage?)`.
  var onSave: ((OverlaySaveRequest, @escaping (Bool, String?) -> Void) -> Void)?
  /// Called when the overlay is dismissed (Esc or post-save auto-dismiss).
  var onDismiss: (() -> Void)?
  /// Called when the user needs a fresh free-explanation fetch for the shown unit — on a target-language
  /// switch, a unit edit, or Retry after a failed fetch. Carries the target (gates the allowlist + cache)
  /// and the gloss language. The plugin round-trips this to Dart's `/explain`; the result comes back via
  /// `applyExplanation`. Without it, a target switch would leave the slot blank and the failed-state Retry
  /// would be inert.
  var onRequestExplanation:
    ((_ unit: String, _ targetLanguage: String, _ explanationLanguage: String) -> Void)?

  /// When non-nil, forces the overlay to the Capecho app's Light/Dark theme (#2) instead of following the
  /// OS. Set by the plugin from the `brightness` arg before each present() and applied to the panel, so
  /// the warm-glass palette, the field editor caret, scrollers, and the language menu all match. nil =
  /// follow the OS appearance (ThemeMode.system, resolved in Dart). palette() reads the panel's resulting
  /// effectiveAppearance, so setting this is all that's needed.
  var appearanceOverride: NSAppearance?

  private static let panelWidth: CGFloat = 460

  // The target-language menu (BCP-47 tag, native display name) for the target chip — the languages a
  // capture can be attributed to + explained in. Mirrors capture-core's `supportedTargetLanguages` so the
  // chip never offers a target the backend can't gloss; the names mirror the shared `langName`. A seeded
  // out-of-menu tag (the current target, or a detected suggestion) stays selectable (see showTargetMenu).
  // Keep in sync with that set; the full searchable picker is post-MVP.
  private static let targetLanguages: [(tag: String, name: String)] = [
    ("en", "English"),
    ("zh-Hans", "简体中文"),
    ("es", "Español"),
    ("de", "Deutsch"),
    ("it", "Italiano"),
    ("fr", "Français"),
    ("pt", "Português"),
    ("ja", "日本語"),
    ("ko", "한국어"),
  ]

  /// The lang-unsupported message (the overlay note slot). Hoisted to a
  /// constant so the wording is greppable when M1 wires `/explain` and may
  /// reconcile the copy with the live-explanation states (09/10).
  private static let langUnsupportedMessage =
    "Meaning not available for this language yet. "
    + "You can still save, review, and export this word."

  /// In-flight free explanation.
  private static let explanationLoadingMessage = "Generating the meaning with AI…"

  /// The free explanation couldn't be fetched here. Honest + calm: the word still saves and the Word
  /// Book fetches its explanation later.
  private static let explanationFailedMessage =
    "Couldn’t load the meaning here — it’ll be in your Word Book."

  /// The captured unit isn't a word — caught locally (junk / keyboard-mash), so no `/explain` was
  /// spent. Calm + honest: nothing to explain, but capture isn't blocked (照常入库、仅不查).
  private static let notAWordMessage =
    "This doesn’t look like a word — nothing to explain. You can still save it."

  /// In-flight in-context preview (E2) — the opt-in "Explain in this sentence" fetch.
  private static let contextPreviewLoadingMessage = "Explaining in this sentence…"

  /// The shared daily context-explanation cap is spent.
  private static let contextQuotaMessage =
    "Daily explanation limit reached — you can still save, review, and export this word."

  /// The in-context preview couldn't be generated. Calm: the word still saves.
  private static let contextFailedMessage =
    "Couldn’t explain this word in the sentence — you can still save it."

  /// The in-context preview is account-only and the caller is signed out (or the session expired). Calm:
  /// the value of an account (the free daily allowance), paired with a "Sign in" button; the word still
  /// saves either way.
  private static let contextNeedsLoginMessage =
    "Explaining a word in your sentence is free with an account — 10 a day. You can still save this word."

  /// The ready card's text content as a single a11y label (Phase 1): each part of speech and its
  /// senses, read in order — e.g. "noun: a friendly greeting. verb: to greet someone gladly."
  private static func explanationReadyText(_ exp: OverlayExplanation) -> String {
    var parts: [String] = []
    for reading in exp.readings {
      for pos in reading.pos {
        parts.append("\(pos.label): \(pos.senses.joined(separator: "; ")).")
      }
    }
    return parts.joined(separator: " ")
  }

  // Views — recreated per present() via rebuildContent().
  private var panel: CaptureOverlayPanel?
  private var current: OverlayCapture?
  private var unitField: QuietTextField?
  /// The faint inset box wrapping the unit field (Variant B, #3/#4): it — not the field — carries the
  /// rest/focus inset styling and the empty-unit alert border, so the editable headword reads as an input
  /// distinct from the flat AI explanation below it.
  private var unitFieldBox: NSView?
  /// Whether the unit field currently holds focus, so clearing the empty-unit alert restores the box to the
  /// correct (focused vs. rest) inset look rather than always the rest look.
  private var unitFocused = false
  private var contextView: QuietTextView?
  /// The scroll view wrapping `contextView` — the sentence field auto-grows with
  /// content up to a 3-line cap, then scrolls (overlay UX). `contextHeightConstraint`
  /// is the cap-clamped height driven by `updateContextHeight`.
  private var contextScrollView: NSScrollView?
  /// The faint inset box wrapping the sentence scroll (Variant B, #3) — a plain NSView, like the unit box,
  /// because styling the NSScrollView's OWN layer is clobbered by `drawsBackground=false` (the empty field
  /// then showed no background). This box carries the rest/focus inset styling reliably.
  private var contextFieldBox: NSView?
  private var contextHeightConstraint: NSLayoutConstraint?
  /// The target-language chip (Phase 2). Shows the capture target; when a different
  /// same-script language was detected for the span it surfaces a one-tap switch
  /// suggestion. An `OverlayLanguageButton` chip — no AI mark (a language choice, not AI).
  private var targetButton: OverlayLanguageButton?
  /// The pending target suggestion shown on [targetButton] (the span's detected
  /// language ≠ current target), or nil when there's none / it was accepted.
  private var suggestedTargetTag: String?
  /// The capture's target language (the language being learned). Seeded in present() from
  /// `OverlayCapture.defaultTargetLanguage`; the target chip can switch it when the span was detected to
  /// be a different language (Phase 2). Gates the explanation allowlist + cache and is what Save persists.
  private var targetLanguage: String = "en"
  /// The user's CONFIGURED learning language (pre script-auto-switch), seeded from
  /// `OverlayCapture.learningLanguage`. `revalidateTargetForUnitChange` re-derives the target from this
  /// baseline whenever the unit changes, so attribution follows the word rather than the original capture.
  private var learningLanguage: String = "en"
  /// The captured span's detected language + confidence (cached from capture-time recognition), reused to
  /// re-evaluate the same-script suggestion on a unit change without re-running detection.
  private var spanLanguage: String?
  private var spanLanguageConfidence: Double = 0
  /// True once the user EXPLICITLY picks a target from the chip menu. A same-script unit edit then keeps
  /// their choice; only a script-disjoint unit, or a fresh "set as word", overrides / resets it.
  private var targetManuallyChosen = false
  /// The EXPLANATION (gloss) language — the language a meaning is rendered IN. Follows the account/device
  /// setting (seeded from `defaultExplanationLanguage` in present()); there is no per-capture picker, so it
  /// is fixed for the capture and just read by the explain + context-preview requests.
  private var selectedExplanationTag: String = "en"
  private var saveButton: OverlaySaveButton?
  /// Footer status slot — hidden at rest, used only for the "● Saved"
  /// confirmation and inline save-error messages (the resting "Capecho · esc
  /// dismiss" chrome was removed — overlay UX #5).
  private var blockHintLabel: NSTextField?
  /// The footer "Generated with AI" credit (B-final: one card-level credit in the footer covers ALL
  /// generated content — definition + in-context gloss — instead of a caption row pinned mid-card under
  /// the definition). Hidden until any AI content is actually on the card.
  private var aiCreditLabel: NSTextField?
  /// The calm "this word isn't in the sentence" advisory below the Sentence field (capture issue 3) —
  /// hidden at rest, shown (ink2, non-alert) only when a non-empty sentence doesn't contain the unit.
  /// Non-blocking: Save still works; the stored highlight just drops (the reader re-searches).
  private var unitNotInSentenceLabel: NSTextField?
  /// The "Word or phrase / required" eyebrow above the unit field — hidden at
  /// rest, revealed (alert-toned) only on a save attempt with an empty unit
  /// (overlay UX #5).
  private var unitEyebrowRow: NSView?
  /// Tracks whether the unit-required validation is currently shown, so toggling
  /// it only relayouts/announces on an actual edge.
  private var unitRequiredShown = false
  private var setAsWordButton: NSButton?
  /// The TOP explanation region (region A), directly under the headword: one `US /…/ UK /…/ · pos` line
  /// per reading + the one-sentence summary headline when ready, or the loading / failed /
  /// langUnsupported note. A vertical stack rebuilt per state. Its leading divider (`topDivider`) hides
  /// with it.
  private var topSlot: NSStackView?
  /// Scrolls `topSlot` once the senses exceed `explanationMaxHeight` (uncapped senses + a heteronym can
  /// run tall); below that the scroll hugs its content. Hidden in lockstep with `topSlot`.
  private var topScrollView: NSScrollView?
  /// The divider below `topSlot` — hidden whenever `topSlot` is hidden so an empty top collapses cleanly.
  private var topDivider: NSView?
  /// The in-context "Explain in this sentence" line inside the Sentence block — the explain trigger
  /// button (idle), spinner (loading), gloss (ready), quota note, or failed note + Retry. Driven by
  /// `renderContextPreviewLine` from `contextPreview` + whether a sentence is present.
  private var contextPreviewLine: NSStackView?
  /// The footer "Dictionary" (system Look Up) button — hidden when there is no unit to look up.
  private var dictionaryButton: NSView?
  /// The last-applied slot state — drives resize/announce dedupe and the
  /// allowlist guard on pushed live states.
  private var explanationState: ExplanationSlotState = .hidden
  /// Fired when the user taps the opt-in "Explain in this sentence" button (E2 / concern #3). Carries
  /// the headword + the CURRENT sentence (so the gloss matches what a later Save would persist) + the
  /// target. The host runs the metered `POST /explain/context/preview` and pushes the result back via
  /// `applyContextPreview`; nil = the host hasn't wired it (the button stays hidden).
  var onRequestContextPreview:
    ((_ unit: String, _ contextText: String, _ targetLanguage: String, _ explanationLanguage: String) -> Void)?
  /// Fired when the user taps the "Sign in" button on the signed-out in-context preview prompt
  /// (`.needsLogin`). The host brings the app forward and opens the in-app sign-in surface; the overlay
  /// itself dismisses first (it's a floating panel that would otherwise cover that window). nil = the
  /// host hasn't wired it (the button is still shown, but tapping it only dismisses).
  var onRequestSignIn: (() -> Void)?
  /// The in-context preview result shown below the ready card's actions row (E2). Reset to `.idle` on
  /// each new capture + on each fresh `/explain` fetch (a different word's gloss must never linger).
  private var contextPreview: ContextPreviewSlot = .idle
  /// The unit the in-flight/last context preview was requested for. The overlay is reused across
  /// captures, so a late preview result paints ONLY if the shown word still matches (else a capture-B
  /// card would show capture-A's in-context gloss).
  private var contextPreviewUnit: String?
  // GCD (not Timer): `Timer.scheduledTimer` runs in the RunLoop's `.default`
  // mode, which a key NSPanel from an LSUIElement agent can park out of — the
  // dwell would set "Saved" but never fire dismiss. GCD main-queue is
  // mode-agnostic (PR3b-1 fix).
  private var dismissWorkItem: DispatchWorkItem?
  // Monotonic token bumped on every present/dismiss/save. The Save callback
  // captures the epoch at dispatch and bails if it has changed by the time
  // the platform replies — otherwise a stale "● Saved + 700ms dismiss" or a
  // stale error would mutate (and auto-dismiss) a NEW overlay opened in the
  // interim (subagent review H2).
  private var saveEpoch: UInt64 = 0
  // The CAP-2 promotion candidate captured AT THE MOMENT the floating "set as
  // word" chip became eligible. We cache the (range, promoted-string) pair when
  // the chip is shown and consume it when the chip is clicked, rather than
  // reading `tv.selectedRange` inside `promoteSelectionToUnit` — the cache is
  // stable across the focus change the click provokes. Cleared on
  // dismiss/present/save/unit-edit, on non-eligible selections, on
  // selection→zero, and when the sentence loses focus. (The chip fires on
  // mouseDown, so it consumes the candidate before any of those clears it.)
  private var promotionCandidate: (range: NSRange, promoted: String)?
  // Debounce + dedup for re-glossing while the user EDITS the unit field: a pause in typing re-fetches
  // /explain for the edited unit (capture issue 2) without spending a call on every keystroke or
  // re-fetching an unchanged unit. `lastRequestedExplanationUnit` is seeded with the captured unit (the
  // host already fetched that one), so merely focusing the field — no change — doesn't re-fetch.
  private var explainDebounceWorkItem: DispatchWorkItem?
  private var lastRequestedExplanationUnit: String?

  // MARK: - Present

  /// Shows (or re-shows) the overlay for [capture]. Must be called on the main
  /// thread.
  func present(_ capture: OverlayCapture) {
    dismissWorkItem?.cancel()
    dismissWorkItem = nil
    saveEpoch &+= 1  // any in-flight Save callback is now stale.
    promotionCandidate = nil
    current = capture
    targetLanguage = capture.defaultTargetLanguage.isEmpty ? "en" : capture.defaultTargetLanguage
    learningLanguage = capture.learningLanguage.isEmpty ? "en" : capture.learningLanguage
    spanLanguage = capture.detectedSpanLanguage
    spanLanguageConfidence = capture.detectedSpanLanguageConfidence
    targetManuallyChosen = false
    // The capture-time suggestion (validated: a real, different target). buildHeaderRow seeds the chip from
    // this; revalidateTargetForUnitChange recomputes it whenever the unit changes.
    let initialSuggestion = capture.suggestedTargetLanguage
    suggestedTargetTag =
      (initialSuggestion?.isEmpty == false && initialSuggestion != targetLanguage) ? initialSuggestion : nil
    selectedExplanationTag =
      capture.defaultExplanationLanguage.isEmpty ? "en" : capture.defaultExplanationLanguage
    explanationState = .hidden
    // A reused overlay must open fresh: clear any prior in-context preview so capture B never shows
    // capture A's gloss.
    contextPreview = .idle
    contextPreviewUnit = nil
    // The captured unit's explanation is fetched by the host (Dart `explainFor`); a subsequent EDIT is
    // what triggers a native re-gloss. Seed the captured unit as "already requested" so a no-op focus /
    // caret move doesn't re-fetch (capture issue 2), and drop any pending debounce from a prior capture.
    explainDebounceWorkItem?.cancel()
    explainDebounceWorkItem = nil
    lastRequestedExplanationUnit = capture.unit.isEmpty ? nil : capture.unit

    let panel = ensurePanel()
    // Apply the app-theme override (#2) BEFORE building content, so palette() (which resolves from the
    // panel's effectiveAppearance) and every system-drawn part are consistent. nil = follow the OS.
    panel.appearance = appearanceOverride
    rebuildContent(for: capture, in: panel)
    // Lay out once so the sentence scroll view has its real width, then size it to
    // a pre-filled context (wrapping at that width) BEFORE centering — otherwise a
    // multi-line captured sentence would open at one line and jump on first edit.
    panel.contentView?.layoutSubtreeIfNeeded()
    updateContextHeight()
    positionCentered(panel)

    // Do NOT activate the app (bug #2): a `.nonactivatingPanel` that
    // `canBecomeKey` receives Esc/⏎ + typing from `makeKeyAndOrderFront` alone,
    // WITHOUT pulling Capecho — and any open Settings / Word Book window — to the
    // front. Activating here stole focus from the app the user was reading: after
    // Esc the Capecho window surfaced and interrupted them. The selection
    // highlight was already sampled before this, so no activation is needed.
    panel.makeKeyAndOrderFront(nil)

    // Make the unit field the initial first responder so the user can
    // immediately type to correct (state 07/08) or fill in (state 12). When
    // the unit is pre-populated, select all so a single keystroke replaces it
    // (US-5.1: "the detected unit is preselected").
    if let field = unitField {
      panel.makeFirstResponder(field)
      // Warm selection tint (B-final): the preselected headword opened wearing the saturated
      // system-blue highlight — the loudest colour on the "warm-tinted, not colourful" glass
      // (DESIGN.md §Overlay). The shared field editor takes the accent-derived tint instead; the
      // select-all affordance itself is unchanged.
      if let editor = panel.fieldEditor(true, for: field) as? NSTextView {
        editor.selectedTextAttributes[.backgroundColor] = palette().selectionTint
      }
      if !capture.unit.isEmpty {
        field.currentEditor()?.selectAll(nil)
      }
    }
  }

  /// Dismisses the overlay without saving.
  @objc func dismiss() {
    dismissWorkItem?.cancel()
    dismissWorkItem = nil
    explainDebounceWorkItem?.cancel()
    explainDebounceWorkItem = nil
    saveEpoch &+= 1  // any in-flight Save callback is now stale.
    promotionCandidate = nil
    panel?.orderOut(nil)
    onDismiss?()
  }

  // MARK: - Panel lifecycle

  private func ensurePanel() -> CaptureOverlayPanel {
    if let panel { return panel }
    let panel = CaptureOverlayPanel(
      contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 240),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true  // system window shadow only (DESIGN.md / memo)
    panel.isMovableByWindowBackground = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.onCancel = { [weak self] in self?.dismiss() }
    self.panel = panel
    return panel
  }

  private func palette() -> OverlayPalette {
    OverlayPalette.resolve(panel?.effectiveAppearance ?? NSApp.effectiveAppearance)
  }

  // MARK: - Content build

  private func rebuildContent(for capture: OverlayCapture, in panel: CaptureOverlayPanel) {
    let colors = palette()

    // Reset transient view refs (the panel's contentView is about to be
    // replaced, detaching the prior tree).
    unitField = nil
    unitFieldBox = nil
    unitFocused = false
    contextView = nil
    contextScrollView = nil
    contextFieldBox = nil
    contextHeightConstraint = nil
    targetButton = nil
    saveButton = nil
    blockHintLabel = nil
    aiCreditLabel = nil
    unitEyebrowRow = nil
    unitRequiredShown = false
    setAsWordButton = nil
    topSlot = nil
    topScrollView = nil
    topDivider = nil
    contextPreviewLine = nil
    dictionaryButton = nil

    // Root container — a rounded, warm-tinted glass surface.
    let root = NSView()
    root.wantsLayer = true
    root.layer?.cornerRadius = OverlayMetrics.radius
    root.layer?.masksToBounds = true

    let blur = NSVisualEffectView()
    blur.material = .hudWindow
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(blur)

    // Warm tint over the blur (the `--ovl-tint` cast — the token appearance,
    // not the raw system material).
    let tint = NSView()
    tint.wantsLayer = true
    tint.layer?.backgroundColor = colors.tint.cgColor
    tint.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(tint)

    // Content column (top → bottom), B-final:
    //   unit-required eyebrow | headword + Learning | already-saved cue |
    //   TOP explanation (one `US /…/ UK /…/ · noun` line per reading + the 16px summary headline) · rule |
    //   Sentence (field + gloss callout + "Sentence meaning" disclosure) · rule |
    //   footer (Dictionary · "Generated with AI" · Save).
    // `detachesHiddenViews` drops a hidden region AND its trailing custom spacing AND its divider (an
    // empty top on a bare capture, langUnsupported) with no residual gap.
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = OverlayMetrics.space2
    stack.detachesHiddenViews = true
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)

    // The "Word or phrase / required" eyebrow is HIDDEN at rest (overlay UX #5)
    // — the headword field leads. It is revealed in the alert tone, with a
    // matching field border, only on a save attempt with an empty unit
    // (setUnitRequired). `detachesHiddenViews` drops it + its spacing while
    // hidden, so the resting overlay opens straight on the headword.
    let unitEyebrow = buildEyebrow(
      text: "Word or phrase", mark: "required", colors: colors, color: colors.alert)
    unitEyebrow.isHidden = true
    unitEyebrowRow = unitEyebrow
    stack.addArrangedSubview(unitEyebrow)

    let headerRow = buildHeaderRow(capture: capture, colors: colors)
    stack.addArrangedSubview(headerRow)
    headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    stack.setCustomSpacing(OverlayMetrics.space3, after: headerRow)

    // Source affordance — only the "already in your Word Book" cue is kept
    // (bug #6). The resting "From OCR/selection · click to correct" meta-line
    // was noise (overlay UX #5); the inline-edit affordance (focus reveals the
    // field) carries "you can correct this" without a line of chrome.
    if capture.alreadySaved {
      let affLine = buildSourceAffordance(for: capture, colors: colors)
      stack.addArrangedSubview(affLine)
      stack.setCustomSpacing(OverlayMetrics.space3, after: affLine)
    }

    // TOP explanation region (region A) directly under the headword + its divider. Built empty;
    // `renderExplanationSlot` fills it and toggles it + `topDivider`. Wrapped in a vertical scroll that
    // hugs its content but caps at `explanationMaxHeight` — past the cap the senses scroll instead of
    // growing the panel off-screen (uncapped senses + a heteronym can run tall).
    let top = buildTopSlot()
    let topScroll = NSScrollView()
    topScroll.drawsBackground = false
    topScroll.borderType = .noBorder
    topScroll.hasVerticalScroller = true
    topScroll.hasHorizontalScroller = false
    topScroll.autohidesScrollers = true
    topScroll.scrollerStyle = .overlay
    topScroll.documentView = top
    topScroll.translatesAutoresizingMaskIntoConstraints = false
    topScrollView = topScroll
    stack.addArrangedSubview(topScroll)
    topScroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    // The senses (documentView) fill the scroll width and grow downward; rows wrap to this width.
    NSLayoutConstraint.activate([
      top.leadingAnchor.constraint(equalTo: topScroll.contentView.leadingAnchor),
      top.topAnchor.constraint(equalTo: topScroll.contentView.topAnchor),
      top.widthAnchor.constraint(equalTo: topScroll.widthAnchor),
    ])
    // Hug the content height, but never exceed the cap (then it scrolls). The hug is below-required so
    // it yields to the cap without a broken-constraint warning.
    let topHug = topScroll.heightAnchor.constraint(equalTo: top.heightAnchor)
    topHug.priority = .defaultHigh
    topHug.isActive = true
    topScroll.heightAnchor.constraint(
      lessThanOrEqualToConstant: OverlayMetrics.explanationMaxHeight
    ).isActive = true
    stack.setCustomSpacing(OverlayMetrics.space3, after: topScroll)
    let topRule = makeDivider(colors: colors)
    stack.addArrangedSubview(topRule)
    topRule.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    stack.setCustomSpacing(OverlayMetrics.space3, after: topRule)
    topDivider = topRule

    let contextBlock = buildContextBlock(capture: capture, colors: colors)
    stack.addArrangedSubview(contextBlock)
    contextBlock.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    stack.setCustomSpacing(OverlayMetrics.space3, after: contextBlock)

    // Divider between the Sentence and the footer — always present (the Sentence + footer always
    // show), so the footer never butts straight against the sentence field.
    let sentenceRule = makeDivider(colors: colors)
    stack.addArrangedSubview(sentenceRule)
    sentenceRule.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    stack.setCustomSpacing(OverlayMetrics.space3, after: sentenceRule)

    let footer = buildFooterRow(colors: colors)
    stack.addArrangedSubview(footer)
    footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

    // Both regions + dividers now exist: settle the resting explanation state (hidden until /explain
    // lands — D3: langUnsupported only ever arrives from the server) and the Sentence's
    // explain-in-context line BEFORE centering, so the initial size is right.
    renderExplanationSlot(.hidden, notifyResize: false)
    renderContextPreviewLine()
    refreshDictionaryVisibility()

    // The "set as word" floating chip — child of root, positioned manually
    // CENTERED BELOW the context selection (overlay UX #3) so it never overlaps
    // the selected word, even when that word is right-most on its line. Uses
    // PillButton (a solid chip) so it reads clearly against the warm-glass text;
    // the system `.inline` / `.recessed` bezels were too faint.
    let setBtn = PillButton(
      title: "set as word", target: self, action: #selector(promoteSelectionToUnit))
    setBtn.style(
      background: colors.accent,
      font: chromeFont(size: OverlayMetrics.metaPillSize, weight: .semibold))
    setBtn.isHidden = true
    // Frame-positioned (see showSetAsWordButton), not constraint-driven — so the
    // explicit frame stays authoritative across layout passes.
    setBtn.translatesAutoresizingMaskIntoConstraints = true
    // A spelled-out a11y label reads better than the bare "set as word" title.
    setBtn.setAccessibilityLabel("Set selection as the word")
    root.addSubview(setBtn)
    setAsWordButton = setBtn

    // Close (✕) pinned to the card's top-right corner, ABOVE the centered language chip (padTop=28 leaves
    // room) — so it reads as a corner close, not a third item in the header row.
    let closeBtn = buildCloseButton(colors: colors)
    closeBtn.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(closeBtn)

    NSLayoutConstraint.activate([
      closeBtn.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
      // The ✕ is a borderless glyph centered in an invisible box with vPad=3 / hPad=6, so the
      // VISIBLE gap is the constant plus that pad. Top gap = 6 + 3 = 9; match it on the right with
      // 3 + hPad(6) = 9 so the glyph sits an equal 9pt from both edges (was -16 → a 22pt right gap).
      closeBtn.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -3),
      blur.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      blur.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      blur.topAnchor.constraint(equalTo: root.topAnchor),
      blur.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      tint.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      tint.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      tint.topAnchor.constraint(equalTo: root.topAnchor),
      tint.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: OverlayMetrics.padLr),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -OverlayMetrics.padLr),
      stack.topAnchor.constraint(equalTo: root.topAnchor, constant: OverlayMetrics.padTop),
      stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -OverlayMetrics.padBottom),
      root.widthAnchor.constraint(equalToConstant: Self.panelWidth),
    ])

    panel.contentView = root

    // Tab focus chain: unit → context → [target chip, only when shown] → save → unit (OVL-3). (Buttons
    // participate only when "Full Keyboard Access" is set to "All controls" in System Settings → Keyboard.
    // The explicit nextKeyView chain is still honored.) Rebuilt whenever the chip's visibility changes.
    rewireFocusChain()

    // No default-button cell: the warm-mono Save is a flat outlined button, NOT
    // the system accent-filled default button (mockup: "ink text, no fill").
    // Enter is dispatched per-control instead — the unit field (NSControl
    // delegate) and the context view (NSTextView delegate) both intercept
    // `insertNewline:` and call `handleSave`, and the Save button fires on its
    // own Return/click. (`defaultButtonCell` left nil.)

    // Initial state: clear any stale unit-required validation + paint the
    // unit-mark underline in the context.
    updateSaveEnabled()
    refreshUnitMark()
  }

  // MARK: - Sub-views

  /// An eyebrow label + optional marker. [color] overrides the resting ink2
  /// tone — used for the alert-toned "Word or phrase required" validation (#5).
  /// Eyebrows rest in ink-2, NEVER ink-3 (DESIGN.md §Overlay: "ink-3 is
  /// illegible on translucent glass over a busy desktop" — a binding rule this
  /// factory previously violated).
  private func buildEyebrow(
    text: String, mark: String?, colors: OverlayPalette, color: NSColor? = nil
  ) -> NSView {
    let tone = color ?? colors.ink2
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .firstBaseline
    row.spacing = OverlayMetrics.space2

    let title = NSTextField(labelWithString: text)
    title.font = chromeFont(size: OverlayMetrics.chromeMetaSize, weight: .medium)
    title.textColor = tone
    title.isSelectable = true  // #9: section labels are copyable
    row.addArrangedSubview(title)

    if let mark, !mark.isEmpty {
      let pill = NSTextField(labelWithString: mark)
      pill.font = chromeFont(size: OverlayMetrics.metaPillSize, weight: .regular)
      pill.textColor = tone
      pill.isSelectable = true  // #9
      row.addArrangedSubview(pill)
    }
    return row
  }

  /// Paint a field's wrapping inset box for Variant B (#3/#4): a faint `--ovl-active-bg` fill + 1px border
  /// + 8px radius that reads as "editable input". The border strengthens on focus (saveEdge vs divider) so
  /// the active field is legible without the loud system focus ring. `alert == true` paints the empty-unit
  /// validation border instead. `box.wantsLayer` must already be true.
  private func styleInsetBox(_ box: NSView?, focused: Bool, alert: Bool = false, colors: OverlayPalette) {
    guard let layer = box?.layer else { return }
    layer.cornerRadius = 8
    layer.backgroundColor = colors.activeBg.cgColor
    if alert {
      layer.borderWidth = 1.5
      layer.borderColor = colors.alert.cgColor
    } else {
      // A clearly-visible saveEdge border at REST too (#8) so the field reads as an input BEFORE focus —
      // the faint divider border was invisible, so the sentence box looked border-less until activated.
      // Focus thickens it to 1.5px as the active cue (alongside the caret) — no colour change.
      layer.borderWidth = focused ? 1.5 : 1
      layer.borderColor = colors.saveEdge.cgColor
    }
  }

  private func buildHeaderRow(capture: OverlayCapture, colors: OverlayPalette) -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    // Vertically CENTER the small target-language chip against the large serif
    // headword (overlay UX #4). Baseline-aligning a chip-height control to a
    // 32pt display line dropped it well below the headword's centre.
    row.alignment = .centerY
    row.distribution = .fill
    row.spacing = OverlayMetrics.space4

    // Unit field — large serif, quiet inline edit, placeholder when empty.
    let field = QuietTextField()
    field.font = serifFont(size: OverlayMetrics.displaySize, weight: .medium)
    field.textColor = colors.ink
    field.stringValue = capture.unit
    // The empty prompt is a QUIET, vertically-CENTRED hint at 19pt (#1 + #4) — not the 32pt headword size
    // (which filled the panel and truncated to "Set the word or") and centred in the box rather than
    // sitting at the big-font baseline. A typed unit still renders at the full 32pt.
    field.centeredPlaceholder = NSAttributedString(
      string: "Set the word or phrase…",
      attributes: [
        .font: serifFont(size: 19, weight: .medium),
        .foregroundColor: colors.ink3,
      ])
    field.lineBreakMode = .byTruncatingTail
    field.delegate = self
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    unitField = field

    // Variant B (#3/#4): the editable unit sits in a faint inset box so it reads as an input, distinct
    // from the flat AI explanation below it. The BOX (not the field) carries the rest/focus styling + the
    // empty-unit alert border; the field is transparent inside it, padded so the text isn't flush to the
    // edge. The box stretches to fill the row; the language chip keeps its intrinsic width.
    let unitBox = NSView()
    unitBox.wantsLayer = true
    unitBox.translatesAutoresizingMaskIntoConstraints = false
    unitBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
    unitBox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.translatesAutoresizingMaskIntoConstraints = false
    unitBox.addSubview(field)
    // Fixed single-line height (#6): pin the field to its natural line height so the box height is
    // CONSTANT across the empty placeholder, focus (field editor), and typed text — it was "jumping" on
    // activation. Box height resolves to this + the 4pt top/bottom padding.
    let unitLineHeight = ceil(
      NSLayoutManager().defaultLineHeight(
        for: field.font ?? NSFont.systemFont(ofSize: OverlayMetrics.displaySize)))
    NSLayoutConstraint.activate([
      field.leadingAnchor.constraint(equalTo: unitBox.leadingAnchor, constant: 10),
      field.trailingAnchor.constraint(equalTo: unitBox.trailingAnchor, constant: -10),
      field.topAnchor.constraint(equalTo: unitBox.topAnchor, constant: 4),
      field.bottomAnchor.constraint(equalTo: unitBox.bottomAnchor, constant: -4),
      field.heightAnchor.constraint(equalToConstant: unitLineHeight),
    ])
    unitFieldBox = unitBox
    styleInsetBox(unitBox, focused: false, colors: colors)
    // Focus intensifies the box border — but yields to the empty-unit alert border while that is showing.
    field.onFocusChange = { [weak self] focused in
      guard let self else { return }
      self.unitFocused = focused
      // Re-gloss only when the unit field LOSES focus — fetching /explain on every keystroke (even
      // debounced) is too frequent (overlay UX). The initial captured-unit gloss is fired host-side, so
      // this covers EDITS. refreshExplanationForEditedUnit() no-ops when the unit is empty/unchanged or
      // the target isn't allowlisted, so it's safe to call before the required-unit guard below.
      if !focused { self.refreshExplanationForEditedUnit() }
      guard !self.unitRequiredShown else { return }
      self.styleInsetBox(self.unitFieldBox, focused: focused, colors: self.palette())
    }

    // Target-language chip (Phase 2) — the capture's target. Shown ONLY when a switch needs confirming: a
    // same-script span difference surfaces here as a one-tap suggestion (accent border + the name with a
    // "?"). A script-certain language (中文 while learning English) switches SILENTLY with no chip —
    // nothing to confirm. The chip re-derives whenever the unit changes (set as word / edit). No AI
    // mark — a language choice, not AI; the gloss language follows the account setting.
    let targetBtn = OverlayLanguageButton(frame: .zero)
    targetBtn.apply(
      palette: colors, displayName: Self.displayName(for: targetLanguage), toolTip: "Capture language")
    targetBtn.setContentHuggingPriority(.required, for: .horizontal)
    targetBtn.target = self
    targetBtn.action = #selector(showTargetMenu(_:))
    targetBtn.setAccessibilityRole(.popUpButton)
    targetButton = targetBtn

    row.addArrangedSubview(unitBox)
    row.addArrangedSubview(targetBtn)
    // A hidden (no-suggestion) chip collapses cleanly so the header keeps no gap.
    row.detachesHiddenViews = true
    // Seed the chip's label / accent / visibility from the capture-time suggestion (hidden when none).
    applyTarget(targetLanguage, suggestion: suggestedTargetTag)
    return row
  }

  /// The close (✕) — pinned to the card's TOP-RIGHT CORNER (not inline with the language chip), a
  /// borderless warm-glass glyph in keeping with the quiet chrome (like the disclosure chevron).
  /// Click/tap dismisses (mirrors Esc); stays in the Tab chain for keyboard users.
  private func buildCloseButton(colors: OverlayPalette) -> NSButton {
    let btn = OverlayChromeButton()
    btn.hPad = 6
    btn.vPad = 3
    btn.layer?.borderWidth = 0
    btn.attributedTitle = NSAttributedString(
      string: "✕",
      attributes: [
        .foregroundColor: colors.ink2,
        .font: chromeFont(size: OverlayMetrics.bodySmallSize, weight: .medium),
      ])
    btn.target = self
    btn.action = #selector(closeTapped)
    btn.setAccessibilityLabel("Close")
    return btn
  }

  /// The corner ✕ — an explicit dismiss, mirroring Esc / the post-save auto-dismiss.
  @objc private func closeTapped() { dismiss() }

  /// Display name for a BCP-47 target tag from the fixed menu, or the raw tag when it
  /// is a seeded out-of-menu language (so it is never silently relabeled).
  private static func displayName(for tag: String) -> String {
    targetLanguages.first { $0.tag == tag }?.name ?? tag
  }

  /// Pops the TARGET-language menu under the target chip (Phase 2) — the supported targets,
  /// with the current one checked and the detected suggestion annotated. Selecting routes to
  /// `targetMenuPicked` → `selectTargetLanguage`.
  @objc private func showTargetMenu(_ sender: Any?) {
    guard let button = targetButton else { return }
    let menu = NSMenu()
    var tags = Self.targetLanguages.map { $0.tag }
    // Keep the current target + a suggested out-of-list tag selectable (don't strand the user).
    if !targetLanguage.isEmpty, !tags.contains(targetLanguage) { tags.append(targetLanguage) }
    if let s = suggestedTargetTag, !s.isEmpty, !tags.contains(s) { tags.append(s) }
    for tag in tags {
      let title = tag == suggestedTargetTag
        ? "\(Self.displayName(for: tag)) — detected"
        : Self.displayName(for: tag)
      let item = NSMenuItem(
        title: title, action: #selector(targetMenuPicked(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = tag
      item.state = (tag == targetLanguage) ? .on : .off
      menu.addItem(item)
    }
    let origin = NSPoint(x: 0, y: button.bounds.height + 4)
    menu.popUp(positioning: nil, at: origin, in: button)
  }

  @objc private func targetMenuPicked(_ sender: NSMenuItem) {
    guard let tag = sender.representedObject as? String else { return }
    selectTargetLanguage(tag)
  }

  /// Apply a TARGET-language switch the user picked from the chip menu (Phase 2): mark it a manual choice
  /// (so a later same-script unit edit keeps it), resolve the chip (no pending suggestion → it tucks away),
  /// and re-request the explanation in the new target (the allowlist + cache are keyed by target, so a
  /// stale gloss would otherwise remain). Save now persists the new target. Only THIS capture's target
  /// changes — the user's configured learning language is untouched.
  private func selectTargetLanguage(_ tag: String) {
    let changed = tag != targetLanguage
    targetManuallyChosen = true
    applyTarget(tag, suggestion: nil)
    guard changed else { return }
    // A target switch makes any in-context gloss stale (generated for the old target).
    if clearStaleContextPreview() { renderContextPreviewLine() }
    if !currentUnit().isEmpty {
      // Optimistic loading during the Dart round-trip; the fetch result replaces it (D3: no client
      // allowlist — the server's language_unsupported drives the langUnsupported note).
      renderExplanationSlot(.loading, notifyResize: true)
      onRequestExplanation?(currentUnit(), targetLanguage, selectedExplanationTag)
    } else {
      // Empty unit: settle the resting slot.
      refreshExplanationSlot()
    }
  }

  /// Apply a target + optional pending suggestion to the chip in one place: update `targetLanguage` +
  /// `suggestedTargetTag`, set the chip's label / accent / tooltip / a11y, show the chip ONLY when a
  /// suggestion is pending (otherwise the language is certain — nothing to confirm — so it stays hidden,
  /// per "don't show the box when no confirmation is needed"), and re-wire the focus chain around the
  /// chip's new visibility. Does NOT itself re-gloss — callers do.
  private func applyTarget(_ target: String, suggestion: String?) {
    targetLanguage = target
    let pending = (suggestion?.isEmpty == false) ? suggestion : nil
    suggestedTargetTag = pending
    guard let btn = targetButton else { return }
    if let s = pending {
      btn.isHidden = false
      btn.setSuggested(true)
      btn.setDisplayName("\(Self.displayName(for: s))?")
      btn.toolTip = "Looks like \(Self.displayName(for: s)) — tap to capture as that language"
      btn.setAccessibilityLabel(
        "Capture language \(Self.displayName(for: target)); detected "
          + "\(Self.displayName(for: s)) — activate to switch")
    } else {
      btn.isHidden = true
      btn.setSuggested(false)
      btn.setDisplayName(Self.displayName(for: target))
      btn.toolTip = "Capture language"
      btn.setAccessibilityLabel("Capture language \(Self.displayName(for: target))")
    }
    rewireFocusChain()
  }

  /// Re-derive the capture target + suggestion from the CURRENT unit after it changes (a "set as word"
  /// promotion or an inline edit), so attribution follows the word the user actually ends up with — done
  /// natively + synchronously (no Dart round-trip), so the chip updates the instant the unit changes.
  ///
  /// A script-disjoint unit (中文 while learning English) switches with deterministic certainty and shows
  /// NO chip; a same-script span difference (a Spanish word in an English passage) becomes a suggestion.
  /// `resetManual` is true on "set as word" (a brand-new word — drop any prior manual pick) and false on
  /// an in-place edit (keep a target the user explicitly confirmed for this same word). The span language
  /// is the cached capture-time detection (the sentence the unit sits in), reused without re-detecting.
  private func revalidateTargetForUnitChange(resetManual: Bool) {
    if resetManual { targetManuallyChosen = false }
    let unit = currentUnit()
    let effective = UnitLanguage.effectiveTargetLanguage(unit: unit, learningLanguage: learningLanguage)
    let newTarget: String
    let newSuggestion: String?
    if effective != learningLanguage {
      // Script-disjoint → a deterministic different language: switch certainly, no confirmation, and drop
      // any manual pick (a Han unit isn't the Spanish the user may have chosen for a prior word).
      newTarget = effective
      targetManuallyChosen = false
      newSuggestion = nil
    } else if targetManuallyChosen {
      // Same script + the user confirmed a target for this word → keep it; only re-evaluate the suggestion.
      newTarget = targetLanguage
      newSuggestion = UnitLanguage.suggestedTargetLanguage(
        unit: unit, effectiveTarget: targetLanguage,
        spanLanguage: spanLanguage, spanLanguageConfidence: spanLanguageConfidence)
    } else {
      // Same script, no manual pick → settle on the configured learning language; suggest if the span
      // reads as a different supported same-script language.
      newTarget = learningLanguage
      newSuggestion = UnitLanguage.suggestedTargetLanguage(
        unit: unit, effectiveTarget: learningLanguage,
        spanLanguage: spanLanguage, spanLanguageConfidence: spanLanguageConfidence)
    }
    // Skip the chip churn when nothing actually changed (the common keystroke case).
    guard newTarget != targetLanguage || newSuggestion != suggestedTargetTag else { return }
    applyTarget(newTarget, suggestion: newSuggestion)
  }

  /// (Re)build the Tab focus chain around the target chip's current visibility: unit → context →
  /// [target chip, only when visible] → save → unit. A hidden chip (no pending suggestion) is skipped so
  /// Tab never lands on an invisible control.
  private func rewireFocusChain() {
    guard let u = unitField, let c = contextView, let s = saveButton else { return }
    if let t = targetButton, !t.isHidden {
      u.nextKeyView = c
      c.nextKeyView = t
      t.nextKeyView = s
      s.nextKeyView = u
    } else {
      u.nextKeyView = c
      c.nextKeyView = s
      s.nextKeyView = u
    }
  }

  /// Re-gloss the current unit, or reset to the resting slot when there is no real unit. Skips a
  /// re-fetch when the unit is unchanged since the last request.
  private func refreshExplanationForEditedUnit() {
    let unit = currentUnit()
    guard UnitNormalization.hasWordContent(unit)
    else {
      // No real word yet → drop any stale gloss, show the resting slot.
      lastRequestedExplanationUnit = nil
      refreshExplanationSlot()
      return
    }
    guard unit != lastRequestedExplanationUnit else { return }  // unchanged since the last request
    lastRequestedExplanationUnit = unit
    renderExplanationSlot(.loading, notifyResize: true)  // also clears the now-stale in-context preview
    onRequestExplanation?(unit, targetLanguage, selectedExplanationTag)
  }

  /// Reset a stale in-context preview (E2) when the unit / sentence / target it was glossed for changes —
  /// a pure STATE reset (back to idle). Returns whether it actually cleared anything, so the caller can
  /// re-render the Sentence line + resize only when needed. Cheap to call on every keystroke.
  @discardableResult
  private func clearStaleContextPreview() -> Bool {
    guard contextPreview != .idle || contextPreviewUnit != nil else { return false }
    contextPreview = .idle
    contextPreviewUnit = nil
    return true
  }

  /// The "already in your Word Book" affordance (bug #6) — the ONLY affordance
  /// line still shown (the resting "From OCR/selection · click to correct" copy
  /// was removed as noise, overlay UX #5; this builder is only called when
  /// `capture.alreadySaved`). Says the unit is known and that saving adds this
  /// sentence (the unit is immutable; a re-capture contributes a new context).
  private func buildSourceAffordance(
    for capture: OverlayCapture, colors: OverlayPalette
  ) -> NSView {
    let label = NSTextField(
      labelWithString: "✓ Already in your Word Book · saving adds this sentence")
    label.font = chromeFont(size: OverlayMetrics.chromeMetaSize, weight: .regular)
    label.textColor = colors.ink3
    label.isSelectable = true  // #9
    label.lineBreakMode = .byTruncatingTail
    return label
  }

  private func buildContextBlock(
    capture: OverlayCapture, colors: OverlayPalette
  ) -> NSView {
    let col = NSStackView()
    col.orientation = .vertical
    col.alignment = .leading
    col.spacing = OverlayMetrics.space2

    // No "Sentence · optional" eyebrow (#1) — the field's own placeholder ("Add a sentence — optional")
    // already carries both the label and the optionality, so the eyebrow was redundant chrome.

    // Auto-growing context field: an NSTextView (document) inside an NSScrollView
    // whose height tracks the content but is CAPPED at 3 lines — beyond that the
    // field scrolls instead of growing the panel (overlay UX). Frame-based doc
    // view (the classic scroll-view text setup), not autolayout-sized.
    let serif = serifFont(size: OverlayMetrics.bodySmallSize, weight: .regular, italic: true)
    let tv = QuietTextView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 30))
    tv.palette = colors
    tv.isEditable = true
    tv.isSelectable = true
    tv.isRichText = false
    tv.allowsUndo = true
    tv.drawsBackground = false
    tv.textContainerInset = NSSize(width: 4, height: 4)
    tv.font = serif
    tv.textColor = colors.ink2
    tv.typingAttributes = [
      .font: serif,
      .foregroundColor: colors.ink2,
    ]
    // Scroll-view document setup: grow vertically with content, wrap horizontally
    // to the field width (no horizontal scroll).
    tv.isVerticallyResizable = true
    tv.isHorizontallyResizable = false
    tv.autoresizingMask = [.width]
    tv.minSize = NSSize(width: 0, height: 0)
    tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    if let container = tv.textContainer {
      container.lineFragmentPadding = 0
      container.widthTracksTextView = true
      container.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    }
    tv.string = capture.context
    tv.delegate = self
    tv.placeholderString = "Add a sentence — optional"
    // Warm selection in the sentence field too — the same accent-derived tint as the headword's field
    // editor (B-final), so no surface on the card ever flashes system blue.
    tv.selectedTextAttributes[.backgroundColor] = colors.selectionTint
    contextView = tv
    // Dismiss the floating "set as word" chip AND clear the selection when the
    // sentence loses focus — Tab away, click the headword / language / Save, or
    // click the overlay's empty background (overlay UX). The chip's own click
    // promotes on mouseDown first, so this only ever fires AFTER a promotion has
    // consumed the candidate, never cancels one. Collapsing the selection keeps
    // an unfocused field from showing a stale highlight or resurrecting the chip.
    tv.onFocusChange = { [weak self, weak tv] focused in
      guard let self else { return }
      // Variant B (#3/#4): intensify the sentence box border on focus, relax it on blur.
      self.styleInsetBox(self.contextFieldBox, focused: focused, colors: self.palette())
      guard !focused else { return }
      self.setAsWordButton?.isHidden = true
      self.promotionCandidate = nil
      if let tv, tv.selectedRange.length > 0 {
        tv.setSelectedRange(NSRange(location: tv.selectedRange.location, length: 0))
      }
    }

    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.documentView = tv
    scroll.translatesAutoresizingMaskIntoConstraints = false
    contextScrollView = scroll

    // Variant B (#3): wrap the scroll in a faint inset box — a PLAIN NSView, whose layer fill/border render
    // reliably (the NSScrollView's own layer fill is clobbered by `drawsBackground=false`, so the empty
    // field showed no background). The scroll sits inside with padding (so text isn't flush + the box has
    // presence); the vertical padding also makes the field taller (#2).
    let fieldBox = NSView()
    fieldBox.wantsLayer = true
    fieldBox.translatesAutoresizingMaskIntoConstraints = false
    fieldBox.addSubview(scroll)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: 8),
      scroll.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -8),
      scroll.topAnchor.constraint(equalTo: fieldBox.topAnchor, constant: 6),
      scroll.bottomAnchor.constraint(equalTo: fieldBox.bottomAnchor, constant: -6),
    ])
    contextFieldBox = fieldBox
    styleInsetBox(fieldBox, focused: false, colors: colors)
    col.addArrangedSubview(fieldBox)
    fieldBox.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true

    // Drive the field height (updateContextHeight) at just-below-required so it's
    // honored exactly in normal layout but YIELDS — rather than breaking a
    // constraint with a console warning — if the panel is ever clamped to a
    // pathologically short screen. The 3-line cap keeps it short regardless.
    let heightConstraint = scroll.heightAnchor.constraint(equalToConstant: 30)
    heightConstraint.priority = NSLayoutConstraint.Priority(999)
    heightConstraint.isActive = true
    contextHeightConstraint = heightConstraint
    updateContextHeight()

    // The "Explain in this sentence" line (E2), directly under the sentence: the explain trigger button
    // (idle), a spinner (loading), the in-context gloss (ready), a quota note, or a failed note + Retry.
    // Built empty; `renderContextPreviewLine` fills it from `contextPreview` + whether a sentence is
    // present. `detachesHiddenViews` drops it (no sentence / host not wired) with no residual gap.
    let ctxLine = NSStackView()
    ctxLine.orientation = .vertical
    ctxLine.alignment = .leading
    ctxLine.spacing = OverlayMetrics.space2
    ctxLine.translatesAutoresizingMaskIntoConstraints = false
    contextPreviewLine = ctxLine
    col.addArrangedSubview(ctxLine)
    ctxLine.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true

    // The calm "word isn't in the sentence" advisory (capture issue 3), hidden until refreshUnitMark
    // detects the mismatch. ink2, non-alert — Save is never blocked; the stored highlight just drops.
    let note = NSTextField(labelWithString: "This word isn’t in the sentence")
    note.font = chromeFont(size: OverlayMetrics.metaPillSize, weight: .regular)
    note.textColor = colors.ink2
    note.isSelectable = true  // #9
    note.isHidden = true
    note.translatesAutoresizingMaskIntoConstraints = false
    note.setAccessibilityLabel(
      "The word or phrase does not appear in the sentence; it will be saved without a highlight")
    unitNotInSentenceLabel = note
    col.addArrangedSubview(note)

    return col
  }

  /// Size the sentence scroll view to its content, clamped between one line and a
  /// 3-line cap; past the cap the field scrolls instead of the panel growing.
  private func updateContextHeight() {
    guard let tv = contextView, let lm = tv.layoutManager, let tc = tv.textContainer,
      let constraint = contextHeightConstraint
    else { return }
    lm.ensureLayout(for: tc)
    let inset = tv.textContainerInset.height * 2
    let line = lm.defaultLineHeight(
      for: tv.font ?? NSFont.systemFont(ofSize: OverlayMetrics.bodySmallSize))
    let used = ceil(lm.usedRect(for: tc).height)
    // 2-line minimum so the empty sentence reads as a roomier input area (#2), not a one-line strip; it
    // still grows to the 3-line cap, then scrolls.
    let minHeight = ceil(line * 2) + inset
    let maxHeight = ceil(line * 3) + inset
    let target = min(max(used + inset, minHeight), maxHeight)
    if abs(constraint.constant - target) > 0.5 {
      constraint.constant = target
    }
  }

  /// A hairline section divider in the WARM `--ovl-divider` tone (B-final). The system `.separator`
  /// NSBox painted a cool neutral gray — one of the few cool intrusions on the warm glass; this draws
  /// the tokenized warm hairline instead. (Layer color, like `styleInsetBox` — the content rebuilds per
  /// present/appearance change, so no dynamic-provider is needed.)
  private func makeDivider(colors: OverlayPalette) -> NSView {
    let rule = NSView()
    rule.wantsLayer = true
    rule.layer?.backgroundColor = colors.divider.cgColor
    rule.translatesAutoresizingMaskIntoConstraints = false
    rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return rule
  }

  /// The TOP explanation region (region A) container — the collapsed core directly under the headword
  /// (US/UK IPA + one-sentence summary + POS chips), or the loading / failed / langUnsupported note. Built
  /// empty; `renderExplanationSlot` fills it per state and toggles it + `topDivider`.
  private func buildTopSlot() -> NSStackView {
    let container = NSStackView()
    container.orientation = .vertical
    container.alignment = .leading
    container.spacing = OverlayMetrics.space2
    container.translatesAutoresizingMaskIntoConstraints = false
    topSlot = container
    return container
  }

  /// Settle the slot to its resting state (hidden — D3: the client holds no allowlist, so there is
  /// nothing to resolve locally). A fresh `/explain` push then drives
  /// loading/ready/failed/langUnsupported via `applyExplanation`.
  private func refreshExplanationSlot(notifyResize: Bool = true) {
    renderExplanationSlot(.hidden, notifyResize: notifyResize)
  }

  /// Push a live free-explanation state into the slot — called by the plugin's `updateExplanation`
  /// handler after a `/explain` fetch. No-op if the overlay isn't built.
  func applyExplanation(_ state: ExplanationSlotState) {
    // D3: no client allowlist guard. Staleness is defended by the host's generation token (a target
    // switch bumps it, so a late explanation for the OLD target is dropped Dart-side, never pushed)
    // — and langUnsupported itself now ARRIVES through this path (the server's language_unsupported).
    renderExplanationSlot(state, notifyResize: true)
  }

  /// Rebuild the slot's contents for [state], announce the change to VoiceOver,
  /// and resize the panel — but only when the state actually changed (re-pushing
  /// an identical state, or toggling zh→ja which both resolve to langUnsupported,
  /// skips the relayout + window-resize + announcement churn).
  private func renderExplanationSlot(_ state: ExplanationSlotState, notifyResize: Bool) {
    guard let top = topSlot else { return }
    let previous = explanationState
    let changed = state != previous
    explanationState = state

    // Rebuild the region subtree. Cheap, and avoids stale-view bugs from in-place edits.
    top.arrangedSubviews.forEach { $0.removeFromSuperview() }
    let colors = palette()

    switch state {
    case .hidden:
      top.isHidden = true
    case .langUnsupported:
      top.isHidden = false
      addSlotRow(buildSlotNote(text: Self.langUnsupportedMessage, colors: colors), to: top)
    case .loading:
      top.isHidden = false
      addSlotRow(buildSlotLoading(colors: colors, message: Self.explanationLoadingMessage), to: top)
    case let .ready(exp):
      top.isHidden = false
      for row in buildTopReadyRows(exp, colors: colors) { addSlotRow(row, to: top) }
    case .failed:
      top.isHidden = false
      addSlotRow(
        buildSlotNote(
          text: Self.explanationFailedMessage, colors: colors, action: #selector(retryExplanation)),
        to: top)
    case .notAWord:
      // A non-word caught locally — calm note, no Retry (re-asking won't make it a word).
      top.isHidden = false
      addSlotRow(buildSlotNote(text: Self.notAWordMessage, colors: colors), to: top)
    }
    // The scroll wrapper + the top divider track the region's visibility so an empty top (a bare
    // capture) collapses cleanly (`detachesHiddenViews` drops the hidden views + their spacing).
    topScrollView?.isHidden = top.isHidden
    topDivider?.isHidden = top.isHidden
    refreshAICreditVisibility()

    guard changed else { return }
    announceSlot(state)
    guard notifyResize else { return }
    // Defer one runloop turn: a language-menu selection can fire while the menu
    // is still tearing down, and a synchronous setFrame fights that animation.
    DispatchQueue.main.async { [weak self] in self?.requestPanelResize() }
  }

  /// Pin a built slot row to the container width (so wrapping labels know their
  /// measure) and add it.
  private func addSlotRow(_ view: NSView, to container: NSStackView) {
    container.addArrangedSubview(view)
    view.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
  }

  /// VoiceOver announcement for a slot transition — the slot takes no first
  /// responder, so without this the change is silent for VoiceOver users (#9).
  private func announceSlot(_ state: ExplanationSlotState) {
    let message: String
    switch state {
    case .hidden: return
    case .langUnsupported: message = Self.langUnsupportedMessage
    case .loading: message = Self.explanationLoadingMessage
    case let .ready(exp): message = "Meaning. " + Self.explanationReadyText(exp)
    case .failed: message = Self.explanationFailedMessage + " Retry available."
    case .notAWord: message = Self.notAWordMessage
    }
    guard let element = topSlot else { return }
    NSAccessibility.post(
      element: element, notification: .announcementRequested,
      userInfo: [
        .announcement: message,
        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
      ])
  }

  // MARK: - Explanation slot row builders

  /// A 6×6 accent ink-dot in a top-aligned glyph column (lifted to sit by the
  /// first line's cap height, matching the mockup's `margin-bottom: 2px`).
  private func buildDotGlyph(colors: OverlayPalette) -> NSView {
    let glyphHolder = NSView()
    glyphHolder.translatesAutoresizingMaskIntoConstraints = false
    let dot = NSView()
    dot.wantsLayer = true
    dot.layer?.backgroundColor = colors.accent.cgColor
    dot.layer?.cornerRadius = 3
    dot.translatesAutoresizingMaskIntoConstraints = false
    glyphHolder.addSubview(dot)
    NSLayoutConstraint.activate([
      dot.widthAnchor.constraint(equalToConstant: 6),
      dot.heightAnchor.constraint(equalToConstant: 6),
      dot.leadingAnchor.constraint(equalTo: glyphHolder.leadingAnchor),
      dot.trailingAnchor.constraint(equalTo: glyphHolder.trailingAnchor),
      dot.topAnchor.constraint(equalTo: glyphHolder.topAnchor, constant: 6),
      glyphHolder.widthAnchor.constraint(equalToConstant: 6),
    ])
    return glyphHolder
  }

  /// The calm dot-note used for langUnsupported, the failed word explanation, and the failed/quota/
  /// needsLogin in-context preview. When [action] is non-nil it appends an inline button (titled
  /// [actionTitle], default "Retry") wired to that selector — `#selector(retryExplanation)` for the word
  /// layer, `#selector(contextPreviewTapped)` for the in-context Retry, `#selector(signInTapped)` ("Sign
  /// in") for the signed-out in-context prompt.
  private func buildSlotNote(
    text: String, colors: OverlayPalette, action: Selector? = nil, actionTitle: String = "Retry"
  ) -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .top
    row.spacing = OverlayMetrics.space2
    row.translatesAutoresizingMaskIntoConstraints = false
    row.addArrangedSubview(buildDotGlyph(colors: colors))

    let label = NSTextField(wrappingLabelWithString: text)
    label.font = chromeFont(size: OverlayMetrics.chromeSmallSize, weight: .regular)
    label.textColor = colors.ink2
    label.isSelectable = true  // #9: status / note text is copyable
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    row.addArrangedSubview(label)

    if let action {
      let actionBtn = NSButton(title: actionTitle, target: self, action: action)
      actionBtn.isBordered = false
      actionBtn.bezelStyle = .inline
      actionBtn.font = chromeFont(size: OverlayMetrics.chromeSmallSize, weight: .semibold)
      actionBtn.contentTintColor = colors.ink
      actionBtn.setContentHuggingPriority(.required, for: .horizontal)
      actionBtn.setAccessibilityLabel(actionTitle)
      row.addArrangedSubview(actionBtn)
    }
    return row
  }

  /// The "filling in…" loading row (state 03). The overlay's one moving "working" cue:
  /// the brand echo mark with the coffee band sweeping left→right (the same `EchoPulseView`
  /// the capture HUD uses), so every loader in the product is one logo, one motion.
  /// The pulsing echo loader, optionally with a caption. Pass [message] = nil for the animation ALONE
  /// (the in-sentence "Explain here" preview — the pulse already says "working", so the words were
  /// redundant); pass a string to caption it (the word-meaning slot still reads "Generating…").
  private func buildSlotLoading(colors: OverlayPalette, message: String? = nil) -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = OverlayMetrics.space2
    row.translatesAutoresizingMaskIntoConstraints = false

    let echo = EchoPulseView(frame: .zero)
    echo.accent = colors.accent  // the single warm save-mark accent (--ovl-accent)
    echo.translatesAutoresizingMaskIntoConstraints = false
    echo.setContentHuggingPriority(.required, for: .horizontal)
    NSLayoutConstraint.activate([
      echo.widthAnchor.constraint(equalToConstant: 22),
      echo.heightAnchor.constraint(equalToConstant: 16),
    ])
    echo.startAnimating()
    row.addArrangedSubview(echo)

    if let message, !message.isEmpty {
      let label = NSTextField(labelWithString: message)
      label.font = chromeFont(size: OverlayMetrics.chromeSmallSize, weight: .regular)
      label.textColor = colors.ink2
      row.addArrangedSubview(label)
    }
    return row
  }

  /// The TOP ready region (region A): per-reading blocks of per-POS sense rows. A single
  /// reading is one block (its pronunciation line + sense rows); a heteronym is several blocks
  /// separated by a hairline. Every sense is shown — no cap, no "more" hint; the region scrolls if it
  /// outgrows its max height. The senses ARE the explanation — there is no summary line. The AI credit
  /// (and the "Open in Dictionary" button) live in the footer (B-final).
  private func buildTopReadyRows(_ exp: OverlayExplanation, colors: OverlayPalette) -> [NSView] {
    var rows: [NSView] = []
    for (i, reading) in exp.readings.enumerated() {
      if i > 0 { rows.append(makeDivider(colors: colors)) }  // separate heteronym reading blocks
      rows.append(contentsOf: buildReadingBlock(reading, colors: colors))
    }
    return rows
  }

  /// One reading block: its pronunciation line (or an `idiom` badge for a phrase) followed by one row
  /// per part of speech (its label + senses).
  private func buildReadingBlock(_ reading: OverlayReading, colors: OverlayPalette) -> [NSView] {
    var rows: [NSView] = []
    if reading.isIdiom {
      rows.append(buildIdiomBadge(colors: colors))
    } else if reading.hasPronunciation {
      rows.append(buildPronunciationLine(reading, colors: colors))
    }
    for pos in reading.pos {
      rows.append(buildPosRow(pos, colors: colors))
    }
    return rows
  }

  /// The pronunciation line — `US /…/  UK /…/` (display-ready parts; labels + decoration computed
  /// Dart-side from the TARGET profile, nothing accent-specific here). An omit-on-failed part is absent.
  private func buildPronunciationLine(_ reading: OverlayReading, colors: OverlayPalette) -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .firstBaseline
    row.spacing = OverlayMetrics.space2
    for part in reading.pronunciations {
      let text = part.label.map { "\($0) \(part.display)" } ?? part.display
      let label = NSTextField(labelWithString: text)
      label.font = serifFont(size: OverlayMetrics.bodySmallSize, weight: .regular)
      label.textColor = colors.ink2
      label.isSelectable = true  // #9: the pronunciation is copyable
      label.translatesAutoresizingMaskIntoConstraints = false
      label.setAccessibilityLabel(part.label.map { "\($0) pronunciation" } ?? "pronunciation")
      row.addArrangedSubview(label)
    }
    return row
  }

  /// The `idiom` badge shown where the IPA would be for a phrase/idiom reading (no transcription).
  private func buildIdiomBadge(colors: OverlayPalette) -> NSView {
    let badge = NSTextField(labelWithString: "idiom")
    badge.font = chromeFont(size: OverlayMetrics.metaPillSize, weight: .semibold)
    badge.textColor = colors.ink3
    badge.translatesAutoresizingMaskIntoConstraints = false
    badge.setAccessibilityLabel("idiom")
    return badge
  }

  /// The separator between a part of speech's senses shown on one line: a fullwidth Chinese semicolon
  /// for a CJK gloss (本质上；根本上), an ASCII "; " otherwise (to move; to jog) — chosen from the gloss
  /// language so the punctuation matches the script the meanings are written in.
  private var sensesSeparator: String {
    let tag = selectedExplanationTag.lowercased()
    return (tag.hasPrefix("zh") || tag.hasPrefix("ja") || tag.hasPrefix("ko")) ? "; " : "; "
  }

  /// One POS row: the abbreviated POS label (a quiet serif-italic label, flush LEFT under the headword)
  /// followed by ALL of that part of speech's senses joined onto ONE wrapping serif line (founder
  /// request — a glance, not a numbered column). Every sense is shown (no cap, no "more" hint); the
  /// layout is decided Dart-side (`computeSenseLayout`) and this only renders. The senses container is
  /// kept (now a single child) so the wrapping label sizes exactly as before.
  private func buildPosRow(_ pos: OverlayPosRow, colors: OverlayPalette) -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .firstBaseline
    row.spacing = OverlayMetrics.space2

    let label = NSTextField(labelWithString: pos.label)
    label.font = serifFont(size: OverlayMetrics.bodySmallSize, weight: .regular, italic: true)
    label.textColor = colors.ink2
    label.alignment = .left
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentHuggingPriority(.required, for: .horizontal)
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    label.setAccessibilityLabel(pos.label)
    row.addArrangedSubview(label)

    let senses = NSStackView()
    senses.orientation = .vertical
    senses.alignment = .leading
    senses.spacing = 4
    senses.translatesAutoresizingMaskIntoConstraints = false
    // A form note shared by every sense (e.g. "make 的现在分词") shows ONCE at the front of the joined
    // line, in parentheses — not repeated on each meaning (the note is pulled out Dart-side).
    let joined = pos.senses.joined(separator: sensesSeparator)
    let line = pos.note.isEmpty ? joined : "(\(pos.note)) \(joined)"
    senses.addArrangedSubview(buildSenseLine(line, colors: colors))
    row.addArrangedSubview(senses)
    return row
  }

  /// One sense line: the POS's meaning(s) as a wrapping serif label at the 16px "overlay core meaning"
  /// size, copyable (#9). A POS's senses are joined upstream (buildPosRow), so this is a single plain
  /// line with no number prefix.
  private func buildSenseLine(_ sense: String, colors: OverlayPalette) -> NSView {
    let field = NSTextField(wrappingLabelWithString: sense)
    field.font = serifFont(size: OverlayMetrics.bodySize, weight: .regular)
    field.textColor = colors.ink
    field.isSelectable = true  // #9: the meaning is copyable
    field.translatesAutoresizingMaskIntoConstraints = false
    field.setAccessibilityLabel(sense)
    return field
  }

  // MARK: - Explanation slot actions (dictionary / context)

  @objc private func showDictionaryTapped() {
    let term = currentUnit()
    guard !term.isEmpty, let field = unitField else { return }
    // Anchor the system Look Up popover at the HEADWORD (the unit field), not the panel centre, so it
    // points at the word the user is looking up. `showDefinition(for:at:)` takes a point in the
    // RECEIVER's own coordinates — present from the field, anchored near its leading edge.
    // Render the looked-up term in the popover's anchor glyph at the HEADWORD's own font (the 32pt display
    // serif) so the highlighted word matches the headword the user is looking up (#6) — without an explicit
    // font, `showDefinition` falls back to AppKit's small body size, which read noticeably smaller than the
    // headword behind it.
    let attr = NSAttributedString(
      string: term,
      attributes: [.font: field.font ?? serifFont(size: OverlayMetrics.displaySize, weight: .medium)])
    field.showDefinition(for: attr, at: NSPoint(x: field.bounds.minX + 2, y: field.bounds.midY))
  }

  /// The opt-in "Explain in this sentence" trigger shown in the Sentence block when no in-context gloss
  /// has been requested yet (idle). §178: opt-in — it never fires on its own.
  private func buildContextPreviewButton(colors: OverlayPalette) -> NSView {
    let btn = OverlayChromeButton()
    btn.hPad = 10
    btn.vPad = 5
    btn.styleBorder(colors.saveEdge)
    // Plain text — no sparkle glyph (founder D1: the ✨ reads as Gemini's mark, not a neutral AI cue).
    // The AI attribution lives in the tooltip + the footer "Generated with AI" credit.
    btn.attributedTitle = NSAttributedString(
      string: "Explain here",
      attributes: [
        .foregroundColor: colors.ink2,
        .font: chromeFont(size: OverlayMetrics.metaPillSize, weight: .semibold),
      ])
    btn.toolTip = "Explain this word as used in the sentence — generated with AI"
    btn.target = self
    btn.action = #selector(contextPreviewTapped)
    btn.setAccessibilityLabel("Explain this word in the captured sentence, generated with AI")
    return btn
  }

  @objc private func contextPreviewTapped() {
    let unit = currentUnit()
    let context = currentContext()
    guard !unit.isEmpty, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    // Remember the word this preview is for (the reused-overlay late-result guard), show the spinner
    // immediately in the Sentence line (responsive — no round-trip just to paint "working"), then ask
    // the host to run the metered fetch.
    contextPreviewUnit = unit
    contextPreview = .loading
    renderContextPreviewLine()
    DispatchQueue.main.async { [weak self] in self?.requestPanelResize() }
    onRequestContextPreview?(unit, context, targetLanguage, selectedExplanationTag)
  }

  /// "Sign in" on the signed-out in-context prompt (`.needsLogin`): dismiss the overlay FIRST — it's a
  /// `.floating` panel that would otherwise cover the app window — then ask the host to bring the app
  /// forward and open the in-app sign-in surface. Dismissing this capture is honest: the user chose to
  /// go authenticate instead of saving, so it counts as an abandon (re-capture after signing in).
  @objc private func signInTapped() {
    dismiss()
    onRequestSignIn?()
  }

  /// Push an in-context preview result into the Sentence block's explain line (E2) — the plugin calls
  /// this after the host's metered fetch. The line is independent of the word-explanation state now, so
  /// the only guard is the shown word still matching the request (a new capture reset the slot; a late
  /// result must not paint a stale gloss onto a different word).
  func applyContextPreview(_ slot: ContextPreviewSlot) {
    guard currentUnit() == contextPreviewUnit else { return }
    contextPreview = slot
    renderContextPreviewLine()
    announceContextPreview(slot)
    DispatchQueue.main.async { [weak self] in self?.requestPanelResize() }
  }

  /// Render the "Explain in this sentence" line in the Sentence block from `contextPreview` + whether a
  /// sentence is present: idle → the explain trigger button; loading → spinner; ready → the in-context
  /// gloss (no button); quota → a calm note; failed → a note + a trailing Retry. Hidden when there is no
  /// sentence to explain (or the host hasn't wired the fetch). Does NOT resize — callers do.
  private func renderContextPreviewLine() {
    guard let line = contextPreviewLine else { return }
    defer { refreshAICreditVisibility() }
    line.arrangedSubviews.forEach { $0.removeFromSuperview() }
    let colors = palette()
    let hasSentence = !currentContext().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard onRequestContextPreview != nil, hasSentence else {
      line.isHidden = true
      return
    }
    line.isHidden = false
    switch contextPreview {
    case .idle:
      // Hugging button (leading) — NOT width-pinned, so it sizes to its title.
      line.addArrangedSubview(buildContextPreviewButton(colors: colors))
    case .loading:
      // Animation ALONE — no caption (the pulse already reads as "working"; the words were redundant).
      // The VoiceOver announce below still speaks contextPreviewLoadingMessage for non-visual users.
      addSlotRow(buildSlotLoading(colors: colors), to: line)
    case let .ready(meaning):
      // B-final: the in-context explanation as an UNLABELED callout visually attached to the sentence
      // box above (an indented warm left rule — adjacency + the underlined unit do the labeling). One
      // combined answer (v3): the unit's meaning here AND what the whole sentence is saying.
      let col = NSStackView()
      col.orientation = .vertical
      col.alignment = .leading
      col.spacing = OverlayMetrics.space2
      col.translatesAutoresizingMaskIntoConstraints = false

      let callout = buildGlossCallout(meaning, colors: colors)
      col.addArrangedSubview(callout)
      callout.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
      addSlotRow(col, to: line)
    case .quotaExhausted:
      // No Retry — the daily cap won't clear until tomorrow.
      addSlotRow(buildSlotNote(text: Self.contextQuotaMessage, colors: colors), to: line)
    case .needsLogin:
      // Account-only feature, signed out → the calm prompt WITH a "Sign in" button. No Retry (re-asking
      // won't authenticate); the button brings the app forward and opens the in-app sign-in surface.
      addSlotRow(
        buildSlotNote(
          text: Self.contextNeedsLoginMessage, colors: colors,
          action: #selector(signInTapped), actionTitle: "Sign in"),
        to: line)
    case .failed:
      // Failed → the calm note WITH a trailing Retry that re-runs the in-context fetch (#7).
      addSlotRow(
        buildSlotNote(text: Self.contextFailedMessage, colors: colors, action: #selector(contextPreviewTapped)),
        to: line)
    }
  }

  /// One wrapping serif body paragraph for the in-context preview (the sentence meaning or the word
  /// meaning). The caller width-pins it to the column so it wraps.
  private func buildContextPreviewBody(_ text: String, colors: OverlayPalette) -> NSTextField {
    let body = NSTextField(wrappingLabelWithString: text)
    body.font = serifFont(size: OverlayMetrics.bodySmallSize, weight: .regular)
    body.textColor = colors.ink
    body.isSelectable = true  // #9: explanation content is copyable
    body.translatesAutoresizingMaskIntoConstraints = false
    return body
  }

  /// The in-context WORD gloss as an attached callout (B-final): indented under the sentence box with a
  /// 2px warm left rule — the attachment, not a label, says "this is about the underlined word above".
  private func buildGlossCallout(_ text: String, colors: OverlayPalette) -> NSView {
    let wrap = NSView()
    wrap.translatesAutoresizingMaskIntoConstraints = false
    let bar = NSView()
    bar.wantsLayer = true
    bar.layer?.backgroundColor = colors.rule.cgColor
    bar.translatesAutoresizingMaskIntoConstraints = false
    let body = buildContextPreviewBody(text, colors: colors)
    wrap.addSubview(bar)
    wrap.addSubview(body)
    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14),
      bar.widthAnchor.constraint(equalToConstant: 2),
      bar.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 1),
      bar.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -1),
      body.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 12),
      body.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
      body.topAnchor.constraint(equalTo: wrap.topAnchor),
      body.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
    ])
    return wrap
  }

  /// VoiceOver announcement for an in-context preview transition (the region takes no first responder,
  /// so the change is otherwise silent for VoiceOver users — DR4 a11y, mirrors `announceSlot`).
  private func announceContextPreview(_ slot: ContextPreviewSlot) {
    let message: String
    switch slot {
    case .idle: return
    case .loading: message = Self.contextPreviewLoadingMessage
    // One combined answer (v3) — read it verbatim; it already phrases naturally in the gloss language.
    case let .ready(meaning): message = meaning
    case .quotaExhausted: message = Self.contextQuotaMessage
    case .needsLogin: message = Self.contextNeedsLoginMessage
    case .failed: message = Self.contextFailedMessage
    }
    guard let element = contextPreviewLine else { return }
    NSAccessibility.post(
      element: element, notification: .announcementRequested,
      userInfo: [
        .announcement: message,
        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
      ])
  }

  /// Retry the free-explanation fetch (failed state, #7). Shows loading and asks
  /// Dart to re-run `/explain` for the shown unit + current target.
  @objc private func retryExplanation() {
    let unit = currentUnit()
    guard !unit.isEmpty else { return }
    renderExplanationSlot(.loading, notifyResize: true)
    onRequestExplanation?(unit, targetLanguage, selectedExplanationTag)
  }

  private func buildFooterRow(colors: OverlayPalette) -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = OverlayMetrics.space3
    row.distribution = .fill
    row.detachesHiddenViews = true

    // Dictionary (system Look Up) — leading. Hidden when there is no unit to look up
    // (`refreshDictionaryVisibility`); `detachesHiddenViews` collapses it cleanly.
    // B-final footer geometry: SAME padding/radius/type size as Save — hierarchy is carried by ink
    // (ink2 vs ink) + border tone (divider vs saveEdge) alone, not four simultaneous variables.
    let dict = OverlayChromeButton()
    dict.hPad = 14
    dict.vPad = 7
    dict.corner = 8
    dict.styleBorder(colors.divider)
    dict.attributedTitle = NSAttributedString(
      string: "Look up",
      attributes: [
        .foregroundColor: colors.ink2,
        .font: chromeFont(size: OverlayMetrics.chromeSmallSize, weight: .semibold),
      ])
    dict.target = self
    dict.action = #selector(showDictionaryTapped)
    dict.setContentHuggingPriority(.required, for: .horizontal)
    dict.setAccessibilityLabel("Look up in the system dictionary")
    dictionaryButton = dict

    // Footer status slot — hidden at rest. The resting "Capecho · esc dismiss"
    // chrome was removed (overlay UX #5); this label now carries only the
    // post-save "● Saved" confirmation and inline save-error messages.
    let blockHint = NSTextField(labelWithString: "")
    blockHint.font = chromeFont(size: OverlayMetrics.metaPillSize, weight: .medium)
    blockHint.textColor = colors.ink2
    blockHint.isHidden = true
    blockHint.setContentHuggingPriority(.required, for: .horizontal)
    blockHintLabel = blockHint

    let spacer = NSView()
    spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

    // The card-level "Generated with AI" credit (B-final): ONE quiet footer caption covers all the
    // generated content (definition + in-context gloss) instead of a caption row pinned under the
    // definition mid-card. Plain text — no sparkle glyph (founder D1: ✨ reads as Gemini's mark).
    // Hidden until AI content is actually on the card (refreshAICreditVisibility).
    let aiCredit = NSTextField(labelWithString: "Generated with AI")
    aiCredit.font = chromeFont(size: OverlayMetrics.metaTagSize, weight: .medium)
    aiCredit.textColor = colors.ink3  // a caption, not an eyebrow — ink-3 is allowed here
    aiCredit.toolTip = "The definition and in-context meaning are AI-generated"
    aiCredit.isHidden = true
    aiCredit.setContentHuggingPriority(.required, for: .horizontal)
    aiCredit.setAccessibilityLabel("Explanation generated with AI")
    aiCreditLabel = aiCredit

    // Warm-mono outlined Save with the leading ink-dot save mark + ⏎ hint,
    // NOT the system accent-filled default button. No
    // `keyEquivalent`/default-cell: Enter is dispatched per-control (the unit
    // field + context view intercept `insertNewline:`; this button fires on its
    // own Return/click).
    let save = OverlaySaveButton(frame: .zero)
    save.target = self
    save.action = #selector(handleSave)
    save.apply(palette: colors)
    save.setContentHuggingPriority(.required, for: .horizontal)
    // VoiceOver reads the ink-dot glyph without an override (subagent review M5).
    save.setAccessibilityLabel("Save")
    saveButton = save

    // Dictionary (left) · status hint · spacer · AI credit · Save (right).
    row.addArrangedSubview(dict)
    row.addArrangedSubview(blockHint)
    row.addArrangedSubview(spacer)
    row.addArrangedSubview(aiCredit)
    row.addArrangedSubview(save)
    return row
  }

  /// Show the footer Dictionary only when there is a unit to look up (hidden on a bare/empty capture).
  private func refreshDictionaryVisibility() {
    dictionaryButton?.isHidden = currentUnit().isEmpty
  }

  /// Show the footer "Generated with AI" credit only while AI content is actually on the card — a
  /// ready word explanation or a ready in-context gloss (loading/failed/idle states carry no AI text).
  private func refreshAICreditVisibility() {
    let explanationReady: Bool
    if case .ready = explanationState { explanationReady = true } else { explanationReady = false }
    let contextReady: Bool
    if case .ready = contextPreview { contextReady = true } else { contextReady = false }
    aiCreditLabel?.isHidden = !(explanationReady || contextReady)
  }

  // MARK: - Save enable + unit-mark in context (reactive)

  private func currentUnit() -> String {
    (unitField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func currentContext() -> String {
    contextView?.string ?? ""
  }

  /// Save is always actionable: a unit with no real word surfaces the inline "Word or
  /// phrase required" validation on the save ATTEMPT (handleSave → setUnitRequired)
  /// rather than greying the button out (overlay UX #5). So here we only CLEAR
  /// that validation once the user has supplied a unit with real word content (a unit that
  /// normalizes away — only whitespace/punctuation — keeps the validation). The button's
  /// disabled state is reserved for the in-flight / saved lifecycle.
  private func updateSaveEnabled() {
    if UnitNormalization.hasWordContent(currentUnit()) {
      setUnitRequired(false)
    }
  }

  /// Show or clear the empty-unit validation (overlay UX #5): the top eyebrow
  /// ("Word or phrase / required", hidden at rest) appears in the alert tone and
  /// the unit field takes a matching alert border. Idempotent — only relayouts /
  /// announces on an actual edge.
  private func setUnitRequired(_ show: Bool) {
    guard show != unitRequiredShown else { return }
    unitRequiredShown = show
    let colors = palette()
    unitEyebrowRow?.isHidden = !show
    // The alert border lives on the unit's inset box now (Variant B) — paint the validation border on
    // show, restore the normal rest/focus inset on clear.
    styleInsetBox(unitFieldBox, focused: unitFocused, alert: show, colors: colors)
    if show, let target = unitEyebrowRow {
      // The field takes no first responder change here, so announce the
      // validation for VoiceOver users (their Enter "did nothing" otherwise).
      NSAccessibility.post(
        element: target,
        notification: .announcementRequested,
        userInfo: [
          .announcement: "Word or phrase required",
          .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
    // Showing/hiding the eyebrow changes the panel height — keep it fit.
    requestPanelResize()
  }

  /// Updates the underline of the (first occurrence of the) unit inside the
  /// context view's attributed text. Idempotent — called on unit or context
  /// changes. Display-only; the durable span is the user-corrected pair sent
  /// up to the journal at save time.
  ///
  /// IME-safe: skips while the text view has marked text (active Chinese /
  /// Japanese / Korean composition), so we don't fight the system's marked-
  /// attribute rendering. Re-applies `typingAttributes` after the storage
  /// mutation so the next character the user types resumes the italic ink2
  /// body style — AppKit otherwise inherits the unit-mark's ink + underline
  /// at the insertion point (subagent review H3).
  private func refreshUnitMark() {
    guard let tv = contextView else { return }
    if tv.hasMarkedText() { return }
    let unit = currentUnit()
    let text = tv.string
    guard let storage = tv.textStorage else { return }
    let colors = palette()
    let full = NSRange(location: 0, length: (text as NSString).length)
    let matchRange = unit.isEmpty ? nil : text.range(of: unit, options: .caseInsensitive)
    storage.beginEditing()
    storage.removeAttribute(.underlineStyle, range: full)
    storage.removeAttribute(.underlineColor, range: full)
    storage.addAttribute(.foregroundColor, value: colors.ink2, range: full)
    if let r = matchRange {
      let ns = NSRange(r, in: text)
      storage.addAttributes(
        [
          .underlineStyle: NSUnderlineStyle.single.rawValue,
          .underlineColor: colors.rule,
          .foregroundColor: colors.ink,
        ], range: ns)
    }
    storage.endEditing()
    // Restore the resting typing attributes — without this, NSTextView would
    // inherit the unit-mark's foreground/underline at the insertion point on
    // the user's next keystroke.
    tv.typingAttributes = [
      .font: serifFont(size: OverlayMetrics.bodySmallSize, weight: .regular, italic: true),
      .foregroundColor: colors.ink2,
    ]
    // Advisory (capture issue 3): the unit isn't in the sentence it'll be saved with — non-blocking
    // (Save still works; the stored span just drops to nil and the reader re-searches). Shown ONLY when
    // there is a real unit AND a non-empty sentence that doesn't contain it; toggled (with a resize)
    // only on an actual visibility edge so typing doesn't churn the layout.
    let sentenceHasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let shouldShow = UnitNormalization.hasWordContent(unit) && sentenceHasText && matchRange == nil
    if let note = unitNotInSentenceLabel, note.isHidden == shouldShow {
      note.isHidden = !shouldShow
      requestPanelResize()
    }
  }

  // MARK: - Delegate hooks

  // Unit field text changed (NSTextFieldDelegate via NSControl).
  func controlTextDidChange(_ notification: Notification) {
    updateSaveEnabled()
    refreshUnitMark()
    unitField?.updatePlaceholderVisibility()  // NSTextField has no didChangeText hook (#4 centred prompt)
    refreshDictionaryVisibility()  // show/hide footer Dictionary as the unit gains/loses content
    // The user is now typing the unit directly — the (stale) promotion
    // candidate from a prior context selection should not surprise them on
    // their next click.
    setAsWordButton?.isHidden = true
    promotionCandidate = nil
    // The free gloss + the in-context preview were for the PRIOR unit. Drop the stale preview now (the
    // in-context line reverts to its explain button) and schedule a debounced re-gloss (capture issue 2).
    if clearStaleContextPreview() {
      renderContextPreviewLine()
      requestPanelResize()
    }
    // The unit changed by typing → re-derive the target (a script-disjoint edit switches certainly; a
    // same-script span difference re-surfaces the suggestion). resetManual:false keeps a target the user
    // confirmed for this same word. Synchronous so the chip tracks keystrokes; the /explain re-gloss is
    // deferred to the field losing focus (this fires per keystroke — re-glossing here is too frequent).
    revalidateTargetForUnitChange(resetManual: false)
  }

  // Enter in the unit field dispatches Save. The Save button is no longer the
  // panel's default-button cell (it's a flat outlined control now — overlay
  // polish #10), so the field editor's Return must be intercepted here, exactly
  // as the context view does. Tab/Backtab fall through to AppKit's default
  // single-line field nextKeyView advance.
  func control(
    _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
  ) -> Bool {
    guard control === unitField else { return false }
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      // handleSave validates an empty unit (→ "required" eyebrow); never gate
      // here, or Enter on an empty field would be silently inert.
      handleSave()
      return true
    }
    return false
  }

  // Context text view text changed (NSTextViewDelegate).
  func textDidChange(_ notification: Notification) {
    refreshUnitMark()
    updateContextHeight()
    // The cached selection (range, promoted text) was computed against the
    // PRIOR context string. Once the user edits the context, the NSRange may
    // point at unrelated characters and the promoted string may no longer
    // appear at the cached location. Clear it (the next eligible selection
    // repopulates) and hide the chip so a stale click can't fire.
    promotionCandidate = nil
    setAsWordButton?.isHidden = true
    // The in-context preview (E2) was glossed for the PRIOR sentence — editing the sentence makes it
    // stale, so reset it. Re-render the line unconditionally so the explain button appears/disappears as
    // the sentence becomes non-empty/empty. The free unit gloss is unaffected (keyed on the unit).
    clearStaleContextPreview()
    renderContextPreviewLine()
    requestPanelResize()
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    guard let tv = contextView else { return }
    // No eligible selection → no promotion affordance: hide the chip + clear the
    // candidate (overlay UX #2). This no longer races the chip's own click —
    // PillButton fires on mouseDown and consumes the candidate BEFORE the click's
    // focus change collapses the selection and reaches here.
    guard let candidate = promotionFromCurrentSelection() else {
      setAsWordButton?.isHidden = true
      promotionCandidate = nil
      return
    }
    promotionCandidate = candidate
    showSetAsWordButton(near: candidate.range, in: tv)
  }

  // Intercept Enter + Tab inside the context view. Enter → dispatch Save
  // (Option-Enter via `insertNewlineIgnoringFieldEditor` is not intercepted;
  // it inserts a literal newline). Tab + Backtab → advance/retreat the
  // panel's first responder (NSTextView would otherwise eat the keystroke as
  // a literal U+0009 and the `nextKeyView` chain would never fire — that's a
  // direct OVL-3 violation).
  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    switch commandSelector {
    case #selector(NSResponder.insertNewline(_:)):
      // handleSave validates an empty unit (→ "required" eyebrow).
      handleSave()
      return true
    case #selector(NSResponder.insertTab(_:)):
      panel?.selectNextKeyView(nil)
      return true
    case #selector(NSResponder.insertBacktab(_:)):
      panel?.selectPreviousKeyView(nil)
      return true
    default:
      return false
    }
  }

  // MARK: - "Set as word" floating affordance (CAP-2)

  /// The promotable unit for the context view's CURRENT selection, or nil when
  /// there is no eligible selection. Used both to cache the candidate when the
  /// chip is shown and as the click-time fallback in `promoteSelectionToUnit`.
  private func promotionFromCurrentSelection() -> (range: NSRange, promoted: String)? {
    guard let tv = contextView else { return nil }
    let selRange = tv.selectedRange
    guard selRange.length > 0 else { return nil }
    let nsText = tv.string as NSString
    guard NSMaxRange(selRange) <= nsText.length else { return nil }
    let raw = nsText.substring(with: selRange)
    // Distinguish user gesture: a double-click word selection snaps to word
    // boundaries (CAP-2); a manual character drag is taken verbatim so the user
    // can pick a partial word or a phrase. Triple-click line selection also
    // snaps (still a whole-unit gesture).
    let granularity: CaptureSelectionPromotion.SelectionGranularity =
      tv.selectionGranularity == .selectByCharacter ? .character : .word
    guard
      let promoted = CaptureSelectionPromotion.promote(
        rawSelection: raw, in: tv.string,
        selectionRange: selRange, targetLanguage: targetLanguage,
        granularity: granularity)
    else { return nil }
    return (selRange, promoted)
  }

  private func showSetAsWordButton(near range: NSRange, in tv: NSTextView) {
    guard let panel, let btn = setAsWordButton, let root = panel.contentView,
      let lm = tv.layoutManager, let tc = tv.textContainer
    else {
      return
    }
    let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    let bounds = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
    let inTV = bounds.offsetBy(
      dx: tv.textContainerInset.width, dy: tv.textContainerInset.height)
    let inRoot = tv.convert(inTV, to: root)
    btn.sizeToFit()
    let size = btn.fittingSize
    // Center the chip horizontally under the selection and place it just BELOW
    // the selection's bottom edge (overlay UX #3) so it never overlaps the
    // selected word — including the right-most word on a line, where the old
    // inline-right anchor pushed the chip onto the text. NSTextView is flipped,
    // root is not — after convert(_:to:), `inRoot.minY` is the selection's
    // visual BOTTOM and `inRoot.midX` its horizontal center.
    var x = inRoot.midX - size.width / 2
    var y = inRoot.minY - size.height - 4
    x = min(x, root.bounds.maxX - size.width - 4)
    x = max(x, root.bounds.minX + 4)
    y = max(y, root.bounds.minY + 4)
    y = min(y, root.bounds.maxY - size.height - 4)
    btn.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    btn.isHidden = false
  }

  @objc private func promoteSelectionToUnit() {
    // Prefer the (range, promoted) pair cached when the chip was shown, which is
    // stable across the focus change this method triggers below. Fall back to
    // the context view's LIVE selection if the cache was already cleared — a
    // defensive net for the rare ordering where AppKit resigns the text view
    // (clearing the candidate via onFocusChange) during event routing, before
    // this mouseDown-dispatched action runs. Bail only if neither yields a unit.
    guard let field = unitField,
      let candidate = promotionCandidate ?? promotionFromCurrentSelection()
    else {
      setAsWordButton?.isHidden = true
      return
    }
    field.stringValue = candidate.promoted
    updateSaveEnabled()
    refreshUnitMark()
    refreshDictionaryVisibility()  // the unit just changed (gained content)
    // The promoted unit differs from any prior in-context gloss → reset the Sentence line to its button.
    // Match the typing path: clearing a (possibly multi-line) preview shrinks the line, so resize too —
    // otherwise the panel keeps the taller stale-gloss height until some later unrelated resize.
    if clearStaleContextPreview() {
      renderContextPreviewLine()
      requestPanelResize()
    }
    setAsWordButton?.isHidden = true
    promotionCandidate = nil
    // Programmatically replacing `stringValue` does NOT fire `controlTextDidChange`, so re-gloss the
    // promoted unit here. This is a discrete action (unlike per-keystroke typing, which now defers its
    // re-gloss to the field losing focus), so fetch immediately; the backend cache + the controller's
    // generation guard absorb the cost if the user then edits the focused-and-selected field below.
    // "set as word" replaces the unit with a span from the sentence → re-derive the target for the NEW
    // word (resetManual:true: it's a brand-new word, so drop any manual pick made for the prior one). A
    // CJK substring of an English line switches to its language here; a same-script one may suggest.
    revalidateTargetForUnitChange(resetManual: true)
    refreshExplanationForEditedUnit()
    // Move focus to the unit so the user can tweak — full-select so a single
    // keystroke replaces it.
    panel?.makeFirstResponder(field)
    field.currentEditor()?.selectAll(nil)
  }

  // MARK: - Panel resize (context view height can change as the user types)

  private func requestPanelResize(animated: Bool = false) {
    guard let panel, let root = panel.contentView else { return }
    root.layoutSubtreeIfNeeded()
    let fitting = root.fittingSize
    let visible = panel.screen?.visibleFrame
    // Cap the height to the visible frame so the panel is never taller than the
    // screen (#5). The context field is capped at 3 lines, so the panel height
    // is already bounded; on a pathologically short screen the field's
    // just-below-required height yields so the headword + Save stay on.
    var height = max(fitting.height, 160)
    if let visible { height = min(height, visible.height) }
    let size = NSSize(width: Self.panelWidth, height: height)
    let frame = panel.frame
    // Keep the top anchored so the panel grows downward as the context wraps.
    var origin = NSPoint(x: frame.minX, y: frame.maxY - size.height)
    // Clamp so the panel is FULLY on-screen — bottom not below the visible
    // frame, and (the #5 fix) top not above it either, so the headword can't be
    // pushed off the top edge.
    if let visible {
      if origin.y < visible.minY { origin.y = visible.minY }
      if origin.y + size.height > visible.maxY { origin.y = visible.maxY - size.height }
    }
    let target = NSRect(origin: origin, size: size)
    // The disclosure toggle (#5) animates the height change via the window animator — reliable for this
    // borderless floating panel in BOTH grow + shrink directions (plain `setFrame(animate:)` read as
    // instant on grow). Every other caller passes `animated: false` for an instant resize so the panel
    // never lags the text being edited.
    if animated {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.22
        panel.animator().setFrame(target, display: true)
      }
    } else {
      panel.setFrame(target, display: true)
    }
  }

  // MARK: - Save

  @objc private func handleSave() {
    guard let capture = current, let onSave else { return }
    // A save attempt supersedes any pending debounced re-explain: cancel it so a late /explain can't fire
    // a wasted round-trip + a spinner flash on an overlay that's already committing/dismissing (CR). If the
    // save fails and the user re-edits, controlTextDidChange schedules a fresh one.
    explainDebounceWorkItem?.cancel()
    explainDebounceWorkItem = nil
    let unit = currentUnit()
    // Save attempted with no real WORD — empty, or only whitespace/punctuation/symbols that the dedup
    // key (localDedupKey) would normalize AWAY, so the drain would create no word (a "Saved" that saves
    // nothing — capture P0 silent loss). Surface the inline "Word or phrase required" validation
    // (overlay UX #5) + focus the field; do not save. Mirrors localDedupKey via UnitNormalization.
    if !UnitNormalization.hasWordContent(unit) {
      setUnitRequired(true)
      if let field = unitField { panel?.makeFirstResponder(field) }
      return
    }
    // Re-entry guard: a save in flight (or the post-save "Saved" dwell) has already disabled the
    // button, so a second Enter — e.g. in the context field, which dispatches Save directly — must not
    // fire a second save (a duplicate durable append + a double-counted `completed` metric; review P2).
    guard saveButton?.isEnabled ?? false else { return }
    let ctx = currentContext().trimmingCharacters(in: .whitespacesAndNewlines)
    // Save persists the current capture target (the language being learned) — its default, or the value
    // the target chip switched to. The gloss language is a separate, settings-driven value, not persisted here.
    let request = OverlaySaveRequest(
      unit: unit,
      context: ctx.isEmpty ? nil : ctx,
      targetLanguage: targetLanguage,
      source: capture.source,
      // Capture-source provenance + detected language ride straight from the capture (gated app-side by
      // the Settings toggle — when off, these arrive nil). Confidence is paired with the language: nil
      // when none was detected, so the journal never stores a bare 0.
      sourceApp: capture.sourceApp,
      sourceTitle: capture.sourceTitle,
      detectedLanguage: capture.detectedSpanLanguage,
      detectedLanguageConfidence: capture.detectedSpanLanguage == nil
        ? nil : capture.detectedSpanLanguageConfidence)

    saveEpoch &+= 1
    let epoch = saveEpoch
    saveButton?.isEnabled = false
    onSave(request) { [weak self] success, errorMessage in
      DispatchQueue.main.async {
        guard let self, self.saveEpoch == epoch else { return }  // H2 guard
        if success {
          self.showSavedThenDismiss()
        } else {
          // Surface the inline error in the footer status slot and re-enable
          // Save so the user can retry. Re-enable UNCONDITIONALLY (not gated on a
          // non-empty unit): Save is always actionable now — if the user cleared
          // the unit during the in-flight save, a later retry should still be
          // possible (an empty unit just re-shows the "required" validation),
          // otherwise the overlay could get stuck unable to save until dismissed.
          self.saveButton?.isEnabled = true
          self.blockHintLabel?.textColor = self.palette().ink2
          self.blockHintLabel?.stringValue =
            errorMessage ?? "Couldn’t save — try again"
          self.blockHintLabel?.isHidden = false
        }
      }
    }
  }

  /// The saved confirmation: a brief dwell (~700ms) before auto-dismiss. The ink-dot is the accent mark.
  private func showSavedThenDismiss() {
    // The committed confirmation lives on the Save button itself now — "● Saved" with the brand ink-dot
    // (#7). The footer status slot stays reserved for inline save errors, so the "Saved" isn't doubled.
    saveButton?.markSaved()
    dismissWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.dismiss() }
    dismissWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
  }

  // MARK: - Positioning

  /// Centers the panel on the screen under the mouse (Spotlight-style).
  private func positionCentered(_ panel: CaptureOverlayPanel) {
    panel.contentView?.layoutSubtreeIfNeeded()
    let fitting = panel.contentView?.fittingSize ?? NSSize(width: Self.panelWidth, height: 220)
    let mouse = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
      ?? NSScreen.main
      ?? NSScreen.screens.first
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    // Cap height to the visible frame (#5) so the panel is never taller than the
    // screen, then center with a slight upward bias.
    let size = NSSize(
      width: Self.panelWidth, height: min(max(fitting.height, 160), visible.height))
    var origin = NSPoint(
      x: visible.midX - size.width / 2,
      y: visible.midY - size.height / 2 + visible.height * 0.08)
    // Keep the panel fully within the visible frame even after the upward bias.
    if origin.y + size.height > visible.maxY { origin.y = visible.maxY - size.height }
    if origin.y < visible.minY { origin.y = visible.minY }
    panel.setFrame(NSRect(origin: origin, size: size), display: true)
  }

  // MARK: - Fonts (token-faithful fallbacks)

  /// Serif (New York) standing in for Fraunces/Charter until those fonts are
  /// bundled (a follow-up). Falls back to the system serif design.
  private func serifFont(size: CGFloat, weight: NSFont.Weight, italic: Bool = false) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    var descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
    if italic {
      descriptor = descriptor.withSymbolicTraits(.italic)
    }
    return NSFont(descriptor: descriptor, size: size) ?? base
  }

  private func chromeFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
  }
}
