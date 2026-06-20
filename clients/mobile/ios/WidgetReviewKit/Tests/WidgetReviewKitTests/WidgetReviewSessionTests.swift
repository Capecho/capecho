//
//  WidgetReviewSessionTests.swift
//  WidgetReviewKitTests
//
//  Pins the widget interaction state machine: reveal/grade/advance, the grade guard,
//  double-tap dedupe (deterministic eventId), the face states, and the grade-event wire format that the
//  app's WidgetBridge drains (the QUEUE half of the cross-language contract).
//

import XCTest

@testable import WidgetReviewKit

final class WidgetReviewSessionTests: XCTestCase {

  private func card(_ id: String) -> WidgetReviewCard {
    WidgetReviewCard(
      wordId: id, surfaceUnit: id, targetLang: "en", dueAt: 0, state: "due", contextText: "ctx",
      targetSpan: nil, meaning: "m", meaningStatus: .ready)
  }

  private func snapshot(
    _ ids: [String], id: String = "snap", builtAt: Int64 = 0, staleAfterMs: Int64 = 1000,
    cursor: Int = 0
  ) -> WidgetReviewSnapshot {
    WidgetReviewSnapshot(
      snapshotId: id, builtAt: builtAt, staleAfterMs: staleAfterMs, cursor: cursor,
      cards: ids.map(card))
  }

  // MARK: - reveal / grade flow

  func testRevealFlipsFrontToBack() {
    let s = WidgetReviewSession(snapshot: snapshot(["a"]))
    XCTAssertEqual(s.face(atMillis: 0), .front(card("a")))
    let revealed = s.revealing(atMillis: 0)
    XCTAssertTrue(revealed.revealed)
    XCTAssertEqual(revealed.face(atMillis: 0), .back(card("a")))
  }

  func testGradeBeforeRevealIsRejected() {
    let s = WidgetReviewSession(snapshot: snapshot(["a"]))  // front, not revealed
    XCTAssertNil(s.grading(3, clientReviewTs: 100, atMillis: 0))
  }

  func testGradeProducesEventAndAdvancesToTheNextFront() throws {
    let s = WidgetReviewSession(snapshot: snapshot(["a", "b"])).revealing(atMillis: 0)
    let out = try XCTUnwrap(s.grading(3, clientReviewTs: 100, atMillis: 0))
    XCTAssertEqual(out.event.wordId, "a")
    XCTAssertEqual(out.event.rating, 3)
    XCTAssertEqual(out.event.source, "widget")
    XCTAssertEqual(out.event.eventId, "snap#0")
    XCTAssertEqual(out.next.cursor, 1)
    XCTAssertFalse(out.next.revealed)
    XCTAssertEqual(out.next.face(atMillis: 0), .front(card("b")))
  }

  // MARK: - double-tap dedupe

  func testDoubleTapAtTheSameCursorYieldsTheSameEventId() {
    // Two grades against the SAME session (the race where both taps read cursor 0 before either write
    // lands) must carry the SAME deterministic eventId, so the server folds them idempotently.
    let s = WidgetReviewSession(snapshot: snapshot(["a", "b"])).revealing(atMillis: 0)
    let first = s.grading(3, clientReviewTs: 100, atMillis: 0)
    let second = s.grading(2, clientReviewTs: 200, atMillis: 0)
    XCTAssertEqual(first?.event.eventId, "snap#0")
    XCTAssertEqual(first?.event.eventId, second?.event.eventId)
  }

  func testDistinctCursorsYieldDistinctEventIds() throws {
    let s = WidgetReviewSession(snapshot: snapshot(["a", "b"])).revealing(atMillis: 0)
    let firstNext = try XCTUnwrap(s.grading(3, clientReviewTs: 100, atMillis: 0)).next.revealing(
      atMillis: 0)
    let secondEvent = try XCTUnwrap(firstNext.grading(3, clientReviewTs: 200, atMillis: 0)).event
    XCTAssertEqual(secondEvent.eventId, "snap#1")
  }

  // MARK: - faces

  func testDepletedOnceCursorPastTheEnd() {
    let s = WidgetReviewSession(snapshot: snapshot(["a"]), cursor: 1)
    XCTAssertNil(s.currentCard)
    XCTAssertEqual(s.face(atMillis: 0), .depleted)
  }

  func testAllCaughtUpWhenTheSnapshotHasNoCards() {
    XCTAssertEqual(WidgetReviewSession(snapshot: snapshot([])).face(atMillis: 0), .allCaughtUp)
  }

