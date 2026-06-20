//
//  WidgetReviewSnapshot.swift
//  WidgetReviewKit
//
//  The Swift mirror of the Dart `WidgetReviewSnapshot` wire contract
//  (shared/app-core/lib/src/review/widget_review_snapshot.dart). The Dart app builds a snapshot,
//  encodes it (toJson), and writes it into the App Group; the iOS widget decodes it HERE. The two
//  sides are pinned to one committed golden fixture
//  (shared/app-core/test/fixtures/widget_review_snapshot.golden.json) so they can't drift.
//
//  Foundation-only (no WidgetKit / SwiftUI) so the model layer is testable with `swift test`. The
//  widget NEVER computes FSRS — it renders these resolved cards and emits rating events; scheduling
//  stays server-authoritative.
//

import Foundation

// MARK: - Meaning status

/// Whether a card's back (meaning) is renderable. Mirrors the Dart `WidgetMeaningStatus`.
public enum WidgetMeaningStatus: String, Equatable {
  case ready
  case unsupported   // the target language is off the explanation allowlist
  case unavailable   // a fetch failure / no blob — the front is still reviewable

  /// Lenient decode: an unknown / absent wire value degrades to `.unavailable` (the safe "no meaning,
  /// still reviewable" state), so a future status string can't break an older widget — matching the
  /// Dart `WidgetMeaningStatus.fromWire`.
  public static func from(wire: String?) -> WidgetMeaningStatus {
    guard let wire, let status = WidgetMeaningStatus(rawValue: wire) else { return .unavailable }
    return status
  }
}

// MARK: - Target span

/// A half-open UTF-16 `[start, end)` highlight range within a card's context text. On the wire it is a
/// 2-element array `[start, end]` (or null). UTF-16 so Swift's `String.Index`/`NSRange` and Dart's
/// UTF-16 offsets agree. Mirrors the Dart `WidgetTargetSpan`.
public struct WidgetTargetSpan: Equatable {
  public let start: Int
  public let end: Int

  public init(start: Int, end: Int) {
    self.start = start
    self.end = end
  }

  /// Build from the wire `[start, end]` array, or nil if absent / malformed (wrong length / negative /
  /// inverted) — the widget then renders plain text. Mirrors the Dart `WidgetTargetSpan.fromBounds` /
  /// `fromJson`, so an invalid span resolves to nil on BOTH sides (no asymmetric mismatch).
  public static func from(array: [Int]?) -> WidgetTargetSpan? {
    guard let array, array.count == 2 else { return nil }
    let start = array[0], end = array[1]
    guard start >= 0, end >= start else { return nil }
    return WidgetTargetSpan(start: start, end: end)
  }

  /// The substring of [text] this span highlights, or nil if the span is out of range for [text]
  /// (defensive — a stale snapshot's span against a different string). Uses UTF-16 offsets.
  public func substring(of text: String) -> String? {
    let utf16 = text.utf16
    guard start <= end, end <= utf16.count,
          let from = utf16.index(utf16.startIndex, offsetBy: start, limitedBy: utf16.endIndex),
          let to = utf16.index(utf16.startIndex, offsetBy: end, limitedBy: utf16.endIndex),
          let sFrom = String.Index(from, within: text),
          let sTo = String.Index(to, within: text)
    else { return nil }
    return String(text[sFrom..<sTo])
  }
}

// MARK: - Card

/// One fully-resolved card the widget renders: the front (context sentence + the target span to
/// highlight — the word is SHOWN, recognition review, not a cloze blank) and the back ([meaning] +
/// [meaningStatus]). Mirrors the Dart `WidgetReviewCard`.
public struct WidgetReviewCard: Equatable, Decodable {
  public let wordId: String
  public let surfaceUnit: String
  public let targetLang: String
  public let dueAt: Int64           // glance count only — the widget never re-sorts/filters by it
  public let state: String          // "due" | "new" (both reviewable; renderer doesn't branch on it)
  public let contextText: String    // the most-recent sentence, or "" for a bare card
  public let targetSpan: WidgetTargetSpan?
  public let ipa: String?           // bare IPA (primary reading US, else UK), or nil when omitted
  public let meaning: String?       // per-POS senses, one line per part of speech, or nil when not `ready`
  public let meaningStatus: WidgetMeaningStatus
  public let contextMeaning: String?  // in-sentence "Explain here" gloss for the front sentence, or nil

