import Cocoa

// The agent's in-use dropdown (see DESIGN.md): a warm,
// frosted panel opened from the menu-bar "C". A standard NSMenu can't be restyled to
// the Caffeine warm-glass look (the system owns its chrome), so this is a custom
// borderless NSPanel — modeled on the capture overlay's panel — rendering the rows,
// boxed key-caps, and capture-mode status line itself.
//
// The `--app-*` warm tokens are TRANSCRIBED from the Dart OnboardingPalette /
// design/tokens.css (kept in sync until the token generator feeds the native
// build — same follow-up as OverlayTokens.swift). Do NOT hand-tune.

// MARK: - Palette

/// The warm `--app-*` colors for one appearance, plus the frosted dropdown surface.
struct StatusMenuPalette {
  let ink: NSColor
  let ink2: NSColor
  let ink3: NSColor
  let line: NSColor
  let card: NSColor
  let edge: NSColor
  let primary: NSColor
  let primaryFg: NSColor
  let border: NSColor
  /// The warm frosted dropdown fill laid over the blur.
  let tint: NSColor

  static let light = StatusMenuPalette(
    ink: srgb(0.169, 0.137, 0.125),       // --app-ink   #2B2320
    ink2: srgb(0.420, 0.365, 0.329),      // --app-ink-2 #6B5D54
    ink3: srgb(0.635, 0.584, 0.541),      // --app-ink-3 #A2958A
    line: srgb(0.925, 0.898, 0.863),      // --app-line  #ECE5DC
    card: srgb(1, 1, 1),                  // --app-card  #FFFFFF
    edge: srgb(0.169, 0.137, 0.125),      // --app-edge  #2B2320
    primary: srgb(0.392, 0.290, 0.251),   // --app-primary    #644A40
    primaryFg: srgb(1, 1, 1),             // --app-primary-fg #FFFFFF
    border: srgb(0, 0, 0, 0.10),          // dropdown hairline
    // A neutral 248,248,246 reads cool over the system material; warm it toward the
    // app canvas + raise opacity so it isn't grey.
    tint: srgb(0.969, 0.957, 0.937, 0.95)) // warm off-white ~#F7F4EF

  static let dark = StatusMenuPalette(
    ink: srgb(0.941, 0.914, 0.878),       // #F0E9E0
    ink2: srgb(0.765, 0.706, 0.651),      // #C3B4A6
    ink3: srgb(0.553, 0.494, 0.443),      // #8D7E71
    line: srgb(0.227, 0.188, 0.165),      // #3A302A
    card: srgb(0.173, 0.141, 0.122),      // #2C241F
    edge: srgb(0.063, 0.047, 0.039),      // #100C0A
    primary: srgb(0.902, 0.769, 0.608),   // #E6C49B
    primaryFg: srgb(0.169, 0.122, 0.094), // #2B1F18
    border: srgb(1, 1, 1, 0.10),
    tint: srgb(0.133, 0.106, 0.090, 0.95)) // warm dark canvas ~#221B17

  static func resolve(_ appearance: NSAppearance) -> StatusMenuPalette {
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
  }

  private static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
  }
}

// MARK: - Row model

/// One dropdown entry. A `separator` draws a hairline; an `item` is a clickable row
/// with an optional boxed shortcut cap and an action.
enum StatusMenuRow {
  case item(title: String, shortcut: String?, action: () -> Void)
  case separator
}

// MARK: - Boxed key-cap

/// The fixed-height rounded key-cap: warm card face, edge border, mono
/// glyph. One cap per shortcut string (e.g. "⌥R", "⌘,").
private final class KeyCapView: NSView {
  private let label = NSTextField(labelWithString: "")

  init(_ text: String, palette: StatusMenuPalette) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 5
    layer?.borderWidth = 1
    translatesAutoresizingMaskIntoConstraints = false

    label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 24),
      widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
    ])
    apply(text: text, palette: palette)
  }

  required init?(coder: NSCoder) { fatalError() }

  func apply(text: String, palette: StatusMenuPalette) {
    label.stringValue = text
    label.textColor = palette.ink
    layer?.backgroundColor = palette.card.cgColor
    layer?.borderColor = palette.edge.withAlphaComponent(0.55).cgColor
  }
}

// MARK: - Row view

/// A clickable dropdown row with hover highlight (warm primary fill) and an optional
/// trailing key-cap. Fires its action on mouse-up inside.
private final class MenuRowView: NSView {
  private let title: String
  private let shortcut: String?
  private let action: () -> Void
  private var palette: StatusMenuPalette

  private let titleLabel = NSTextField(labelWithString: "")
  private var cap: KeyCapView?
  private var tracking: NSTrackingArea?
  private var highlighted = false

