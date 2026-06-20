//
//  WidgetReviewSnapshotTests.swift
//  WidgetReviewKitTests
//
//  Pins the cross-language snapshot contract: the Swift decoder here reads the EXACT
//  committed golden fixture that the Dart encoder (WidgetReviewSnapshot.toJson) is pinned to
//  (shared/app-core/test/widget_review_snapshot_test.dart). If the Dart wire ever changes without the
//  Swift side following, this test goes red — the two sides can't silently drift.
//

import XCTest

@testable import WidgetReviewKit

final class WidgetReviewSnapshotTests: XCTestCase {

  /// Read the SAME committed golden JSON the Dart contract test pins — located relative to THIS source
  /// file (#filePath), so it works regardless of the test runner's working directory.
  private func goldenData() throws -> Data {
    // .../clients/mobile/ios/WidgetReviewKit/Tests/WidgetReviewKitTests/<thisFile>
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }  // → repo root
    url.appendPathComponent("shared/app-core/test/fixtures/widget_review_snapshot.golden.json")
    return try Data(contentsOf: url)
  }

  // MARK: - The golden contract

  func testDecodesTheCommittedGoldenFixture() throws {
    let snapshot = try XCTUnwrap(WidgetReviewSnapshot.decode(from: try goldenData()))

    XCTAssertEqual(snapshot.schemaVersion, 1)
    XCTAssertEqual(snapshot.snapshotId, "snap-fixture-1")
    XCTAssertEqual(snapshot.builtAt, 1_733_616_000_000)
    XCTAssertEqual(snapshot.staleAfterMs, 86_400_000)
    XCTAssertEqual(snapshot.cursor, 0)
    XCTAssertEqual(snapshot.cards.count, 3)

    // Card 0 — ready, with a CJK meaning + a UTF-16 highlight span.
    let ready = snapshot.cards[0]
    XCTAssertEqual(ready.wordId, "w-ledger")
    XCTAssertEqual(ready.surfaceUnit, "ledger")
    XCTAssertEqual(ready.targetLang, "en")
    XCTAssertEqual(ready.dueAt, 1_733_620_000_000)
    XCTAssertEqual(ready.state, "due")
    XCTAssertEqual(ready.contextText, "She kept a ledger of debts.")
    XCTAssertEqual(ready.targetSpan, WidgetTargetSpan(start: 11, end: 17))
    XCTAssertEqual(ready.ipa, "ˈlɛdʒər")
    XCTAssertEqual(ready.meaning, "账簿;分类账")
    XCTAssertEqual(ready.meaningStatus, .ready)
    XCTAssertEqual(ready.contextMeaning, "这里 ledger 指记账的账本;这句话说她把欠的债都记在账本里。")

    // Card 1 — unsupported target language, null meaning, CJK-prefixed context.
    let unsupported = snapshot.cards[1]
    XCTAssertEqual(unsupported.targetLang, "de")
    XCTAssertEqual(unsupported.meaningStatus, .unsupported)
    XCTAssertNil(unsupported.meaning)
    XCTAssertNil(unsupported.ipa)
    XCTAssertNil(unsupported.contextMeaning)
    XCTAssertEqual(unsupported.targetSpan, WidgetTargetSpan(start: 3, end: 12))

    // Card 2 — bare card: empty context, no span, unavailable.
    let bare = snapshot.cards[2]
    XCTAssertEqual(bare.contextText, "")
    XCTAssertNil(bare.targetSpan)
    XCTAssertNil(bare.meaning)
    XCTAssertEqual(bare.meaningStatus, .unavailable)
  }

  /// The span must select the right word using UTF-16 offsets on both sides (Dart asserts the same).
  func testTargetSpanHighlightsTheWordViaUtf16() throws {
    let snapshot = try XCTUnwrap(WidgetReviewSnapshot.decode(from: try goldenData()))
    XCTAssertEqual(snapshot.cards[0].targetSpan?.substring(of: snapshot.cards[0].contextText), "ledger")
    // "学习 framework 的用法": 学(0) 习(1) space(2) → "framework" is [3, 12) in UTF-16 units.
    XCTAssertEqual(snapshot.cards[1].targetSpan?.substring(of: snapshot.cards[1].contextText), "framework")
  }

  // MARK: - Defensive / forward-safe decoding (mirrors the Dart tests)

  func testRejectsAnIncompatibleFutureSchemaVersion() {
    let json = #"{"schemaVersion":99,"snapshotId":"s","builtAt":0,"staleAfterMs":1,"cursor":0,"cards":[]}"#
    // The Swift side is the enforcing gate → a newer-than-supported snapshot decodes to nil.
    XCTAssertNil(WidgetReviewSnapshot.decode(from: Data(json.utf8)))
  }

  func testUnknownMeaningStatusDegradesToUnavailable() {
    XCTAssertEqual(WidgetMeaningStatus.from(wire: "some-future-status"), .unavailable)
    XCTAssertEqual(WidgetMeaningStatus.from(wire: nil), .unavailable)
    XCTAssertEqual(WidgetMeaningStatus.from(wire: "ready"), .ready)
  }

  func testMalformedSpanResolvesToNil() {
    XCTAssertNil(WidgetTargetSpan.from(array: [5, 2]))   // inverted
    XCTAssertNil(WidgetTargetSpan.from(array: [3]))      // one-sided
    XCTAssertNil(WidgetTargetSpan.from(array: [-1, 4]))  // negative
    XCTAssertNil(WidgetTargetSpan.from(array: nil))
    XCTAssertEqual(WidgetTargetSpan.from(array: [11, 17]), WidgetTargetSpan(start: 11, end: 17))
  }

  func testStalenessWindow() {
    let snapshot = WidgetReviewSnapshot(
      snapshotId: "s", builtAt: 1000, staleAfterMs: 500, cursor: 0, cards: [])
    XCTAssertFalse(snapshot.isStale(atMillis: 1000 + 499))
    XCTAssertTrue(snapshot.isStale(atMillis: 1000 + 500))
  }

  func testMissingRequiredFieldDecodesToNil() {
    // No snapshotId → the whole decode fails → nil (widget falls back to "open to refresh").
    let json = #"{"builtAt":0,"staleAfterMs":1,"cursor":0,"cards":[]}"#
    XCTAssertNil(WidgetReviewSnapshot.decode(from: Data(json.utf8)))
  }
}
