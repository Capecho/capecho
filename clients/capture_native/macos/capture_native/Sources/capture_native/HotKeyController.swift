//
//  HotKeyController.swift
//  capture_native
//
//  Carbon global hotkeys. Registers SEVERAL global hotkeys (⌥E capture, ⌥R Review,
//  ⌥B Word Book) against ONE installed event handler, dispatched by EventHotKeyID.id.
//  A thin native trigger: the Flutter orchestrator owns presentation.
//

import Carbon
import Foundation

/// Carbon global-hotkey controller for an arbitrary set of keys. One process-wide
/// event handler is installed lazily; each `register` adds a hotkey keyed by `id`
/// and the handler dispatches the press to that id's callback.
///
/// Used only from the main thread (the plugin registers on the platform thread and
/// the Carbon callback explicitly hops to `@MainActor` before invoking the
/// callback), so it is intentionally NOT `@MainActor`-isolated — that lets the
/// nonisolated `FlutterPlugin.register` entry point construct and register it
/// without an isolation violation. The `handlers` map is populated once at startup
/// and only read thereafter, so there is no concurrent mutation.
final class HotKeyController {
    /// Whether at least one global hotkey is currently registered.
    private(set) var isRegistered = false

    /// id → callback. Read on the main actor from the Carbon handler.
    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?

    /// Registers one global hotkey: `keyCode` + `modifiers` (Carbon masks, e.g.
    /// `optionKey`), identified by `id` (unique per key, carried in the
    /// `EventHotKeyID`). `onPressed` fires on the main actor each time it's pressed.
    /// Re-registering the same `id` swaps the callback and replaces the OS
    /// binding if the keycode/modifiers changed. Returns whether the OS
    /// registration succeeded.
    ///
    /// MUST be called from the main actor — `handlers`/`hotKeyRefs` are not
    /// synchronized. The Flutter platform channel and the Carbon callback both
    /// resolve to the main actor, so registrations and reads share one queue.
    /// Safe to call at runtime (e.g. swapping a shortcut from Settings), not just
    /// at startup.
    @discardableResult
    func register(
        keyCode: UInt32, modifiers: UInt32, id: UInt32, onPressed: @escaping () -> Void
    ) -> Bool {
        // Install the shared handler BEFORE recording the callback, so a failed
        // install never leaves a phantom `handlers[id]` that can never fire.
        guard installHandlerIfNeeded() else {
            NSLog("Capecho: hotkey event-handler install failed; id=\(id) inactive")
            return false
        }
        unregister(id: id)
        handlers[id] = onPressed

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: HotKeyIdentity.signature, id: id)
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)

        if status == noErr, let ref {
            hotKeyRefs[id] = ref
            isRegistered = true
            return true
        }
        // OS registration failed → drop the callback so nothing thinks this key is live.
        handlers[id] = nil
        NSLog("Capecho: RegisterEventHotKey failed (status \(status)); id=\(id) inactive")
        return false
    }

    /// Unregisters one global hotkey while keeping the shared handler and other
    /// key ids alive.
    func unregister(id: UInt32) {
        if let ref = hotKeyRefs[id] {
            UnregisterEventHotKey(ref)
            hotKeyRefs[id] = nil
        }
        handlers[id] = nil
        isRegistered = !hotKeyRefs.isEmpty
    }

    /// Installs the single shared Carbon event handler on first use. Returns whether
    /// a handler is available (already-installed or freshly installed).
    private func installHandlerIfNeeded() -> Bool {
        if eventHandlerRef != nil { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
        return status == noErr
    }

    /// Dispatches a fired hotkey (by id) to its callback. Called on the main actor.
    func handle(id: UInt32) {
        handlers[id]?()
    }

    /// Tears down every registered hotkey + the shared handler.
    func unregister() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }

        handlers.removeAll()
        isRegistered = false
    }
}

// The Capecho four-char signature shared by every Capecho hotkey; kept nonisolated
// so the C event-handler callback can read it without crossing the main actor. The
// per-key identity is the `EventHotKeyID.id` passed to `register`.
private enum HotKeyIdentity {
    static let signature: OSType = fourCharacterCode("CPEC")  // Capecho
}

// Dispatches a fired hotkey by id. Returns noErr (handled) for a Capecho hotkey,
// and `eventNotHandledErr` for anything else so the event continues down the handler
// chain (defensive; only Capecho keys are registered against this target).
private let hotKeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return noErr }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    // Failure to read the id of a hotkey WE registered → consume it (returning
    // `eventNotHandledErr` would leak the keystroke to other handlers). A genuine
    // foreign signature → pass it down the chain.
    guard status == noErr else { return noErr }
    guard hotKeyID.signature == HotKeyIdentity.signature else {
        return OSStatus(eventNotHandledErr)
    }

    let controller = Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    Task { @MainActor in
        controller.handle(id: id)
    }
    return noErr
}

private func fourCharacterCode(_ string: String) -> OSType {
    precondition(string.utf8.count == 4)
    return string.utf8.reduce(0) { result, character in
        (result << 8) + OSType(character)
    }
}
