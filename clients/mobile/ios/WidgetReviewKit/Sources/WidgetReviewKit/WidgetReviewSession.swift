//
//  WidgetReviewSession.swift
//  WidgetReviewKit
//
//  The widget's interaction state machine over a WidgetReviewSnapshot: where the cursor is + whether
//  the back is revealed, and the reveal/grade transitions the App Intents drive. PURE value logic
//  (Foundation-only) so the hot path is testable headlessly — the native App Intent reads the current
//  state from the App Group, applies `revealing`/`grading`, writes the next state back, and appends the
//  produced event to the App-Group queue. No FSRS is computed here; the widget only PRODUCES events.
//

import Foundation

// MARK: - Face

/// What the widget renders — the SwiftUI view switches on this. A trimmed mirror of the in-app review
/// phases (review_controller.dart) for a glanceable surface.
public enum WidgetFace: Equatable {
  case front(WidgetReviewCard)  // word + sentence shown (recognition); whole-card tap reveals the back
  case back(WidgetReviewCard)  // + meaning + grade buttons
  case depleted  // this batch graded — "open Capecho to continue"
  case allCaughtUp  // the snapshot carried no due or new cards
  case stale  // snapshot aged past its window — glance + "open to refresh"; offline grading disabled
}

// MARK: - Grade event

/// One rating event the widget produces, in the Dart `SyncEvent` wire shape (snake_case). The native
/// App Intent appends `jsonObject()` to the App-Group queue; the app drains it on foreground (WidgetBridge
/// → OfflineEventQueue → /sync). The eventId is DETERMINISTIC per `(snapshotId, cursor)`, so a double-tap
/// yields the SAME id → the server folds it idempotently (no double-count) — the widget's dedupe.
public struct WidgetGradeEvent: Equatable {
  public let wordId: String
  public let eventId: String
  public let rating: Int
  public let clientReviewTs: Int64
  public let source: String  // always "widget"

  /// The JSON object matching Dart `SyncEvent.toJson` (the keys `SyncEvent.fromJson` reads). This is the
  /// QUEUE half of the cross-language contract — pinned by `WidgetReviewSessionTests`.
  public func jsonObject() -> [String: Any] {
    [
      "word_id": wordId,
      "event_id": eventId,
      "rating": rating,
      "client_review_ts": clientReviewTs,
      "source": source,
    ]
  }
}

// MARK: - Session

/// The widget's runtime state over one snapshot. Immutable value type: each transition returns a new
/// session the caller persists to the App Group.
public struct WidgetReviewSession: Equatable {
  public let snapshot: WidgetReviewSnapshot
  public let cursor: Int
  public let revealed: Bool

  /// Start from [snapshot] at [cursor] (default: the snapshot's own cursor), clamped into range.
  public init(snapshot: WidgetReviewSnapshot, cursor: Int? = nil, revealed: Bool = false) {
    self.snapshot = snapshot
    let base = cursor ?? snapshot.cursor
    self.cursor = max(0, min(base, snapshot.cards.count))
    self.revealed = revealed
  }

  /// The card in focus, or nil once the cursor is past the end (this batch is depleted).
  public var currentCard: WidgetReviewCard? {
    cursor >= 0 && cursor < snapshot.cards.count ? snapshot.cards[cursor] : nil
  }

  /// The face to render at [now] (staleness compares now against the snapshot's freshness window).
  public func face(atMillis now: Int64) -> WidgetFace {
    if snapshot.cards.isEmpty { return .allCaughtUp }
    if snapshot.isStale(atMillis: now) { return .stale }
    guard let card = currentCard else { return .depleted }
    return revealed ? .back(card) : .front(card)
  }

  /// Reveal the back (optimistic — the App Intent returns this immediately, not waiting on a reload).
  /// A no-op when already revealed, depleted, or stale.
  public func revealing(atMillis now: Int64) -> WidgetReviewSession {
    guard !revealed, currentCard != nil, !snapshot.isStale(atMillis: now) else { return self }
    return WidgetReviewSession(snapshot: snapshot, cursor: cursor, revealed: true)
  }

  /// Grade the current card → the event to enqueue + the advanced session, or nil when grading isn't
  /// allowed (not revealed / depleted / stale — mirrors the in-app `!_showBack` guard). The eventId is
  /// deterministic per `(snapshotId, cursor)`, so grading the same position twice (a double-tap race)
  /// produces the SAME event id and the server dedupes it.
  public func grading(_ rating: Int, clientReviewTs: Int64, atMillis now: Int64)
    -> (event: WidgetGradeEvent, next: WidgetReviewSession)?
  {
    guard revealed, let card = currentCard, !snapshot.isStale(atMillis: now) else { return nil }
    let event = WidgetGradeEvent(
      wordId: card.wordId,
      eventId: "\(snapshot.snapshotId)#\(cursor)",
      rating: rating,
      clientReviewTs: clientReviewTs,
      source: "widget")
    let next = WidgetReviewSession(snapshot: snapshot, cursor: cursor + 1, revealed: false)
    return (event, next)
  }
}
