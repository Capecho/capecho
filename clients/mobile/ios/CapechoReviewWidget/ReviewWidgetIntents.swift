//
//  ReviewWidgetIntents.swift
//  CapechoReviewWidget
//
//  The widget's hot path: reveal + grade, driven through the proven WidgetReviewSession (the guard,
//  the cursor advance, and the deterministic dedupe id all live there). Each intent returns optimistic
//  state and reloads the timeline; a grade also appends its event to the App-Group queue, which the app
//  drains on foreground (WidgetBridge → OfflineEventQueue → /sync). FSRS stays server-authoritative.
//  NOT compiled in the authoring env — build on-device (iOS 17+ for interactive App Intents).
//

import AppIntents
import Foundation
import WidgetKit
import WidgetReviewKit

struct RevealIntent: AppIntent {
  static var title: LocalizedStringResource = "Reveal meaning"

  func perform() async throws -> some IntentResult {
    if let session = loadSession() {
      saveSession(session.revealing(atMillis: nowMs()))
    }
    WidgetCenter.shared.reloadAllTimelines()
    return .result()
  }
}

struct GradeIntent: AppIntent {
  static var title: LocalizedStringResource = "Grade card"

  @Parameter(title: "Rating") var rating: Int  // 1=Forget 2=Hard 3=Good 4=Easy

  init() {}
  init(rating: Int) { self.rating = rating }

  func perform() async throws -> some IntentResult {
    if let session = loadSession(),
      let outcome = session.grading(rating, clientReviewTs: nowMs(), atMillis: nowMs())
    {
      appendGrade(outcome.event)
      saveSession(outcome.next)
    }
    WidgetCenter.shared.reloadAllTimelines()
    return .result()
  }
}

/// Append one grade event to the App-Group queue array (read-modify-write). The Dart app reads this on
/// foreground via WidgetBridge and flushes it per-event; `WidgetGradeEvent.jsonObject()` is exactly the
/// shape Dart `SyncEvent.fromJson` expects (golden-fixture pinned in CI).
func appendGrade(_ event: WidgetGradeEvent) {
  let defaults = AppGroup.defaults
  let raw = defaults.string(forKey: AppGroup.Key.queue) ?? "[]"
  var array = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]] ?? []
  array.append(event.jsonObject())
  if let data = try? JSONSerialization.data(withJSONObject: array) {
    defaults.set(String(decoding: data, as: UTF8.self), forKey: AppGroup.Key.queue)
  }
}
