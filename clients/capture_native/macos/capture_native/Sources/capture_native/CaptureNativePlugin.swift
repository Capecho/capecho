import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

/// Flutter bridge for the native capture adapter.
///
/// Thin glue only: it registers the global hotkey + the Method/Event channels,
/// and forwards to `CaptureEngine` (capture + OCR + highlight detection). It
/// does NO reconstruction — the engine returns a platform-neutral OCR-snapshot
/// dictionary which is emitted verbatim on the event channel; the shared Dart
/// core turns it into a `CaptureResult`.
///
/// - MethodChannel `capture_native`: triggerCapture / permission queries.
/// - EventChannel `capture_native/snapshots`: one snapshot dict per capture
///   (hotkey or manual trigger). Failures surface as a FlutterError event.
public class CaptureNativePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let engine = CaptureEngine()
  private let hotKey = HotKeyController()
  /// The brief OCR-phase loader (CaptureLoadingPanel) — shown the instant the screenshot
  /// is secured, dismissed when the result overlay presents.
  private let loading = CaptureLoadingController()
  private let journal = CaptureJournal()
  /// Tracks clipboard freshness for the cascade (US-4.1). Polls `changeCount`
  /// only; reads contents solely at capture time.
  private let pasteboard = PasteboardMonitor()
  private var eventSink: FlutterEventSink?
  /// Retained so the native overlay can call BACK into Dart (`onCaptureSaved`)
  /// to trigger the local-store drain after a durable append.
  private var methodChannel: FlutterMethodChannel?
  /// The native warm-glass overlay, created on first use (main thread).
  private var overlay: CaptureOverlayController?
  /// Daily review reminder (US-14.1): native UNUserNotificationCenter scheduling + the tap→Review
  /// route. Created at registration so the notification delegate is live before any tap arrives.
  private var reminders: ReminderNotificationScheduler?

  // §14 capture-time instrumentation (CEO-10). MONOTONIC clock (DispatchTime.uptimeNanoseconds, NOT
  // wall-clock — an NTP/manual clock change mid-capture must not produce negative/huge durations):
  // t0 = hotkey/trigger → t1 = overlay present → t2 = durable save. The deltas (selToPanel = system
  // latency, panelToSave = human dwell, total) ride the `onCaptureLifecycle` channel to the Dart
  // MetricsRecorder, which builds the metric events. Durations/enums/bools ONLY — never text (T8).
  private var captureStartedAtNanos: UInt64?    // t0
  private var overlayPresentedAtNanos: UInt64?  // t1
  private var awaitingCaptureOutcome = false    // a real-unit overlay is up, not yet saved/abandoned
  // Monotonic capture id: ⌥E fires an async OCR Task; a newer ⌥E supersedes an older one, so the older
  // Task must DROP its (late, possibly stale) snapshot instead of painting over the newer capture's
  // overlay (rapid ⌥E / key-repeat — capture P1). Read + written only on the main thread.
  private var captureSeq: UInt64 = 0
  private var presentedSource: String?          // the presented capture's source (metric metadata)
  private var presentedDefaultLanguage: String? // the default target shown (→ langOverride at save)
  /// Allowed capture sources — must match the local store's `kJournalSources`,
  /// so the native side never durably writes a record the Dart drain would
  /// reject (which would otherwise wedge the journal — review H1).
  private static let allowedSources: Set<String> = ["ocr", "clipboard", "selection"]

  /// SR-OFF direct-clipboard mode's freshness window (vs PasteboardMonitor's tight 3s default, which
  /// gates the SR-on OVERRIDE of borderline OCR). SR-off's clipboard is the only input, so a deliberate
  /// copy→⌥E gets generous slack; a clipboard older than this still falls through to the editable
  /// overlay rather than becoming a confident, possibly-unrelated capture (capture P1 / D4).
  private static let srOffClipboardFreshnessWindow: TimeInterval = 10.0

  /// First-run flag, shared with `AppDelegate` (which reads it at launch to
  /// decide whether to show the onboarding window). Keep the key identical.
  private static let onboardingCompleteKey = "capecho.onboardingComplete"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = CaptureNativePlugin()

    let methodChannel = FlutterMethodChannel(
      name: "capture_native", binaryMessenger: registrar.messenger)
    instance.methodChannel = methodChannel
    registrar.addMethodCallDelegate(instance, channel: methodChannel)

    let eventChannel = FlutterEventChannel(
      name: "capture_native/snapshots", binaryMessenger: registrar.messenger)
    eventChannel.setStreamHandler(instance)

    // Start tracking clipboard freshness (changeCount polling only).
    instance.pasteboard.start()

    // Daily review reminder (US-14.1): create the scheduler now so its UNUserNotificationCenter
    // delegate is set at launch — a tap that wakes the agent then routes to Review.
    instance.reminders = ReminderNotificationScheduler()

    instance.registerConfiguredHotKeys()

    // The menu-bar "Welcome" item (AppDelegate) posts this; relay it to Flutter so
    // it re-routes to the onboarding flow regardless of the completion flag. Keep
    // the name identical to AppDelegate's post. The agent lives for the whole app
    // session, so we never remove the observer.
    NotificationCenter.default.addObserver(
      forName: Notification.Name("capecho.showOnboarding"),
      object: nil, queue: .main
    ) { [weak instance] _ in
      instance?.methodChannel?.invokeMethod("showOnboarding", arguments: nil)
    }

    // ⌥R / ⌥B and the menu-bar Review / Word Book / Settings items post this;
    // relay the requested surface to Flutter, which navigates to it. (AppDelegate
    // observes the same notification to bring the window forward.) Never removed.
    NotificationCenter.default.addObserver(
      forName: Notification.Name("capecho.showSurface"),
      object: nil, queue: .main
    ) { [weak instance] note in
      guard let surface = note.userInfo?["surface"] as? String, !surface.isEmpty else { return }
      instance?.methodChannel?.invokeMethod("showSurface", arguments: surface)
    }
  }

  /// Posts the shared surface-open notification (used by the global ⌥R / ⌥B
  /// hotkeys). The notification name + `surface` key are shared verbatim with
  /// AppDelegate's menu items and the relay observer above.
  private static func postShowSurface(_ surface: String) {
    NotificationCenter.default.post(
      name: Notification.Name("capecho.showSurface"), object: nil,
      userInfo: ["surface": surface])
  }

  /// Register the three user-editable global shortcuts from UserDefaults, falling
  /// back to ⌥E / ⌥R / ⌥B. Settings and Quit are deliberately not global hotkeys.
  private func registerConfiguredHotKeys() {
    for action in CapechoShortcutAction.allCases {
      let shortcut = CapechoShortcutPreferences.shortcut(for: action)
      if !registerHotKey(action: action, shortcut: shortcut) {
        NSLog("Capecho: shortcut \(shortcut.display) for \(action.rawValue) is inactive")
      }
    }
  }

  @discardableResult
  private func registerHotKey(action: CapechoShortcutAction, shortcut: CapechoShortcut) -> Bool {
    hotKey.register(
      keyCode: shortcut.keyCode,
      modifiers: shortcut.modifierMask,
      id: action.hotKeyID,
      onPressed: hotKeyHandler(for: action))
  }

  private func hotKeyHandler(for action: CapechoShortcutAction) -> () -> Void {
    switch action {
    case .capture:
      return { [weak self] in self?.performCapture() }
    case .review:
      return { Self.postShowSurface("review") }
    case .wordBook:
      return { Self.postShowSurface("wordBook") }
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "triggerCapture":
      performCapture()
      result(nil)
    case "setAppearanceMode":
      // Match app-wide native appearance to the Capecho app's theme (#5) so the menu-bar status dropdown
      // (StatusMenuController resolves NSApp.effectiveAppearance on open) + the capture overlay follow the
      // app's Light/Dark choice, not the OS. 'system' → clear the override (follow OS).
      let mode = (call.arguments as? [String: Any])?["mode"] as? String
      DispatchQueue.main.async { NSApp.appearance = Self.appAppearance(for: mode) }
      result(nil)
    case "hasScreenRecordingPermission":
      result(engine.hasScreenRecordingPermission())
    case "requestScreenRecordingPermission":
      result(engine.requestScreenRecordingPermission())
    case "onboardingComplete":
      result(UserDefaults.standard.bool(forKey: Self.onboardingCompleteKey))
    case "completeOnboarding":
      UserDefaults.standard.set(true, forKey: Self.onboardingCompleteKey)
      result(nil)
    case "openScreenRecordingSettings":
      openScreenRecordingSettings()
      result(nil)
    case "getShortcuts":
      result(CapechoShortcutPreferences.allDictionaries())
    case "setShortcut":
      handleSetShortcut(call, result)
    case "hideWindow":
      // Post the shared hide notification; AppDelegate orders the (single) Flutter window out so a
      // dismissed surface returns to the menu-bar agent without quitting. Keep the name in sync with
      // AppDelegate's `capecho.hideSurface` observer.
      NotificationCenter.default.post(name: Notification.Name("capecho.hideSurface"), object: nil)
      result(nil)
    case "requestOnboarding":
      // Settings → "Get Started" replays onboarding from another surface. Post the shared
      // request; AppDelegate (re)presents the onboarding window (resize + center) and re-posts
      // `capecho.showOnboarding`, which the observer above relays back to Flutter. Keep the name in
      // sync with AppDelegate's `capecho.requestOnboarding` observer.
      NotificationCenter.default.post(name: Notification.Name("capecho.requestOnboarding"), object: nil)
      result(nil)
    case "saveCapture":
      handleSaveCapture(call, result)
    case "showOverlay":
      handleShowOverlay(call, result)
    case "updateExplanation":
      handleUpdateExplanation(call, result)
    case "updateContextPreview":
      handleUpdateContextPreview(call, result)
    case "saveExportFile":
      handleSaveExportFile(call, result)
    case "journalEntries":
      let afterSeq = (call.arguments as? [String: Any])?["afterSeq"] as? Int ?? 0
      result(journal.entries(afterSeq: afterSeq))
    case "installId":
      result(journal.installID)
    case "requestNotificationPermission":
      // Daily review reminder (US-14.1): its own OS prompt, requested when the user arms a reminder.
      // `reminders` is created in `register`, so it's always present; degrade safely if it somehow isn't
      // (rather than spin up a throwaway whose notification delegate would immediately deallocate).
      guard let reminders = reminders else {
        result(false)
        return
      }
      reminders.requestPermission { granted in result(granted) }
    case "scheduleDailyReminder":
      guard let args = call.arguments as? [String: Any],
        let hour = args["hour"] as? Int, let minute = args["minute"] as? Int,
        let title = args["title"] as? String, let body = args["body"] as? String
      else {
        result(FlutterError(
          code: "bad_args",
          message: "scheduleDailyReminder requires hour, minute, title, body",
          details: nil))
        return
      }
      reminders?.scheduleDaily(hour: hour, minute: minute, title: title, body: body)
      result(nil)
    case "cancelReminder":
      reminders?.cancel()
      result(nil)
    case "showImmediateNotification":
      // Daily review reminder (US-14.1): the one-time "reminders on" confirmation, fired the moment the
      // user enables reminders so the feature visibly works. A distinct id from the daily one (it never
      // replaces an armed reminder).
      guard let args = call.arguments as? [String: Any],
        let title = args["title"] as? String, let body = args["body"] as? String
      else {
        result(FlutterError(
          code: "bad_args",
          message: "showImmediateNotification requires title, body",
          details: nil))
        return
      }
      reminders?.showImmediate(title: title, body: body)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleSetShortcut(
    _ call: FlutterMethodCall, _ result: @escaping FlutterResult
  ) {
    guard let args = call.arguments as? [String: Any],
      let rawAction = args["action"] as? String,
      let action = CapechoShortcutAction(rawValue: rawAction),
      let key = args["key"] as? String,
      let modifiers = args["modifiers"] as? [String]
    else {
      result(FlutterError(
        code: "bad_args",
        message: "setShortcut requires action, key, and modifiers",
        details: nil))
      return
    }

    let shortcut: CapechoShortcut
    do {
      shortcut = try CapechoShortcutPreferences.validate(
        action: action, key: key, modifiers: modifiers)
    } catch let error as CapechoShortcutPreferences.ShortcutError {
      result(FlutterError(code: error.code, message: error.localizedDescription, details: nil))
      return
    } catch {
      result(FlutterError(code: "bad_shortcut", message: error.localizedDescription, details: nil))
      return
    }

    let previous = CapechoShortcutPreferences.shortcut(for: action)
    guard registerHotKey(action: action, shortcut: shortcut) else {
      _ = registerHotKey(action: action, shortcut: previous)
      result(FlutterError(
        code: "hotkey_unavailable",
        message: "That shortcut is already used by macOS or another app.",
        details: nil))
      return
    }

    CapechoShortcutPreferences.store(shortcut, for: action)
    result(shortcut.dictionary(action: action))
  }

  /// Durably appends one capture to the journal (fsync) and returns
  /// `{clientRowId, seq}` — the signal the overlay uses to show the saved
  /// ink-dot. The Flutter side then drains the journal into the local store.
  private func handleSaveCapture(
    _ call: FlutterMethodCall, _ result: @escaping FlutterResult
  ) {
    guard let args = call.arguments as? [String: Any],
      let surfaceUnit = args["surfaceUnit"] as? String,
      let targetLanguage = args["targetLanguage"] as? String,
      let source = args["source"] as? String
    else {
      result(FlutterError(
        code: "bad_args",
        message: "saveCapture requires surfaceUnit, targetLanguage, source",
        details: nil))
      return
    }
    switch appendValidated(
      surfaceUnit: surfaceUnit,
      targetLanguage: targetLanguage,
      contextText: args["contextText"] as? String,
      contextLanguage: args["contextLanguage"] as? String,
      spanStart: args["spanStart"] as? Int,
      spanEnd: args["spanEnd"] as? Int,
      source: source,
      sourceApp: args["sourceApp"] as? String,
      sourceTitle: args["sourceTitle"] as? String,
      detectedLanguage: args["detectedLanguage"] as? String,
      detectedLanguageConfidence: args["detectedLanguageConfidence"] as? Double,
      capturedAt: args["capturedAt"] as? Int)
    {
    case .success(let receipt):
      result(receipt)
    case .failure(let error):
      result(FlutterError(code: error.code, message: error.message, details: nil))
    }
  }

  /// A validation/append failure: a `bad_args` rejection (would wedge the Dart
  /// drain, review H1) or a `save_failed` durable-write error.
  private struct AppendError: Error {
    let code: String
    let message: String
  }

  /// Validates a capture and, if valid, durably appends it (fsync). Shared by
  /// the Flutter `saveCapture` channel and the native overlay's Save, so BOTH
  /// paths enforce the same invariants before the durable write (source in the
  /// allow-list, non-empty unit, well-formed span) — the native side must never
  /// fsync a record the Dart drain would reject.
  private func appendValidated(
    surfaceUnit: String,
    targetLanguage: String,
    contextText: String?,
    contextLanguage: String?,
    spanStart: Int?,
    spanEnd: Int?,
    source: String,
    sourceApp: String? = nil,
    sourceTitle: String? = nil,
    detectedLanguage: String? = nil,
    detectedLanguageConfidence: Double? = nil,
    capturedAt: Int?
  ) -> Result<[String: Any], AppendError> {
    guard CaptureNativePlugin.allowedSources.contains(source) else {
      return .failure(AppendError(code: "bad_args", message: "unknown source '\(source)'"))
    }
    // Reject a unit with no real word content — empty, or only whitespace / punctuation / symbols that
    // the dedup key (localDedupKey / dedup-key.ts) normalizes AWAY. Its key would be empty, so the drain
    // creates NO word: a native "Saved" that silently saves nothing (capture P0). This is the shared
    // backstop for BOTH Save paths (the overlay's handleSave + the Flutter saveCapture channel).
    guard UnitNormalization.hasWordContent(surfaceUnit) else {
      return .failure(AppendError(code: "bad_args", message: "surfaceUnit has no word content"))
    }
    let spanValid =
      (spanStart == nil && spanEnd == nil)
      || (spanStart != nil && spanEnd != nil && spanStart! >= 0 && spanEnd! >= spanStart!)
    guard spanValid else {
      return .failure(AppendError(code: "bad_args", message: "invalid span"))
    }
    let at = capturedAt ?? Int(Date().timeIntervalSince1970 * 1000)
    let outcome = journal.append(
      surfaceUnit: surfaceUnit,
      targetLanguage: targetLanguage,
      contextText: contextText,
      contextLanguage: contextLanguage,
      spanStart: spanStart,
      spanEnd: spanEnd,
      source: source,
      sourceApp: sourceApp,
      sourceTitle: sourceTitle,
      detectedLanguage: detectedLanguage,
      detectedLanguageConfidence: detectedLanguageConfidence,
      capturedAt: at)
    if let errorMessage = outcome["error"] as? String {
      return .failure(AppendError(code: "save_failed", message: errorMessage))
    }
    return .success(outcome)
  }

  // MARK: - Native overlay

  /// Map the Dart `brightness` arg ("light" | "dark") to an explicit overlay appearance (#2); anything
  /// else (nil / unknown / "system") returns nil so the overlay follows the OS appearance.
  private static func overlayAppearance(for brightness: String?) -> NSAppearance? {
    switch brightness {
    case "dark": return NSAppearance(named: .darkAqua)
    case "light": return NSAppearance(named: .aqua)
    default: return nil
    }
  }

  /// Map the Dart app theme mode ("light" | "dark" | "system") to an app-wide NSAppearance for `NSApp`
  /// (#5); "system" / unknown → nil so the app follows the OS appearance.
  private static func appAppearance(for mode: String?) -> NSAppearance? {
    switch mode {
    case "dark": return NSAppearance(named: .darkAqua)
    case "light": return NSAppearance(named: .aqua)
    default: return nil
    }
  }

  /// Shows the native warm-glass overlay for a reconstructed capture. Dart calls
  /// this AFTER the shared core has produced the `CaptureResult`; the overlay
  /// owns correction/language choice and its Save goes straight to the durable
  /// journal (native), then signals Dart (`onCaptureSaved`) to drain.
  private func handleShowOverlay(
    _ call: FlutterMethodCall, _ result: @escaping FlutterResult
  ) {
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "bad_args", message: "showOverlay requires a map", details: nil))
      return
    }
    let capture = OverlayCapture(
      unit: (args["unit"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
      context: args["context"] as? String ?? "",
      source: args["source"] as? String ?? "ocr",
      defaultTargetLanguage: args["targetLanguage"] as? String ?? "en",
      learningLanguage: args["learningLanguage"] as? String ?? "en",
      defaultExplanationLanguage: args["explanationLanguage"] as? String ?? "en",
      alreadySaved: args["alreadySaved"] as? Bool ?? false,
      suggestedTargetLanguage: args["suggestedTargetLanguage"] as? String,
      detectedSpanLanguage: args["detectedSpanLanguage"] as? String,
      detectedSpanLanguageConfidence: args["detectedSpanLanguageConfidence"] as? Double ?? 0,
      sourceApp: args["sourceApp"] as? String,
      sourceTitle: args["sourceTitle"] as? String)
    // The Capecho app resolves its Light/Dark/System theme to a concrete brightness and passes it (#2),
    // so the overlay matches the app rather than the OS; missing / unknown → follow the OS.
    let brightness = args["brightness"] as? String
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      // Hand off the OCR-phase loader to the result overlay (a no-op if it wasn't shown,
      // e.g. the SR-off direct-clipboard path).
      self.loading.dismiss()
      // t1 (monotonic): the overlay-present instant. selToPanel = t1 - t0 is the system latency the
      // GATE judges "fast" on. A real unit is now shown → this capture is abandonable until saved.
      self.overlayPresentedAtNanos = DispatchTime.now().uptimeNanoseconds
      self.awaitingCaptureOutcome = true
      self.presentedSource = capture.source
      self.presentedDefaultLanguage = capture.defaultTargetLanguage
      self.emitLifecyclePresented()
      let overlay = self.ensureOverlay()
      overlay.appearanceOverride = Self.overlayAppearance(for: brightness)  // #2: follow the app theme
      overlay.present(capture)
    }
    result(nil)
  }

  /// Push a free-explanation state into the currently-shown overlay. Dart calls this after a `/explain`
  /// fetch with `phase` = loading | ready (+ readings) | failed | not_a_word | lang_unsupported. A no-op
  /// if no overlay is present (we use the existing instance — never create one just to update it).
  private func handleUpdateExplanation(
    _ call: FlutterMethodCall, _ result: @escaping FlutterResult
  ) {
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "bad_args", message: "updateExplanation requires a map", details: nil))
      return
    }
    let phase = args["phase"] as? String ?? ""
    let state: ExplanationSlotState
    switch phase {
    case "ready":
      // Senses payload: each reading carries DISPLAY-READY pronunciation parts ({label,
      // display}, computed Dart-side from the target profile), an `isIdiom` flag (badge, no IPA), and
      // `pos` rows — each {partOfSpeech, senses, note} laid out Dart-side (capecho_app_core
      // `computeSenseLayout`); `note` is a form note shared by every sense, shown once at the front.
      // Every sense is shown (no cap, no "more" hint — the region scrolls if tall).
      // A blob with no surviving sense renders .failed (must-pass), never a partial card.
      let rawReadings = (args["readings"] as? [[String: Any]] ?? []).map {
        dict -> (
          pronunciations: [(label: String?, display: String)], isIdiom: Bool,
          pos: [(partOfSpeech: String, senses: [String], note: String)]
        ) in
        let pronunciations = (dict["pronunciations"] as? [[String: Any]] ?? []).map {
          (label: $0["label"] as? String, display: $0["display"] as? String ?? "")
        }
        let pos = (dict["pos"] as? [[String: Any]] ?? []).map {
          (
            partOfSpeech: $0["partOfSpeech"] as? String ?? "",
            senses: $0["senses"] as? [String] ?? [],
            note: $0["note"] as? String ?? ""
          )
        }
        return (
          pronunciations: pronunciations,
          isIdiom: dict["isIdiom"] as? Bool ?? false,
          pos: pos)
      }
      if let exp = OverlayExplanation.from(readings: rawReadings) {
        state = .ready(exp)
      } else {
        state = .failed
      }
    case "loading":
      state = .loading
    case "failed":
      state = .failed
    case "not_a_word":
      // The host's junk / gibberish gate caught a non-word locally (no /explain spent) — show the calm
      // "not a word" slot. The capture still saved.
      state = .notAWord
    case "lang_unsupported":
      // The SERVER declined the target language (language_unsupported) — D3: the client holds no
      // allowlist, so this is the only path to the langUnsupported note. The capture still saved.
      state = .langUnsupported
    default:
      result(FlutterError(code: "bad_args", message: "unknown explanation phase '\(phase)'", details: nil))
      return
    }
    DispatchQueue.main.async { [weak self] in self?.overlay?.applyExplanation(state) }
    result(nil)
  }

  /// Push an in-context preview state into the overlay's ready card (E2). Dart calls this after the
  /// metered preview fetch: `phase` = loading | ready (+ meaning) | quota | login | failed. The overlay
  /// drops it unless the same word's ready card is still shown (a no-op otherwise).
  private func handleUpdateContextPreview(
    _ call: FlutterMethodCall, _ result: @escaping FlutterResult
  ) {
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "bad_args", message: "updateContextPreview requires a map", details: nil))
      return
    }
    let phase = args["phase"] as? String ?? ""
    let slot: ContextPreviewSlot
    switch phase {
    case "loading":
      slot = .loading
    case "ready":
      guard let meaning = args["meaning"] as? String, !meaning.isEmpty else {
        result(
          FlutterError(
            code: "bad_args", message: "context-preview ready requires meaning", details: nil))
        return
      }
      slot = .ready(meaning: meaning)
    case "quota":
      slot = .quotaExhausted
    case "login":
      slot = .needsLogin
    case "failed":
      slot = .failed
    default:
      result(FlutterError(code: "bad_args", message: "unknown context-preview phase '\(phase)'", details: nil))
      return
    }
    DispatchQueue.main.async { [weak self] in self?.overlay?.applyContextPreview(slot) }
    result(nil)
  }

  /// Lazily builds the overlay controller and wires its Save/dismiss closures.
  private func ensureOverlay() -> CaptureOverlayController {
    if let overlay { return overlay }
    let controller = CaptureOverlayController()
    controller.onSave = { [weak self] request, completion in
      self?.overlaySave(request, completion: completion)
    }
    // `onDismiss` fires on Esc AND on the post-save auto-dismiss; the pending flag distinguishes them
    // so only a genuine Esc-without-save counts as an abandon (the lookup→save denominator).
    controller.onDismiss = { [weak self] in
      self?.emitLifecycleAbandonedIfPending()
    }
    // The overlay needs a fresh free-explanation when the user switches `Learning ▾` to an allowlisted
    // target or hits Retry. The fetch lives in Dart (the API client), so round-trip the request; the
    // result returns via `updateExplanation` → `applyExplanation`.
    controller.onRequestExplanation = { [weak self] unit, targetLanguage, explanationLanguage in
      self?.methodChannel?.invokeMethod(
        "onOverlayExplainRequest",
        arguments: [
          "unit": unit, "targetLanguage": targetLanguage, "explanationLanguage": explanationLanguage,
        ])
    }
    // The opt-in "Explain in this sentence" button (E2): round-trip to Dart, which runs the metered
    // `POST /explain/context/preview` and pushes the result back via `updateContextPreview`. The
    // sentence rides along so the gloss is generated against exactly what a later Save would persist.
    // The request also carries the two axes the backend prompt can use, both computed HERE on the
    // CURRENT (possibly user-edited) text — the same resolvers the Save path stamps onto the journal:
    //  • span: the unit's UTF-16 [start,end) when it occurs exactly once (UnitSpanResolver — nil on a
    //    repeat/absence, so the backend never marks a guessed occurrence);
    //  • contextLanguage: only when the text's script makes its language certain (nil otherwise — the
    //    backend NEVER defaults it to the target; a zh unit in an English article is the normal mix).
    controller.onRequestContextPreview = {
      [weak self] unit, contextText, targetLanguage, explanationLanguage in
      var arguments: [String: Any] = [
        "unit": unit, "contextText": contextText, "targetLanguage": targetLanguage,
        "explanationLanguage": explanationLanguage,
      ]
      // The axes rules + key spellings live in the logic package (ContextRequestAxesTests pins
      // them against the Dart fromMap keys) — this glue only merges the computed fields in.
      for (key, value) in ContextRequestAxes.previewPayloadFields(unit: unit, contextText: contextText) {
        arguments[key] = value
      }
      self?.methodChannel?.invokeMethod("onOverlayContextPreviewRequest", arguments: arguments)
    }
    // "Sign in" on the signed-out in-context preview prompt (`.needsLogin`): reuse the same
    // `capecho.showSurface` path the menu-bar items use — AppDelegate foregrounds the window and the
    // relay observer routes Flutter to the Settings surface. The `signIn` variant lands it already
    // scrolled to the (signed-out) Account section, whose SignInPanel signs in in place. No new channel
    // needed; the overlay already dismissed itself.
    controller.onRequestSignIn = { Self.postShowSurface("signIn") }
    overlay = controller
    return controller
  }

  /// The overlay's Save: validate + durably append (native), then tell Dart to
  /// drain. `contextLanguage` is stamped ONLY when the context's script makes its
  /// language certain (nil otherwise — never defaulted to the target: the unit's
  /// language and the sentence's genuinely diverge, e.g. a zh unit captured inside
  /// an English article).
  private func overlaySave(
    _ request: OverlaySaveRequest, completion: @escaping (Bool, String?) -> Void
  ) {
    // Persist the captured span (#3): the UTF-16 [start,end) of the unit within
    // the (possibly user-edited) context, so word_contexts records where the
    // unit sits in its sentence — the schema/journal/claim payload carry it, and
    // downstream surfaces highlight the unit in context without re-searching.
    let span = UnitSpanResolver.span(unit: request.unit, in: request.context)
    switch appendValidated(
      surfaceUnit: request.unit,
      targetLanguage: request.targetLanguage,
      contextText: request.context,
      contextLanguage: ContextRequestAxes.contextLanguage(of: request.context),
      spanStart: span?.start,
      spanEnd: span?.end,
      source: request.source,
      // Capture-time provenance + detected language, carried verbatim from the capture (NOT
      // user-editable) — persisted so the stored card records where the word was met.
      sourceApp: request.sourceApp,
      sourceTitle: request.sourceTitle,
      detectedLanguage: request.detectedLanguage,
      detectedLanguageConfidence: request.detectedLanguageConfidence,
      capturedAt: nil)
    {
    case .success(let receipt):
      // t2 (monotonic): emit the `completed` metric (timings + hasContext + langOverride) BEFORE the
      // drain signal. Metrics are best-effort and must never gate the durable-save path.
      emitLifecycleCompleted(receipt: receipt, request: request)
      // Tell Dart a durable record exists so it drains into the local store.
      methodChannel?.invokeMethod("onCaptureSaved", arguments: receipt)
      completion(true, nil)
    case .failure(let error):
      completion(false, error.message)
    }
  }

  // MARK: - §14 capture lifecycle metrics (CEO-10)

  /// Clamp a monotonic nanos delta to whole ms in [0, 3_600_000]. The metric contract bounds a
  /// duration at one hour (a longer span is junk — a window left open); clamping keeps the event
  /// valid rather than getting the whole batch rejected by the server validator.
  private static func msBetween(_ startNanos: UInt64, _ endNanos: UInt64) -> Int {
    let delta = endNanos >= startNanos ? endNanos - startNanos : 0
    return min(max(Int(delta / 1_000_000), 0), 3_600_000)
  }

  /// Send one lifecycle metric to Dart (the MetricsRecorder builds the metric_event). Callers are
  /// already on the main thread (the channel requires it). Best-effort: a missing engine is a no-op.
  private func emitLifecycle(_ payload: [String: Any]) {
    methodChannel?.invokeMethod("onCaptureLifecycle", arguments: payload)
  }

  private func emitLifecyclePresented() {
    guard let t0 = captureStartedAtNanos, let t1 = overlayPresentedAtNanos else { return }
    emitLifecycle([
      "phase": "presented",
      "selToPanelMs": Self.msBetween(t0, t1),
      "source": presentedSource ?? "ocr",
    ])
  }

  /// Esc-without-save on a real-unit overlay = an abandoned lookup (the lookup→save denominator).
  /// No-op when the dismiss followed a save (the flag was already cleared).
  private func emitLifecycleAbandonedIfPending() {
    guard awaitingCaptureOutcome else { return }
    awaitingCaptureOutcome = false
    guard let t0 = captureStartedAtNanos, let t1 = overlayPresentedAtNanos else { return }
    emitLifecycle(["phase": "abandoned", "selToPanelMs": Self.msBetween(t0, t1)])
  }

  /// A durable save: the full t0→t1→t2 split plus hasContext (a real, non-echo sentence) and
  /// langOverride (the user changed the shown target). clientRowId ties it to the unit for
  /// chain-completeness; without it the contract is unsatisfiable, so skip rather than emit junk.
  private func emitLifecycleCompleted(receipt: [String: Any], request: OverlaySaveRequest) {
    awaitingCaptureOutcome = false
    guard let crid = receipt["clientRowId"] as? String,
      let t0 = captureStartedAtNanos, let t1 = overlayPresentedAtNanos
    else { return }
    let t2 = DispatchTime.now().uptimeNanoseconds
    let unit = request.unit.trimmingCharacters(in: .whitespacesAndNewlines)
    let ctx = (request.context ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    emitLifecycle([
      "phase": "completed",
      "clientRowId": crid,
      "selToPanelMs": Self.msBetween(t0, t1),
      "panelToSaveMs": Self.msBetween(t1, t2),
      "totalMs": Self.msBetween(t0, t2),
      "source": request.source,
      // A "real" context: non-empty after trim AND not just the unit echoed back.
      "hasContext": !ctx.isEmpty && ctx != unit,
      "langOverride": request.targetLanguage != (presentedDefaultLanguage ?? request.targetLanguage),
    ])
  }

  /// Runs one capture and emits a snapshot dictionary on the event channel for
  /// the shared Dart cascade (US-4.1). The cascade — not this method — decides
  /// OCR-vs-clipboard, so an OCR failure is NOT a stream error: it is
  /// normalized to an empty-lines snapshot so Dart can fall back to the
  /// clipboard or present the editable empty overlay. When Screen Recording is off, OCR is
  /// skipped entirely (the SR-off direct-clipboard mode). Either way the current
  /// clipboard candidate + the `screenRecordingEnabled` flag are attached, and
  /// the emission is marshalled to the main thread (clipboard reads + Flutter
  /// channel calls must originate there).
  private func performCapture() {
    // A new capture supersedes any overlay still up: if the prior capture's outcome is still pending
    // (the user hit ⌥E again without saving/dismissing), count it ABANDONED before we overwrite the
    // single-slot timing state — otherwise its `presented` would never resolve and the lookup→save
    // denominator would skew (review P1). Uses the PRIOR t0/t1, which are still set here.
    emitLifecycleAbandonedIfPending()
    // t0 (monotonic): the hotkey / trigger instant. Reset per-capture timing state.
    captureStartedAtNanos = DispatchTime.now().uptimeNanoseconds
    overlayPresentedAtNanos = nil
    awaitingCaptureOutcome = false
    captureSeq &+= 1
    let seq = captureSeq  // this capture's id; a newer ⌥E bumps captureSeq and supersedes it
    let hasScreenRecording = engine.hasScreenRecordingPermission()
    Task { [weak self] in
      guard let self = self else { return }
      var snapshot: [String: Any] =
        hasScreenRecording
        ? await self.engine.capture(
          onScreenshotSecured: {
            // The screenshot is secured → show the loader over the (slow) OCR pass. The
            // engine fires this off-main, so hop to main; drop it if a newer ⌥E already
            // superseded this capture (don't re-show the loader over a newer overlay).
            DispatchQueue.main.async { [weak self] in
              guard let self = self, seq == self.captureSeq else { return }
              self.loading.present()
            }
          })
        : [:]

      // Normalize a failed/skipped OCR to an empty-lines snapshot so the
      // cascade reaches the clipboard / empty-capture path instead of erroring.
      if snapshot["lines"] == nil || snapshot["error"] != nil {
        let ocrError = snapshot["error"] as? String
        snapshot = [
          "lines": [[String: Any]](),
          "cursor": ["x": 0.5, "y": 0.5],
          "screenName": "",
          "recognitionLanguages": [String](),
        ]
        if let ocrError = ocrError { snapshot["ocrError"] = ocrError }  // diagnostic only
      }
      snapshot["screenRecordingEnabled"] = hasScreenRecording

      DispatchQueue.main.async { [weak self] in
        guard let self = self, let sink = self.eventSink else { return }
        // A newer ⌥E superseded this capture while its OCR was running → drop this stale snapshot so it
        // can't paint over the newer capture's overlay (rapid ⌥E / key-repeat — capture P1).
        guard seq == self.captureSeq else { return }
        // Read clipboard CONTENTS here only (main thread), at capture time. SR-off direct-clipboard mode
        // gets a GENEROUS freshness window (the clipboard is its only input — a deliberate copy→⌥E may
        // take a few seconds); SR-on keeps the tight default (there the clipboard only OVERRIDES borderline
        // OCR, so a stale one must not hijack it). The cascade hard-requires `fresh` in BOTH modes (D4), so
        // this window is what lets a real SR-off copy→capture still read as fresh.
        let candidate = self.pasteboard.currentCandidate(
          freshnessWindow: hasScreenRecording ? nil : Self.srOffClipboardFreshnessWindow)
        if let text = candidate.text, !text.isEmpty {
          snapshot["clipboard"] = ["text": text, "fresh": candidate.fresh]
        }
        sink(snapshot)
      }
    }
  }

  /// Opens System Settings → Privacy & Security → Screen Recording (the
  /// re-enable path from onboarding's permission-denied / clipboard-mode branch,
  /// US-ON.2). Runs on the platform thread (main).
  private func openScreenRecordingSettings() {
    // The deep anchor (`Privacy_ScreenCapture`) has drifted across macOS
    // versions; fall back to the bare Privacy & Security pane if it fails to
    // open, rather than silently doing nothing (CR #7).
    let deepLink =
      "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    let fallback = "x-apple.systempreferences:com.apple.preference.security"
    if let url = URL(string: deepLink), NSWorkspace.shared.open(url) {
      return
    }
    if let url = URL(string: fallback) {
      NSWorkspace.shared.open(url)
    }
  }

  /// Save an exported file (CSV / Anki `.apkg`) to a user-chosen location via an `NSSavePanel`, then
  /// reveal it in Finder. This is the Word Book "Export" download path — it replaces the old
  /// copy-to-clipboard export. Resolves to the saved file path, or `nil` when the user cancels (the
  /// Flutter side treats `nil` as a calm no-op, not an error). Shown as a sheet on the front window (the
  /// export dialog's) when one exists, else a modeless panel; the completion handler runs on the main
  /// thread, so there is no nested run-loop blocking the method-channel reply.
  private func handleSaveExportFile(
    _ call: FlutterMethodCall, _ result: @escaping FlutterResult
  ) {
    guard let args = call.arguments as? [String: Any],
      let suggestedName = args["suggestedName"] as? String,
      let typed = args["bytes"] as? FlutterStandardTypedData
    else {
      result(
        FlutterError(code: "bad_args", message: "saveExportFile needs suggestedName + bytes", details: nil))
      return
    }
    let data = typed.data

    let panel = NSSavePanel()
    panel.nameFieldStringValue = suggestedName
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    // Constrain to the file's type when the OS knows it (e.g. .csv → comma-separated-values); an
    // unknown extension like .apkg leaves the panel unconstrained so the name still saves verbatim.
    let ext = (suggestedName as NSString).pathExtension
    if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
      panel.allowedContentTypes = [type]
    }

    let completion: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let url = panel.url else {
        result(nil)  // cancelled — not an error
        return
      }
      do {
        try data.write(to: url, options: .atomic)
        NSWorkspace.shared.activateFileViewerSelecting([url])  // "Show in Finder"
        result(url.path)
      } catch {
        result(FlutterError(code: "save_failed", message: error.localizedDescription, details: nil))
      }
    }

    NSApp.activate(ignoringOtherApps: true)
    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
      panel.beginSheetModal(for: window, completionHandler: completion)
    } else {
      panel.begin(completionHandler: completion)
    }
  }

  // MARK: FlutterStreamHandler

  public func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
