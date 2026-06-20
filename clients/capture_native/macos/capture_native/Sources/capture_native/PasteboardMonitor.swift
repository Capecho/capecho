//
//  PasteboardMonitor.swift
//  capture_native
//
//  Tracks clipboard "freshness" for the capture cascade (US-4.1, issue #12).
//
//  NSPasteboard exposes a monotonic `changeCount` but NO last-changed timestamp,
//  so freshness can only be known by observing changes over time. This monitor
//  polls `changeCount` ONLY — an integer; it never reads clipboard CONTENTS
//  while idle (a privacy invariant) — and timestamps each change. The actual
//  string is read once, on demand, at capture time via `currentCandidate()`.
//

import AppKit
import Foundation

final class PasteboardMonitor {
    private let pasteboard: NSPasteboard
    private let freshnessWindow: TimeInterval
    private let pollInterval: TimeInterval
    private var lastChangeCount: Int
    private var lastChangeAt: Date
    private var timer: Timer?

    /// - freshnessWindow: how recently the clipboard must have changed (before
    ///   the hotkey) to count as a deliberate copy-then-capture. 3s per spec.
    init(
        pasteboard: NSPasteboard = .general,
        freshnessWindow: TimeInterval = 3.0,
        pollInterval: TimeInterval = 0.4
    ) {
        self.pasteboard = pasteboard
        self.freshnessWindow = freshnessWindow
        self.pollInterval = pollInterval
        self.lastChangeCount = pasteboard.changeCount
        // Seed in the distant past so the clipboard that already existed at
        // launch is NOT treated as fresh until the user copies anew.
        self.lastChangeAt = .distantPast
    }

    /// Starts polling `changeCount` on the main run loop. Idempotent. Added in
    /// `.common` mode so it keeps firing during menu tracking / modal loops.
    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.observeChange()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Reads the current clipboard candidate — text + freshness. This is the
    /// ONLY place clipboard CONTENTS are read. Call on the main thread (it
    /// touches NSPasteboard). It also catches a change that landed since the
    /// last poll tick (a sub-poll-interval copy→capture), so an immediate
    /// copy-then-hotkey still reads as fresh.
    ///
    /// [freshnessWindow] overrides the instance default (3s) for THIS read: the SR-off direct-clipboard
    /// mode passes a more generous window (the clipboard is its only input — a deliberate copy→hotkey),
    /// while SR-on keeps the tight default (there the clipboard only OVERRIDES borderline OCR, so a stale
    /// one must not hijack it).
    func currentCandidate(freshnessWindow: TimeInterval? = nil) -> (text: String?, fresh: Bool) {
        // NSPasteboard + the change-tracking state are main-thread-only; assert
        // it so a future off-main caller fails loudly in debug instead of
        // racing silently (CR #6).
        dispatchPrecondition(condition: .onQueue(.main))
        observeChange()
        let window = freshnessWindow ?? self.freshnessWindow
        let fresh = Date().timeIntervalSince(lastChangeAt) <= window
        let text = pasteboard.string(forType: .string)
        return (text, fresh)
    }

    /// Reads `changeCount` (an Int, not contents) and timestamps a change — but
    /// only counts it toward text-freshness when the new pasteboard actually
    /// offers a string. An image/file copy bumps `changeCount` while leaving a
    /// stale text string behind; without this guard that stale text would read
    /// as "fresh" and could override usable OCR (CR #5). `types` is type
    /// metadata, not contents, so the privacy invariant holds.
    private func observeChange() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        if pasteboard.types?.contains(.string) == true {
            lastChangeAt = Date()
        }
    }
}