  func testNewStateCardIsReviewableAndGradableLikeAnyOther() throws {
    // The widget reviews new words too: a card whose state == "new" flows through the SAME front → reveal
    // → grade path (the renderer/state machine doesn't branch on `state`), so it isn't shown as empty.
    let newCard = WidgetReviewCard(
      wordId: "wN", surfaceUnit: "obscure", targetLang: "en", dueAt: 0, state: "new",
      contextText: "ctx", targetSpan: nil, meaning: "m", meaningStatus: .ready)
    let s = WidgetReviewSession(
      snapshot: WidgetReviewSnapshot(
        snapshotId: "snap", builtAt: 0, staleAfterMs: 1000, cursor: 0, cards: [newCard]))
    XCTAssertEqual(s.face(atMillis: 0), .front(newCard))
    let out = try XCTUnwrap(s.revealing(atMillis: 0).grading(3, clientReviewTs: 100, atMillis: 0))
    XCTAssertEqual(out.event.wordId, "wN")
    XCTAssertEqual(out.event.eventId, "snap#0")
  }

  func testStaleFaceDisablesRevealAndGrading() {
    // staleAfterMs 500, builtAt 0 → at now=500 the snapshot is stale.
    let revealed = WidgetReviewSession(snapshot: snapshot(["a"], staleAfterMs: 500)).revealing(
      atMillis: 0)
    XCTAssertEqual(revealed.face(atMillis: 500), .stale)
    XCTAssertNil(revealed.grading(3, clientReviewTs: 100, atMillis: 500))  // no offline grading when stale
    // Reveal is also a no-op once stale.
    let fresh = WidgetReviewSession(snapshot: snapshot(["a"], staleAfterMs: 500))
    XCTAssertFalse(fresh.revealing(atMillis: 500).revealed)
  }

  func testCursorClampsIntoRange() {
    XCTAssertEqual(WidgetReviewSession(snapshot: snapshot(["a", "b"]), cursor: 99).cursor, 2)
    XCTAssertEqual(WidgetReviewSession(snapshot: snapshot(["a"]), cursor: -5).cursor, 0)
  }

  // MARK: - grade event wire format (queue cross-language contract)

  func testGradeEventJsonMatchesTheSyncEventWire() throws {
    let s = WidgetReviewSession(snapshot: snapshot(["wA"])).revealing(atMillis: 0)
    let json = try XCTUnwrap(s.grading(2, clientReviewTs: 1234, atMillis: 0)).event.jsonObject()
    XCTAssertEqual(json["word_id"] as? String, "wA")
    XCTAssertEqual(json["event_id"] as? String, "snap#0")
    XCTAssertEqual(json["rating"] as? Int, 2)
    XCTAssertEqual(json["client_review_ts"] as? Int64, 1234)
    XCTAssertEqual(json["source"] as? String, "widget")
    // Exactly the keys Dart SyncEvent.fromJson reads — nothing more.
    XCTAssertEqual(Set(json.keys), ["word_id", "event_id", "rating", "client_review_ts", "source"])
  }

  /// A type-exact mirror of the grade-event wire (snake_case keys = the keys Dart `SyncEvent` uses).
  /// Decoded via `Codable` so the comparison is portable (no `Any`-bridging / `NSDictionary`) — the
  /// package then `swift test`s on a plain Linux CI runner.
  private struct GradeEventWire: Decodable, Equatable {
    let wordId: String
    let eventId: String
    let rating: Int
    let clientReviewTs: Int64
    let source: String
    enum CodingKeys: String, CodingKey {
      case wordId = "word_id"
      case eventId = "event_id"
      case rating
      case clientReviewTs = "client_review_ts"
      case source
    }
  }

  /// The grade event matches the SAME committed fixture the Dart `SyncEvent` contract test pins, so the
  /// QUEUE contract can't drift on either side.
  func testGradeEventMatchesTheCommittedGolden() throws {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }  // → repo root
    url.appendPathComponent("shared/app-core/test/fixtures/widget_grade_event.golden.json")
    let golden = try JSONDecoder().decode(GradeEventWire.self, from: try Data(contentsOf: url))
    let e = WidgetGradeEvent(
      wordId: "w-ledger", eventId: "snap-fixture-1#0", rating: 3,
      clientReviewTs: 1_733_616_000_000, source: "widget")
    XCTAssertEqual(
      golden,
      GradeEventWire(
        wordId: e.wordId, eventId: e.eventId, rating: e.rating, clientReviewTs: e.clientReviewTs,
        source: e.source))
  }

  func testGradingAtADepletedCursorReturnsNil() {
    // The guard holds even for an adversarial past-the-end / empty session built directly.
    XCTAssertNil(
      WidgetReviewSession(snapshot: snapshot(["a"]), cursor: 1, revealed: true)
        .grading(3, clientReviewTs: 0, atMillis: 0))
    XCTAssertNil(
      WidgetReviewSession(snapshot: snapshot([]), revealed: true)
        .grading(3, clientReviewTs: 0, atMillis: 0))
  }
}