  init(title: String, shortcut: String?, palette: StatusMenuPalette, action: @escaping () -> Void) {
    self.title = title
    self.shortcut = shortcut
    self.palette = palette
    self.action = action
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 6
    translatesAutoresizingMaskIntoConstraints = false

    titleLabel.stringValue = title
    titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(titleLabel)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 30),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    if let shortcut {
      let cap = KeyCapView(shortcut, palette: palette)
      addSubview(cap)
      NSLayoutConstraint.activate([
        cap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        cap.centerYAnchor.constraint(equalTo: centerYAnchor),
        cap.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
      ])
      self.cap = cap
    }
    applyColors()
  }

  required init?(coder: NSCoder) { fatalError() }

  func restyle(_ palette: StatusMenuPalette) {
    self.palette = palette
    cap?.apply(text: shortcut ?? "", palette: palette)
    applyColors()
  }

  private func applyColors() {
    layer?.backgroundColor = highlighted ? palette.primary.cgColor : NSColor.clear.cgColor
    titleLabel.textColor = highlighted ? palette.primaryFg : palette.ink
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) {
    highlighted = true
    applyColors()
  }

  override func mouseExited(with event: NSEvent) {
    highlighted = false
    applyColors()
  }

  override func mouseUp(with event: NSEvent) {
    // Only fire if the release is inside the row (a drag-out cancels).
    if bounds.contains(convert(event.locationInWindow, from: nil)) {
      action()
    }
  }
}

// MARK: - Panel

/// Borderless, key-able panel so the dropdown receives Esc even though the app is an
/// agent (same pattern as the capture overlay).
final class StatusMenuPanel: NSPanel {
  var onCancel: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func cancelOperation(_ sender: Any?) { onCancel?() }
}

// MARK: - Controller

/// Owns the dropdown panel: builds it from the rows + the live capture-mode, anchors
/// it under the status-item button, and dismisses on Esc / click-outside / selection.
final class StatusMenuController: NSObject {
  /// Returns whether Screen-Recording (OCR) capture is currently armed — drives the
  /// status line ("OCR capture armed" vs "Clipboard mode").
  private let captureArmed: () -> Bool
  /// The current global capture shortcut display string (for example "⌥E").
  private let captureShortcut: () -> String

  private var rows: [StatusMenuRow] = []
  private var panel: StatusMenuPanel?
  private weak var anchorWindow: NSWindow?  // the status-bar button's window (toggle source)
  private var globalMonitor: Any?
  private var localMonitor: Any?

  private static let width: CGFloat = 248

  init(captureArmed: @escaping () -> Bool, captureShortcut: @escaping () -> String) {
    self.captureArmed = captureArmed
    self.captureShortcut = captureShortcut
  }

  func setRows(_ rows: [StatusMenuRow]) {
    self.rows = rows
  }

  var isShown: Bool { panel?.isVisible ?? false }

  /// Toggle from the status-item button (the button's action).
  func toggle(from button: NSStatusBarButton) {
    if isShown {
      dismiss()
    } else {
      present(from: button)
    }
  }

