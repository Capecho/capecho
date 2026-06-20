import Cocoa
import CoreGraphics
import FlutterMacOS
import capture_native

// Sparkle (auto-update) ships ONLY in the direct-distribution build. The Mac App Store build excludes
// it (MAS forbids self-update + Sparkle's non-sandboxed XPC helpers fail App-Store validation), so the
// `Release-MAS` config does NOT define SPARKLE and does NOT link Sparkle.framework. See Runner-MAS.entitlements.
#if SPARKLE
  import Sparkle
#endif

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?

  /// Sparkle auto-updater. `startingUpdater: true` starts it at launch and schedules background
  /// checks; it reads SUFeedURL + SUPublicEDKey from Info.plist. In the sandbox, installs route
  /// through the Installer XPC service (SUEnableInstallerLauncherService). The "Check for Updates…"
  /// status-menu row triggers a manual check.
  #if SPARKLE
    private let updaterController = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
  #endif

  // Shared with `CaptureNativePlugin` (which reads/writes it from the Flutter
  // onboarding flow). Keep the string identical in both places.
  private static let onboardingCompleteKey = "capecho.onboardingComplete"
  private static let onboardingInitialContentSize = NSSize(width: 800, height: 720)

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Single-instance: Capecho is a menu-bar agent, so a SECOND live process (double-launching the app
    // while it's already running, `open -n`, a stray copy) would mean two status items, two journal
    // writers, and two global-hotkey registrations fighting over ⌥E. If another instance of this bundle
    // is already alive, hand off to it and bow out BEFORE installing our own status item. The common
    // "open it again" path — where LaunchServices reactivates the running instance instead of spawning a
    // new one — is handled by `applicationShouldHandleReopen` (which re-shows the window); this guards
    // only the rarer true-second-process case.
    //
    // KNOWN RACE (acceptable): the main nib already ran `MainFlutterWindow.awakeFromNib`, which booted the
    // headless Flutter engine + registered the global hotkeys, BEFORE this point. So a true second process
    // briefly initializes Dart / the local store / the hotkeys before it bails here. Tolerated: it
    // terminates within ms, Carbon allows duplicate hotkey registrations, and the journal is fsync'd +
    // idempotent. Fully pre-empting it would need a file-lock guard ahead of the engine boot (a custom
    // main.swift before `@main`) — not worth it for a pre-launch menu-bar agent.
    if let bundleId = Bundle.main.bundleIdentifier {
      let myPid = ProcessInfo.processInfo.processIdentifier
      let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        .first { $0.processIdentifier != myPid }
      if let existing {
        existing.activate()  // bring the running agent forward; it owns the menu bar + any open window
        NSApp.terminate(nil)
        return
      }
    }
    setUpStatusItem()
    // Bring the window forward whenever a surface is requested — by a menu item or
    // the global ⌥R / ⌥B hotkey (capture_native). The plugin relays the surface
    // name to Flutter off the same notification; here we just make it visible. The
    // agent lives for the whole session, so the observer is never removed.
    NotificationCenter.default.addObserver(
      forName: Notification.Name("capecho.showSurface"), object: nil, queue: .main
    ) { [weak self] _ in
      self?.showMainWindow()
    }
    // Hide the (single) window when a surface is dismissed (Esc / Done in Review / Word Book /
    // Settings). The capture_native plugin posts this off the Dart `hideWindow()` call. Hiding (not
    // closing) keeps the agent + the global ⌥E capture hotkey live — closing a surface returns to
    // just the menu bar, never quits. Never removed (the agent lives the whole session).
    NotificationCenter.default.addObserver(
      forName: Notification.Name("capecho.hideSurface"), object: nil, queue: .main
    ) { [weak self] _ in
      self?.mainFlutterWindow?.orderOut(nil)
      // No surface is on screen anymore → drop back to a Dock-less menu-bar agent.
      self?.setDockPresence(false)
    }
    // Settings → "Get Started" replays onboarding from another surface; the
    // capture_native plugin posts this off the Dart `requestOnboarding()` call.
    // Route it through the same present path as the menu-bar "Welcome" so the
    // window is resized + centered to the onboarding height before the flow shows.
    NotificationCenter.default.addObserver(
      forName: Notification.Name("capecho.requestOnboarding"), object: nil, queue: .main
    ) { [weak self] _ in
      self?.showOnboarding()
    }
    // First run: the agent normally launches with no visible window, but the
    // onboarding flow must be SEEN, so show the Flutter window. Flutter routes
    // to onboarding-vs-Word-Book off the same flag.
    if !UserDefaults.standard.bool(forKey: Self.onboardingCompleteKey) {
      showOnboardingWindowWhenReady()
    }
    // The custom dropdown replaces the status NSMenu. Settings and Quit stay
    // clickable rows without visible shortcut labels, but the underlying
    // ⌘, / ⌘Q app-menu key equivalents remain wired (and are not user-editable).
    configureMainMenuKeyEquivalents()
    // No `super` call: `FlutterAppDelegate` conforms to `NSApplicationDelegate`
    // but does not implement this optional method, so forwarding to super would
    // dispatch to an unimplemented selector and fault at launch.
  }

  // Capecho is a menu-bar agent: closing the Word Book window must NOT quit the
  // app — the status-item menu and the global ⌥E capture hotkey stay live.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// Re-opening the app — clicking its Dock icon while one is showing, or LaunchServices reactivating the
  /// already-running agent when the user "opens it again" — brings the existing window forward instead of
  /// doing nothing (and, with the single-instance guard above, instead of spawning a duplicate). `flag`
  /// is false when no window is visible; we re-show the main surface then. Returns true so AppKit also
  /// runs its default un-hide. (No `super`: FlutterAppDelegate doesn't implement this — see the note in
  /// applicationDidFinishLaunching — so forwarding would fault.)
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { showMainWindow() }
    return true
  }

  /// Show/hide the Dock icon + app menu by flipping the activation policy. Capecho launches as a menu-bar
  /// agent (LSUIElement ⇒ `.accessory`, no Dock icon); while a real surface window (Word Book / Review /
  /// Settings / onboarding) is on screen we switch to `.regular` so the app has a Dock icon to ⌘-Tab to
  /// and re-open, then back to `.accessory` when it hides. The native capture overlay is a separate
  /// floating panel that never routes through here, so it stays Dock-less (the founder's one exception).
  private func setDockPresence(_ visible: Bool) {
    if visible {
      guard NSApp.activationPolicy() != .regular else { return }
      NSApp.setActivationPolicy(.regular)
      return
    }
    // Hide → drop back to a Dock-less agent. KEY: defer the resign to the NEXT runloop. A MOUSE close
    // (clicking the red ✕) is still being processed, and AppKit RE-ACTIVATES us as it finishes the click
    // — right after a synchronous resign — so an active `.accessory` app gets its Dock tile back. (⌘W /
    // Esc are keyboard: no re-activation, which is exactly why those already dropped the tile while the ✕
    // didn't — the founder's observation.) Deferring lets the click fully drain so our resign is the last
    // word. (We deliberately DON'T touch `.prohibited`: momentarily bouncing through it crashed the
    // Flutter engine in a Dart microtask — plain `.regular`→`.accessory` + resigning is enough.)
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // A surface may have re-opened during the hop — don't strip the Dock icon out from under it.
      guard NSApp.activationPolicy() == .regular, self.mainFlutterWindow?.isVisible != true else { return }
      NSApp.setActivationPolicy(.accessory)
      // Resign active so the Dock drops the now-agent tile (an ACTIVE `.accessory` app keeps its tile).
      // Use deactivate() rather than force-activating the app the user came from: forcing the prior app
      // forward yanks focus (and Spaces), which the founder found jarring + unnecessary. Now that the
      // resign is DEFERRED past the click, deactivate() resigns us so the tile still drops, and macOS
      // restores focus on its own — no Space-jumping `activate()`.
      NSApp.deactivate()
    }
  }

  // MARK: - Menu-bar status item

  /// The warm-glass dropdown shown from the menu-bar C.
  /// Its capture-mode line reads the live Screen-Recording state (no prompt).
  private lazy var statusMenu = StatusMenuController(
    captureArmed: { CGPreflightScreenCaptureAccess() },
    captureShortcut: { CapechoShortcutPreferences.display(for: .capture) })

  private func setUpStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      let image = Self.capechoStatusImage()
      image.isTemplate = true
      button.image = image
      // No `item.menu`: a click toggles our custom warm-glass dropdown rather than
      // the system NSMenu (which can't be restyled to the Caffeine look).
      button.action = #selector(toggleStatusMenu)
      button.target = self
    }
    statusItem = item

    configureStatusMenuRows()
    NotificationCenter.default.addObserver(
      forName: CapechoShortcutPreferences.changedNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.configureStatusMenuRows()
    }
  }

  private func configureStatusMenuRows() {
    // Rows reuse the same `capecho.showSurface` / onboarding paths as the global
    // Review / Word Book hotkeys. Grouping: [header] ─ Review · Word Book ─
    // Settings · Welcome · Updates ─ Quit. (`buildContent` adds the post-header separator.)
    // Built as a typed var (not an array literal with an inline #if — Swift can't parse #if between
    // collection-literal elements). The "Check for Updates…" row exists only in the Sparkle build.
    var rows: [StatusMenuRow] = [
      .item(
        title: "Review",
        shortcut: CapechoShortcutPreferences.display(for: .review),
        action: { [weak self] in self?.requestSurface("review") }),
      .item(
        title: "Word Book",
        shortcut: CapechoShortcutPreferences.display(for: .wordBook),
        action: { [weak self] in self?.requestSurface("wordBook") }),
      .separator,
      .item(title: "Settings", shortcut: nil, action: { [weak self] in self?.requestSurface("settings") }),
      .item(title: "Get Started", shortcut: nil, action: { [weak self] in self?.showOnboarding() }),
    ]
    #if SPARKLE
      rows.append(
        .item(title: "Check for Updates…", shortcut: nil, action: { [weak self] in self?.checkForUpdates() }))
    #endif
    rows.append(.separator)
    rows.append(.item(title: "Quit Capecho", shortcut: nil, action: { [weak self] in self?.quit() }))
    statusMenu.setRows(rows)
  }

  /// Template menu-bar icon: the three C-shaped echo paths only, no app-icon background.
  private static func capechoStatusImage() -> NSImage {
    let size = NSSize(width: 24, height: 18)
    let image = NSImage(size: size, flipped: false) { rect in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      context.saveGState()
      defer { context.restoreGState() }

      context.translateBy(x: 0, y: rect.height)
      context.scaleBy(x: 1, y: -1)

      let sourceBounds = CGRect(x: 4.8, y: 7.1, width: 18.4, height: 13.8)
      let baseTargetBounds = rect.insetBy(dx: 2.5, dy: 2)
      let targetBounds = baseTargetBounds.insetBy(
        dx: baseTargetBounds.width * 0.05,
        dy: baseTargetBounds.height * 0.05)
      let iconScale = min(targetBounds.width / sourceBounds.width, targetBounds.height / sourceBounds.height)
      context.translateBy(
        x: targetBounds.minX + (targetBounds.width - sourceBounds.width * iconScale) / 2,
        y: targetBounds.minY + (targetBounds.height - sourceBounds.height * iconScale) / 2)
      context.scaleBy(x: iconScale, y: iconScale)
      context.translateBy(x: -sourceBounds.minX, y: -sourceBounds.minY)

      context.translateBy(x: -3.08, y: -3.5)
      context.scaleBy(x: 1.25, y: 1.25)
      context.setStrokeColor(NSColor.black.cgColor)
      context.setLineWidth(1.6)
      context.setLineCap(.round)
      context.setLineJoin(.round)

      Self.strokeSvgArc(
        context,
        start: CGPoint(x: 10.5 - 2.2, y: 13 + 3),
        end: CGPoint(x: 10.5 - 2.2, y: 9 + 3),
        rx: 2.3,
        ry: 2.3)
      Self.strokeSvgArc(
        context,
        start: CGPoint(x: 15.5 - 1.7, y: 14.7 + 3),
        end: CGPoint(x: 15.5 - 1.7, y: 7.3 + 3),
        rx: 5,
        ry: 4.1)
      Self.strokeSvgArc(
        context,
        start: CGPoint(x: 21 - 0.8, y: 15.7 + 3),
        end: CGPoint(x: 21 - 0.8, y: 6.3 + 3),
        rx: 6.5,
        ry: 5.0)
      return true
    }
    image.accessibilityDescription = "Capecho"
    return image
  }

  private static func strokeSvgArc(
    _ context: CGContext,
    start: CGPoint,
    end: CGPoint,
    rx: CGFloat,
    ry: CGFloat
  ) {
    let points = svgArcPoints(start: start, end: end, rx: rx, ry: ry)
    guard let first = points.first else { return }
    context.beginPath()
    context.move(to: first)
    for point in points.dropFirst() {
      context.addLine(to: point)
    }
    context.strokePath()
  }

  private static func svgArcPoints(
    start: CGPoint,
    end: CGPoint,
    rx inputRx: CGFloat,
    ry inputRy: CGFloat,
    largeArc: Bool = false,
    sweep: Bool = true,
    segments: Int = 64
  ) -> [CGPoint] {
    var rx = inputRx
    var ry = inputRy
    let dx = (start.x - end.x) / 2
    let dy = (start.y - end.y) / 2
    let lambda = (dx * dx) / (rx * rx) + (dy * dy) / (ry * ry)
    if lambda > 1 {
      let scale = sqrt(lambda)
      rx *= scale
      ry *= scale
    }

    let numerator = max(0, rx * rx * ry * ry - rx * rx * dy * dy - ry * ry * dx * dx)
    let denominator = rx * rx * dy * dy + ry * ry * dx * dx
    let sign: CGFloat = largeArc == sweep ? -1 : 1
    let coefficient = denominator == 0 ? 0 : sign * sqrt(numerator / denominator)
    let center = CGPoint(
      x: coefficient * (rx * dy / ry) + (start.x + end.x) / 2,
      y: coefficient * (-ry * dx / rx) + (start.y + end.y) / 2)

    let ux = (start.x - center.x) / rx
    let uy = (start.y - center.y) / ry
    let vx = (end.x - center.x) / rx
    let vy = (end.y - center.y) / ry
    let theta1 = vectorAngle(ux: 1, uy: 0, vx: ux, vy: uy)
    var delta = vectorAngle(ux: ux, uy: uy, vx: vx, vy: vy)
    if !sweep && delta > 0 {
      delta -= 2 * .pi
    } else if sweep && delta < 0 {
      delta += 2 * .pi
    }

    return (0...segments).map { i in
      let t = theta1 + delta * CGFloat(i) / CGFloat(segments)
      return CGPoint(x: center.x + rx * cos(t), y: center.y + ry * sin(t))
    }
  }

  private static func vectorAngle(ux: CGFloat, uy: CGFloat, vx: CGFloat, vy: CGFloat) -> CGFloat {
    let dot = ux * vx + uy * vy
    let length = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
    let clamped = max(-1, min(1, dot / length))
    let sign: CGFloat = (ux * vy - uy * vx) < 0 ? -1 : 1
    return sign * acos(clamped)
  }

  @objc private func toggleStatusMenu() {
    guard let button = statusItem?.button else { return }
    statusMenu.toggle(from: button)
  }

  /// Repoint the app menu's Preferences… (⌘,) at our Settings surface so the
  /// shortcut survives dropping the status NSMenu. Quit (⌘Q) is already wired
  /// to `terminate:` in MainMenu.xib — we leave it alone. Neither shortcut is
  /// user-editable (the user-configurable shortcuts cover Capture / Review /
  /// Word Book only).
  private func configureMainMenuKeyEquivalents() {
    for top in NSApp.mainMenu?.items ?? [] {
      for sub in top.submenu?.items ?? [] where sub.keyEquivalent == "," {
        sub.target = self
        sub.action = #selector(openSettingsShortcut)
        sub.isEnabled = true
      }
    }
  }

  @objc private func openSettingsShortcut() { requestSurface("settings") }

  /// Manual "Check for Updates…". Sparkle shows its own progress/alert UI and, in the sandbox, routes
  /// the install through the Installer XPC service enabled in Info.plist.
  #if SPARKLE
    @objc private func checkForUpdates() { updaterController.checkForUpdates(nil) }
  #endif

  /// Posts the shared surface-open notification. The `capture_native` plugin relays
  /// the surface to Flutter (which navigates), and `self` observes the same
  /// notification to bring the window forward — so menu clicks and the global
  /// ⌥R / ⌥B hotkeys (which post the same notification) share one path.
  private func requestSurface(_ surface: String) {
    NotificationCenter.default.post(
      name: Notification.Name("capecho.showSurface"), object: nil,
      userInfo: ["surface": surface])
  }

  /// Brings the window forward and asks Flutter to re-show the onboarding flow.
  /// The `capture_native` plugin observes this notification and relays it to
  /// Dart (keep the name identical to the plugin's observer).
  @objc private func showOnboarding() {
    presentOnboardingWindow()
    NotificationCenter.default.post(
      name: Notification.Name("capecho.showOnboarding"), object: nil)
  }

  /// Sizes the window to the verified step-1 onboarding height and centers it,
  /// then brings it forward. Later steps vertically center inside this content
  /// height; taller/resized cases remain scrollable in Flutter.
  private func presentOnboardingWindow() {
    guard let window = mainFlutterWindow else { return }
    setDockPresence(true)
    window.setContentSize(Self.onboardingInitialContentSize)
    window.center()
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  /// Brings the (single) Flutter window forward — the Word Book viewer normally,
  /// the onboarding flow on first run. Safe to call before/after the window is
  /// wired (no-op while `mainFlutterWindow` is still nil).
  private func showMainWindow() {
    guard let window = mainFlutterWindow else { return }
    setDockPresence(true)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  /// First-run only: `mainFlutterWindow` may not be wired the instant launch
  /// finishes (the engine boots during nib load), so poll briefly — bounded —
  /// before ordering it front. Without this a slow engine boot could leave the
  /// agent with no visible window and the onboarding flag never set (CR #1).
  private func showOnboardingWindowWhenReady(attempt: Int = 0) {
    if mainFlutterWindow != nil {
      presentOnboardingWindow()
      return
    }
    guard attempt < 40 else {  // ~2s @ 50ms
      NSLog("Capecho: onboarding window never became available; first-run flow not shown")
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      self?.showOnboardingWindowWhenReady(attempt: attempt + 1)
    }
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}
