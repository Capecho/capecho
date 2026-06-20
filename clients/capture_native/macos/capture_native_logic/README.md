# capture_native_logic — Swift unit tests for the plugin's pure logic

A tiny, **dependency-free** Swift package that exists for one reason: to run
`swift test` against the `capture_native` plugin's pure-logic helpers on a plain
Mac, with no Flutter toolchain, no codesigning, and no app launch.

```bash
cd clients/capture_native/macos/capture_native_logic
swift test
```

## What it covers

The three helpers that are documented as "separated for testability" but had no
runnable Swift test target:

| Helper | Contract | Home file |
| --- | --- | --- |
| `CaptureSelectionPromotion.promote` / `.isSpaceDelimited` | CAP-2 trim/snap of a context selection into the unit (word vs character granularity; CJK vs space-delimited) | `Logic/CaptureSelectionPromotion.swift` |
| `ExplanationSlotState` (`langUnsupported` state) + `OverlayExplanation.from` / `abbreviatePos` | the overlay slot states (the client holds no target allowlist — `langUnsupported` is a state the server pushes via `language_unsupported`) and the senses→reading-block rendering | `Logic/ExplanationSlotState.swift` |
| `UnitSpanResolver.span` | UTF-16 `[start, end)` of the unit within the context, first case-insensitive match, `nil` when absent | `Logic/UnitSpanResolver.swift` |

(`Logic/` = `../capture_native/Sources/capture_native/Logic/`.)

## Why a separate package (and not `swift test` on the plugin, or RunnerTests)

- The plugin's own `Package.swift` depends on `../FlutterFramework`, which only
  exists inside Flutter's ephemeral build workspace — so a standalone
  `swift test` / `swift build` there fails at dependency resolution.
- `clients/macos/macos/RunnerTests` is a **host-based** unit-test bundle
  (`TEST_HOST` = `Capecho.app`): running it builds and launches the whole
  codesigned menu-bar agent, and reaching the plugin's `internal`/`private`
  symbols would depend on the SPM module being built with testability. Heavy and
  fragile for what is pure, side-effect-free logic.

This package sidesteps both: it has **zero dependencies**, so resolution and the
build are instant and deterministic.

## Single source of truth

`Sources/CaptureNativeLogic/*.swift` are **symlinks** to the plugin's real files
under `../capture_native/Sources/capture_native/Logic/`. The plugin compiles
those files into its `capture_native` module (Flutter's build picks them up
recursively); this package compiles the same files into a `CaptureNativeLogic`
module purely so the tests can `@testable import` them. **Edit the logic once;
both the plugin and these tests see the change.**

The helpers are deliberately Foundation-only (no AppKit, no FlutterMacOS) — the
AppKit-facing overlay maps `NSTextView.SelectionGranularity` onto
`CaptureSelectionPromotion.SelectionGranularity` at the call site.