  func present(from button: NSStatusBarButton) {
    // Idempotent: tear down any prior panel + monitors first, so a second present()
    // (a fast re-toggle / future caller) can't leak the old window or stack monitors.
    dismiss()

    let palette = StatusMenuPalette.resolve(NSApp.effectiveAppearance)
    let content = buildContent(palette: palette)
    let size = content.fittingSize

    let panel = StatusMenuPanel(
      contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .popUpMenu
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.onCancel = { [weak self] in self?.dismiss() }
    panel.contentView = content
    self.panel = panel
    self.anchorWindow = button.window

    positionPanel(panel, under: button)
    // Do NOT activate the app: a `.nonactivatingPanel` that `canBecomeKey` already takes Esc /
    // click-to-select from `makeKeyAndOrderFront` alone (same as the capture overlay's present()).
    // Activating here pulls the app — and any open Settings / Word Book / Review window living on ANOTHER
    // Space — to the front, yanking the user over to that Space just to show the dropdown. The panel is
    // `.canJoinAllSpaces`, so it appears on the CURRENT Space without moving anything; only choosing a row
    // (requestSurface → showMainWindow) is allowed to bring a surface forward.
    panel.makeKeyAndOrderFront(nil)
    installDismissMonitors()
  }

  func dismiss() {
    removeMonitors()
    panel?.orderOut(nil)
    panel = nil
    anchorWindow = nil
  }

  // MARK: build

  private func buildContent(palette: StatusMenuPalette) -> NSView {
    // Root: rounded, clipped; a frosted blur base + a hairline border, padding 6.
    let root = NSView()
    root.wantsLayer = true
    root.layer?.cornerRadius = 10
    root.layer?.masksToBounds = true
    root.layer?.borderWidth = 1
    root.layer?.borderColor = palette.border.cgColor

    let blur = NSVisualEffectView()
    blur.material = .popover  // lighter/neutral frost; the warm tint above carries the color
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(blur)

    // The warm `--app` tint over the blur — a near-opaque frosted fill
    // (the system menu material alone reads cool/grey on a neutral desktop).
    let tint = NSView()
    tint.wantsLayer = true
    tint.layer?.backgroundColor = palette.tint.cgColor
    tint.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(tint)

    let column = NSStackView()
    column.orientation = .vertical
    column.alignment = .width
    column.spacing = 0  // rows are flush; only `.sep` margins separate groups
    column.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
    column.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(column)

    column.addArrangedSubview(buildHeader(palette: palette))
    column.addArrangedSubview(separator(palette))

    for row in rows {
      switch row {
      case .separator:
        column.addArrangedSubview(separator(palette))
      case let .item(title, shortcut, action):
        let view = MenuRowView(title: title, shortcut: shortcut, palette: palette) { [weak self] in
          self?.dismiss()
          action()
        }
        column.addArrangedSubview(view)
      }
    }

    NSLayoutConstraint.activate([
      root.widthAnchor.constraint(equalToConstant: Self.width),
      blur.topAnchor.constraint(equalTo: root.topAnchor),
      blur.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      blur.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      blur.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      tint.topAnchor.constraint(equalTo: root.topAnchor),
      tint.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      tint.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      tint.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      column.topAnchor.constraint(equalTo: root.topAnchor),
      column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
    ])
    root.layoutSubtreeIfNeeded()
    return root
  }

  /// The status header: app icon + capture-mode label + a caption line.
  private func buildHeader(palette: StatusMenuPalette) -> NSView {
    let armed = captureArmed()
    let modeLabel = armed ? "OCR capture armed" : "Clipboard mode"
    let shortcut = captureShortcut()
    let caption = armed
      ? "Press \(shortcut) near a word to capture"
      : "Copy text, then \(shortcut) · OCR off"

    let icon = NSImageView(image: NSApp.applicationIconImage)
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.imageAlignment = .alignCenter
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.setContentHuggingPriority(.required, for: .horizontal)
    icon.setContentHuggingPriority(.required, for: .vertical)
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 34),
      icon.heightAnchor.constraint(equalToConstant: 34),
    ])

    let mode = NSTextField(labelWithString: modeLabel)
    mode.font = NSFont.systemFont(ofSize: 12, weight: .medium)
    mode.textColor = palette.ink2  // --app-ink-2
    mode.translatesAutoresizingMaskIntoConstraints = false

    let cap = NSTextField(labelWithString: caption)
    cap.font = NSFont.systemFont(ofSize: 11, weight: .regular)
    cap.textColor = palette.ink3
    cap.translatesAutoresizingMaskIntoConstraints = false

    let copy = NSStackView(views: [mode, cap])
    copy.orientation = .vertical
    copy.alignment = .leading
    copy.spacing = 3

    let header = NSStackView(views: [icon, copy])
    header.orientation = .horizontal
    header.alignment = .top
    header.spacing = 9
    // Align header content with the rows' 10px text inset.
    header.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
    return header
  }

  private func separator(_ palette: StatusMenuPalette) -> NSView {
    let line = NSView()
    line.wantsLayer = true
    line.layer?.backgroundColor = palette.line.cgColor
    line.translatesAutoresizingMaskIntoConstraints = false
    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    // Inset the rule slightly.
    let wrap = NSView()
    wrap.translatesAutoresizingMaskIntoConstraints = false
    wrap.addSubview(line)
    NSLayoutConstraint.activate([
      wrap.heightAnchor.constraint(equalToConstant: 11),
      line.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
      line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 6),
      line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -6),
    ])
    return wrap
  }

  // MARK: positioning + dismissal

  /// Anchor the panel just under the status-item button, right-aligned to it, clamped
  /// to the screen.
  private func positionPanel(_ panel: StatusMenuPanel, under button: NSStatusBarButton) {
    guard let window = button.window else {
      // No anchor (very early launch / display reconfig) → center on the main screen
      // rather than pin to the bottom-left (0,0).
      if let visible = NSScreen.main?.visibleFrame {
        panel.setFrameOrigin(NSPoint(
          x: visible.midX - panel.frame.width / 2, y: visible.midY - panel.frame.height / 2))
      }
      return
    }
    let buttonScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
    var x = buttonScreen.maxX - panel.frame.width
    var y = buttonScreen.minY - panel.frame.height - 4
    if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
      x = min(max(x, visible.minX + 4), visible.maxX - panel.frame.width - 4)
      if y < visible.minY + 4 { y = visible.minY + 4 }  // pin to the visible bottom
    }
    panel.setFrameOrigin(NSPoint(x: x, y: y))
  }

  /// Click anywhere outside the panel (another app, the desktop, or our own Flutter
  /// window) dismisses it. A click on the status button is handled by the button's
  /// own toggle action, so it doesn't come through these monitors.
  private func installDismissMonitors() {
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] _ in self?.dismiss()
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] event in
      guard let self else { return event }
      // The status button's window is in-process, so its click DOES reach this local
      // monitor — exclude it (its own toggle action owns it) and the panel (row
      // selection); anything else (our other windows, etc.) dismisses.
      if event.window != self.panel && event.window != self.anchorWindow {
        self.dismiss()
      }
      return event
    }
  }

  private func removeMonitors() {
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    globalMonitor = nil
    localMonitor = nil
  }
}
