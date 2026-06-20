# capture_native

Capecho's **cross-platform native capture plugin**. It owns only the
*platform-inherent* work — global hotkey, screen capture, OCR, and
highlight-pixel selection detection — and emits a platform-neutral
`OcrSnapshot`. All reconstruction (word targeting, paragraph/sentence/context)
lives in the shared, pure-Dart [`capecho_capture_core`](../../shared/capture-core),
so it is identical on every client and the Windows port swaps **only** this
plugin's native side.

```
                     ┌─ macOS: Swift (this package, today) ─┐
hotkey ⌥E ──▶ native ┤  ScreenCaptureKit + Vision + pixels   ├──▶ OcrSnapshot ──▶ capecho_capture_core ──▶ CaptureResult
                     └─ Windows: C++ (later)                 ┘        (over the EventChannel)        (shared Dart)
```

## Dart API

```dart
final capture = CaptureNative();
capture.captures.listen((CaptureResult r) => ...); // reconstructed, one per capture
await capture.triggerCapture();                     // same path as the ⌥E hotkey
await capture.requestScreenRecordingPermission();
await capture.hasScreenRecordingPermission();
```

`CaptureResult` and the other core types are re-exported from `capecho_capture_core`.

## macOS implementation (Swift, SwiftPM)

`macos/capture_native/Sources/capture_native/`:

- `CaptureNativePlugin.swift` — thin Flutter glue: MethodChannel `capture_native`
  (trigger + permission) + EventChannel `capture_native/snapshots`, registers the
  ⌥E hotkey, forwards to `CaptureEngine`, emits each snapshot dict (errors →
  `FlutterError`). No reconstruction.
- `CaptureEngine.swift` — captures the display under the cursor (excluding our own
  windows) via `SCScreenshotManager`, OCRs with `VNRecognizeTextRequest`, maps the
  cursor into Vision-normalized space, and returns the `OcrSnapshot` dictionary.
- `SelectionHighlightDetector.swift` — sandbox-safe selection detection by
  highlight-background pixels (no Accessibility / AX).
- `HotKeyController.swift` — Carbon global hotkey, default ⌥E.

**Deployment floor macOS 14.0; sandbox-safe** (Screen Recording permission only,
no Accessibility). Built via Swift Package Manager (no CocoaPods).

The bridge contract (the `OcrSnapshot` dictionary shape + the bottom-left
normalized coordinate convention) is documented in `capecho_capture_core`.

The overlay's pure-logic helpers (CAP-2 trim/snap, the explanation slot state, the
captured-unit span) live in
`macos/capture_native/Sources/capture_native/Logic/` — Foundation-only, no
AppKit/Flutter — so the AppKit-facing overlay maps onto them at the call site. The
client holds **no** target allowlist: every capture requests `/explain`, and the
server's `language_unsupported` status is what drives the overlay's unsupported state.

## Tests

- **Dart side** (mocked channels, runs in CI on Linux): `flutter test` from this
  package. See `test/`.
- **Swift pure logic** (runs locally on a Mac — CI is deliberately Linux-only):

  ```bash
  cd macos/capture_native_logic && swift test
  ```

  A zero-dependency SPM package whose sources symlink the `Logic/` files, so the
  contracts are exercised without dragging in `FlutterFramework` (which only
  resolves inside Flutter's ephemeral build workspace). See
  `macos/capture_native_logic/README.md`.
