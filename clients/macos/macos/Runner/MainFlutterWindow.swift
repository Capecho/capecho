import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  override func awakeFromNib() {
    // Capecho is a menu-bar AGENT (LSUIElement): the Flutter window is the Word
    // Book viewer, shown on demand from the status-item menu — it is NOT shown at
    // launch (the xib sets visibleAtLaunch=NO). The capture overlay is native and
    // appears on ⌥E independently.
    //
    // So we run the Flutter engine EXPLICITLY and headlessly here, rather than
    // letting it boot lazily when a window first displays: Dart `main()` must run
    // at launch (it owns the local store + the capture→overlay orchestration and
    // registers the global hotkey), even though no window is visible yet.
    let engine = FlutterEngine(
      name: "capecho", project: FlutterDartProject(), allowHeadlessExecution: true)
    engine.run(withEntrypoint: nil)
    RegisterGeneratedPlugins(registry: engine)

    let flutterViewController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: false)

    // A floor so the windowed surfaces (the Word Book toolbar, the Review card) never have to lay
    // out below their comfortable width when the user resizes.
    self.contentMinSize = NSSize(width: 640, height: 440)

    // Immersive title bar: Capecho's surfaces wear their own warm-glass header (the shared
    // `SurfaceHeader` on the Flutter side), so the default macOS grey title bar reads as a second,
    // uglier chrome stacked on top. Make the title bar TRANSPARENT + full-size-content so the warm
    // canvas runs edge to edge and the traffic-light buttons float over it. The title bar still
    // exists (so the top strip stays draggable and the lights keep their slot) — it just shows the
    // Flutter content through it. The Flutter `SurfaceHeader` reserves a left gutter on macOS so its
    // leading control (back chevron / echo mark) clears these floating lights.
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)

    super.awakeFromNib()

    // Keep `.fullScreenAuxiliary` (can still overlay a full-screen Space) but DON'T add
    // `.moveToActiveSpace`: that "follow me to the active Space" flag made the window a transient macOS
    // doesn't treat as OWNING a Space, so on Space-return it reactivated the desktop's resident app and
    // buried this surface (the "briefly shown, then covered" flash). As a plain resident, macOS keeps it
    // front on return.
    self.collectionBehavior = [.fullScreenAuxiliary]

    // Become our own delegate so the red ✕ traffic-light routes through `windowShouldClose:`. The
    // `performClose` override below catches ⌘W, but on macOS 26 the red ✕ does NOT call performClose — it
    // goes through the delegate's `windowShouldClose:` instead, so without this the ✕ close skipped our
    // hide path (the window hid but the Dock icon never dropped).
    self.delegate = self
  }

  /// The red close button / ⌘W must HIDE this single agent window (return to the menu bar), never DESTROY
  /// it — Capecho is an LSUIElement agent that re-shows this same window (with its already-booted Flutter
  /// engine) on demand, so a real close would strand the agent with no re-openable window. Route the
  /// user-close affordances through the shared hide path (AppDelegate's observer does orderOut + drops the
  /// Dock icon), exactly like Esc / Done. We intentionally don't call super (no NSWindow.close()). Keep
  /// the notification name identical to AppDelegate's `capecho.hideSurface` observer + the plugin poster.
  override func performClose(_ sender: Any?) {
    NotificationCenter.default.post(name: Notification.Name("capecho.hideSurface"), object: nil)
  }

  /// The red ✕ traffic-light closes via the delegate, not performClose, on macOS 26. HIDE (post the shared
  /// hide notification → orderOut + drop the Dock icon) and return false so the single agent window is
  /// never destroyed (stays re-openable). Same end state as ⌘W / Esc.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    NotificationCenter.default.post(name: Notification.Name("capecho.hideSurface"), object: nil)
    return false
  }
}
