// swift-tools-version: 5.9
// Flutter-free home for the iOS review widget's SHARED Swift models — the `Codable` types that
// decode the `WidgetReviewSnapshot` JSON the Dart app writes into the App Group.
//
// Why a standalone package: it has ZERO dependencies, so `swift test` resolves and runs instantly on
// a plain Mac (no Xcode, no codesigned app) — which lets the cross-language CONTRACT be pinned: the
// test decodes the SAME committed golden fixture
//   shared/app-core/test/fixtures/widget_review_snapshot.golden.json
// that the Dart encoder (WidgetReviewSnapshot.toJson) is pinned to, so the two sides can't drift.
//
// The widget extension target (added to Runner.xcodeproj in the on-device Xcode step) depends on this
// package for its model layer; the SwiftUI views + App Intents live in the extension itself.
import PackageDescription

let package = Package(
    name: "WidgetReviewKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "WidgetReviewKit", targets: ["WidgetReviewKit"])
    ],
    targets: [
        .target(name: "WidgetReviewKit"),
        .testTarget(
            name: "WidgetReviewKitTests",
            dependencies: ["WidgetReviewKit"]
        ),
    ]
)
