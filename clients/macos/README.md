# Capecho — macOS client

The macOS Flutter app: a **Flutter shell** for the windowed surfaces + the
**native Swift capture module** ([`capture_native`](../capture_native)) for the
hotkey-triggered OCR capture. Built with Swift Package Manager (no CocoaPods);
deployment floor **macOS 14.0**; sandboxed.

## Status

This is the **active client** and the distributed notarized beta. Built and shipping: first-run
onboarding, the ⌥E capture overlay (two-field model · select-in-context · inline edit · OCR→clipboard
cascade), durable save, Review (FSRS flashcards), Word Book (catalog + pushed detail), Settings, and
account + sync. **[`CHANGELOG.md`](../../CHANGELOG.md) is the canonical current state** (read the top
entry). The module-by-module running narrative is intentionally not duplicated here, so it can't go
stale.

It runs as an **`LSUIElement` agent app** — a menu-bar item (no Dock icon) whose warm-glass dropdown
opens the windowed surfaces; closing a window keeps the agent and the global hotkeys (**⌥E** capture ·
**⌥R** Review · **⌥B** Word Book) alive. A single headless `FlutterEngine` runs at launch, so Dart
owns the store + orchestration with no visible window; windows attach to it on demand.

## Architecture

```
clients/macos        this app (Flutter shell)
clients/capture_native   the native capture plugin (macOS Swift adapter; Windows later)
shared/capture-core      pure-Dart reconstruction core (reused by every client)
```

Capture splits along a Windows-ready seam: the native adapter does the
platform-inherent work (hotkey, ScreenCaptureKit capture, Vision OCR,
highlight-pixel detection) and emits a platform-neutral `OcrSnapshot`; the shared
Dart core reconstructs the `CaptureResult`.

## Build & run

```sh
cd clients/macos
flutter pub get
flutter run -d macos          # or: flutter build macos --debug
```

To point the app at a non-production backend, inject `CAPECHO_API_BASE` (no code change) before
launching.

On first capture, macOS prompts for **Screen Recording** permission; grant it in
System Settings → Privacy & Security → Screen Recording and relaunch. Capture is
triggered by **⌥E** (or the in-app button); the Mac's on-device text recognition
runs once at that instant and returns the recognized text.

## Distribution (release builds)

Two rails: a direct **notarized DMG + Sparkle auto-update** and the **Mac App Store**. The
signing / notarization / appcast pipeline depends on Apple Developer credentials and is maintained by
the project team, so it is not reproducible from a fork.

Versions derive from the canonical [`/VERSION`](../../VERSION). Sparkle (2.9.2) is a vendored, manually
linked + embedded framework — **direct build only**, gated by the `SPARKLE_ENABLED` switch so the Mac
App Store build stays Sparkle-free; **Check for Updates…** is in the menu-bar dropdown.
