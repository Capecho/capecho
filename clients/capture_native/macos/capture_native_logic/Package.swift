// swift-tools-version: 5.9
// A Flutter-free home for the capture_native plugin's pure-logic helpers so
// they can be unit-tested with `swift test` on a plain Mac.
//
// Why this package exists (and is separate from ../capture_native):
//   The plugin's own Package.swift depends on `../FlutterFramework`, a package
//   Flutter only materializes inside its ephemeral build workspace — so
//   `swift test` there fails at dependency resolution, and the macOS
//   RunnerTests bundle is host-based (it would have to build + launch the
//   whole codesigned agent app). This package has ZERO dependencies, so
//   `swift test` resolves and runs instantly.
//
// Single source of truth: Sources/CaptureNativeLogic/*.swift are SYMLINKS to
// the plugin's real files under
//   ../capture_native/Sources/capture_native/Logic/
// The plugin compiles those same files into its `capture_native` module; this
// package compiles them into `CaptureNativeLogic` purely so the tests can
// `@testable import` them. Editing the logic updates both.

import PackageDescription

let package = Package(
    name: "capture_native_logic",
    platforms: [
        .macOS("14.0")
    ],
    targets: [
        .target(
            name: "CaptureNativeLogic"
        ),
        .testTarget(
            name: "CaptureNativeLogicTests",
            dependencies: ["CaptureNativeLogic"]
        ),
    ]
)