  public init(
    wordId: String, surfaceUnit: String, targetLang: String, dueAt: Int64, state: String,
    contextText: String, targetSpan: WidgetTargetSpan?, ipa: String? = nil,
    meaning: String?, meaningStatus: WidgetMeaningStatus, contextMeaning: String? = nil
  ) {
    self.wordId = wordId
    self.surfaceUnit = surfaceUnit
    self.targetLang = targetLang
    self.dueAt = dueAt
    self.state = state
    self.contextText = contextText
    self.targetSpan = targetSpan
    self.ipa = ipa
    self.meaning = meaning
    self.meaningStatus = meaningStatus
    self.contextMeaning = contextMeaning
  }

  private enum CodingKeys: String, CodingKey {
    case wordId, surfaceUnit, targetLang, dueAt, state, contextText, targetSpan, ipa, meaning,
      meaningStatus, contextMeaning
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    wordId = try c.decode(String.self, forKey: .wordId)
    surfaceUnit = try c.decode(String.self, forKey: .surfaceUnit)
    targetLang = try c.decode(String.self, forKey: .targetLang)
    dueAt = try c.decode(Int64.self, forKey: .dueAt)
    state = try c.decodeIfPresent(String.self, forKey: .state) ?? "due"
    contextText = try c.decodeIfPresent(String.self, forKey: .contextText) ?? ""
    targetSpan = WidgetTargetSpan.from(array: try c.decodeIfPresent([Int].self, forKey: .targetSpan))
    ipa = try c.decodeIfPresent(String.self, forKey: .ipa)
    meaning = try c.decodeIfPresent(String.self, forKey: .meaning)
    meaningStatus = WidgetMeaningStatus.from(
      wire: try c.decodeIfPresent(String.self, forKey: .meaningStatus))
    contextMeaning = try c.decodeIfPresent(String.self, forKey: .contextMeaning)
  }
}

// MARK: - Snapshot

/// The pre-resolved review queue the Dart app hands the widget via the App Group. Mirrors the Dart
/// `WidgetReviewSnapshot`. The widget renders [cards] from [cursor] and emits rating events back
/// through the shared offline queue — it never fetches and never computes FSRS.
public struct WidgetReviewSnapshot: Equatable, Decodable {
  /// The newest INCOMPATIBLE wire version this build can read. The Swift decoder is the ENFORCING gate
  /// (the Dart producer is forward-lenient): a snapshot stamped newer than this is REJECTED rather than
  /// mis-rendered (see `init(from:)`).
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let snapshotId: String
  public let builtAt: Int64
  public let staleAfterMs: Int64
  public let cursor: Int
  public let cards: [WidgetReviewCard]

  public init(
    schemaVersion: Int = WidgetReviewSnapshot.currentSchemaVersion, snapshotId: String,
    builtAt: Int64, staleAfterMs: Int64, cursor: Int, cards: [WidgetReviewCard]
  ) {
    self.schemaVersion = schemaVersion
    self.snapshotId = snapshotId
    self.builtAt = builtAt
    self.staleAfterMs = staleAfterMs
    self.cursor = cursor
    self.cards = cards
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, snapshotId, builtAt, staleAfterMs, cursor, cards
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
      ?? WidgetReviewSnapshot.currentSchemaVersion
    // The latch: reject a snapshot written by a NEWER app than this widget can read, rather than
    // silently mis-render it (the Dart-side doc designates Swift as the enforcing gate).
    if version > WidgetReviewSnapshot.currentSchemaVersion {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription:
            "WidgetReviewSnapshot schemaVersion \(version) > supported \(WidgetReviewSnapshot.currentSchemaVersion)"
        ))
    }
    schemaVersion = version
    snapshotId = try c.decode(String.self, forKey: .snapshotId)
    builtAt = try c.decode(Int64.self, forKey: .builtAt)
    staleAfterMs = try c.decode(Int64.self, forKey: .staleAfterMs)
    cursor = try c.decodeIfPresent(Int.self, forKey: .cursor) ?? 0
    cards = try c.decodeIfPresent([WidgetReviewCard].self, forKey: .cards) ?? []
  }

  /// Whether the snapshot has aged past its freshness window (mirrors the Dart `isStaleAt`). Past it
  /// the widget shows a glance + "open to refresh" and refuses to grade offline.
  public func isStale(atMillis nowMs: Int64) -> Bool { nowMs - builtAt >= staleAfterMs }

  /// Decode from raw App Group bytes, returning nil on ANY failure (malformed JSON, a rejected
  /// schemaVersion, a missing required field) so the widget degrades to "open to refresh" instead of
  /// crashing the timeline.
  public static func decode(from data: Data) -> WidgetReviewSnapshot? {
    try? JSONDecoder().decode(WidgetReviewSnapshot.self, from: data)
  }
}
