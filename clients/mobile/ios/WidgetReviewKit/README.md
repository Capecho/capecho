# Capecho iOS Review Widget — implementation guide

The fragmented-time **review widget**.
All the **logic** is built and unit-tested headlessly; this guide is the **on-device Xcode wiring** that
remains. Each step below is a thin shell over a proven type — you should not re-implement any logic.

## 0. What's already done (don't rebuild)

| Layer | Symbol | Verified |
|---|---|---|
| Swift snapshot decode | `WidgetReviewSnapshot.decode(from:)` (this package) | `swift test` |
| Swift interaction logic | `WidgetReviewSession` — `.face / .revealing / .grading`, `WidgetGradeEvent` | `swift test` |
| Dart bridge | `WidgetBridge` (`publish` / `onForeground`) + `WidgetHost` seam | app-core tests |
| Dart snapshot builder | `WidgetSnapshotBuilder` (DUE-only, shared resolve) | app-core tests |
| Dart deep link | `parseDeepLink(Uri)` → `DeepLinkTarget` | app-core tests |

**Two cross-language contracts are pinned** (CI-enforceable): the **snapshot** (Dart `toJson` ⇄ the Swift
decoder, both against `shared/app-core/test/fixtures/widget_review_snapshot.golden.json`) and the **queue**
(`WidgetGradeEvent.jsonObject()` emits exactly the snake_case keys Dart `SyncEvent.fromJson` reads).

FSRS stays **server-authoritative**: the widget only PRODUCES rating events; the app drains them through
the existing per-event-acked `OfflineEventQueue` → `/sync`. Nothing computes a schedule on-device.

---

## 1. App Group

Add the **App Group** capability `group.com.capecho.app` to **both** the `Runner` target and the new
widget-extension target. Everything crosses through `UserDefaults(suiteName: "group.com.capecho.app")`.

## 2. Add the widget extension target (Xcode)

1. **File → New → Target → Widget Extension**, name `CapechoReviewWidget`, **check "Include Live Activity"
   off** and **interactive/App-Intent support on**. Min deployment **iOS 17** (interactive widgets + App
   Intents).
2. Add `WidgetReviewKit` as a **local Swift package** to BOTH `Runner` and `CapechoReviewWidget`
   (File → Add Package Dependencies → Add Local → `clients/mobile/ios/WidgetReviewKit`). The extension uses
   it for the models + session; Runner uses it if you share any helper.
3. Give the extension the App Group entitlement (step 1).

## 3. App-Group keys — the storage contract

| Key | Writer | Reader | Value |
|---|---|---|---|
| `widget_review_snapshot` | Dart (`home_widget`) | Swift widget | the snapshot JSON (`WidgetReviewSnapshot.toJson`) |
| `widget_review_queue` | Swift App Intent (append) | Dart (foreground) | JSON **array** of grade events (`WidgetGradeEvent.jsonObject()`) |
| `widget_review_cursor` / `_revealed` / `_cursor_snapshot_id` | Swift App Intent | Swift widget | the per-snapshot cursor state (D6 scope) |

`home_widget`'s `saveWidgetData(key, value)` on iOS writes to `UserDefaults(suiteName:)`, so the Dart and
Swift sides read/write the **same** keys.

## 4. Swift — TimelineProvider + views

The provider reads the snapshot, builds a `WidgetReviewSession`, and renders its `face(atMillis:)`:

```swift
import WidgetKit
import SwiftUI
import WidgetReviewKit

enum AppGroup {
  static let id = "group.com.capecho.app"
  static var defaults: UserDefaults { UserDefaults(suiteName: id)! }
  enum Key { static let snapshot = "widget_review_snapshot", queue = "widget_review_queue",
             cursor = "widget_review_cursor", revealed = "widget_review_revealed",
             cursorSnapshotId = "widget_review_cursor_snapshot_id" }
}

/// Rebuild the session the App Intents mutate, scoping the cursor to its snapshotId (D6): a rebuilt
/// snapshot (new id) starts at its own cursor, not the stale persisted one.
func loadSession() -> WidgetReviewSession? {
  let d = AppGroup.defaults
  guard let data = d.string(forKey: AppGroup.Key.snapshot)?.data(using: .utf8),
        let snap = WidgetReviewSnapshot.decode(from: data) else { return nil }
  if d.string(forKey: AppGroup.Key.cursorSnapshotId) == snap.snapshotId {
    return WidgetReviewSession(snapshot: snap,
                               cursor: d.integer(forKey: AppGroup.Key.cursor),
                               revealed: d.bool(forKey: AppGroup.Key.revealed))
  }
  return WidgetReviewSession(snapshot: snap)
}

func save(_ s: WidgetReviewSession) {
  let d = AppGroup.defaults
  d.set(s.cursor, forKey: AppGroup.Key.cursor)
  d.set(s.revealed, forKey: AppGroup.Key.revealed)
  d.set(s.snapshot.snapshotId, forKey: AppGroup.Key.cursorSnapshotId)
}
```

The view `switch`es on `WidgetFace`:

```swift
switch session.face(atMillis: Int64(Date().timeIntervalSince1970 * 1000)) {
case .front(let card):  // word SHOWN + highlighted span (recognition, NOT a blank) + "tap to reveal"
case .back(let card):   // + card.meaning (or the unsupported/unavailable copy) + grade buttons
case .depleted:         // "Reviewed this batch · open Capecho"
case .allCaughtUp:      // settled (faded) echo + "All caught up"
case .stale:            // glance + "open to refresh" — DO NOT show grade buttons
}
```

**Design (DESIGN.md §4.5):** Caffeine content (coffee ink / cream / espresso dark) inside a warm-tinted
Liquid Glass container — NOT the capture overlay's cold glass. Fraunces for the word, Charter for the
sentence/meaning, system sans for "N due"/buttons, JetBrains Mono for `№`/counts. Highlight the target
span via `card.targetSpan?.substring(of: card.contextText)`. Due-meter = a **static** three-ripple echo
mark. Grade buttons: small/medium = 2 (Forget = oxblood / Good = sage), large = 4 (+Hard ochre / Easy
slate), **labels only**, muted — never bright SaaS. On grade, a 6px ink-dot (not a checkmark). Consume the
generated Swift design tokens; don't hard-code colors.

## 5. Swift — the App Intents (the hot path)

Reveal and grade go through `WidgetReviewSession`; the intent returns optimistic state and reloads.

```swift
import AppIntents
import WidgetKit
import WidgetReviewKit

struct RevealIntent: AppIntent {
  static var title: LocalizedStringResource = "Reveal meaning"
  func perform() async throws -> some IntentResult {
    if let s = loadSession() { save(s.revealing(atMillis: nowMs())) }
    WidgetCenter.shared.reloadAllTimelines()
    return .result()
  }
}

struct GradeIntent: AppIntent {
  static var title: LocalizedStringResource = "Grade card"
  @Parameter(title: "Rating") var rating: Int   // 1=Forget 2=Hard 3=Good 4=Easy
  func perform() async throws -> some IntentResult {
    if let s = loadSession(), let out = s.grading(rating, clientReviewTs: nowMs(), atMillis: nowMs()) {
      appendToQueue(out.event)        // append out.event.jsonObject() to the widget_review_queue array
      save(out.next)
    }
    WidgetCenter.shared.reloadAllTimelines()
    return .result()
  }
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

/// Append one event to the App-Group queue array (read-modify-write; the app drains it on foreground).
func appendToQueue(_ e: WidgetGradeEvent) {
  let d = AppGroup.defaults
  var arr = (try? JSONSerialization.jsonObject(
    with: (d.string(forKey: AppGroup.Key.queue) ?? "[]").data(using: .utf8)!)) as? [[String: Any]] ?? []
  arr.append(e.jsonObject())
  if let data = try? JSONSerialization.data(withJSONObject: arr) {
    d.set(String(decoding: data, as: UTF8.self), forKey: AppGroup.Key.queue)
  }
}
```

`grading` returns nil (a no-op) before reveal or when stale — the guard is already enforced; the buttons
just won't produce an event. A **double-tap** of the same card yields the SAME `eventId`
(`"<snapshotId>#<cursor>"`), so the server folds it idempotently — no double-count.

## 6. Dart — the concrete `WidgetHost` + wiring (clients/mobile)

1. `clients/mobile/pubspec.yaml`: add `home_widget` and `app_links` (both SPM-capable — keep the macOS
   client untouched; this is mobile only).
2. Implement `WidgetHost` over `home_widget`:

```dart
class HomeWidgetHost implements WidgetHost {
  static const _group = 'group.com.capecho.app';
  static const _snapshotKey = 'widget_review_snapshot';
  static const _queueKey = 'widget_review_queue';

  @override
  Future<void> publishSnapshot(String snapshotJson) async {
    await HomeWidget.setAppGroupId(_group);
    await HomeWidget.saveWidgetData<String>(_snapshotKey, snapshotJson);
    await HomeWidget.updateWidget(iOSName: 'CapechoReviewWidget');
  }

  @override
  Future<String?> readQueueJson() => HomeWidget.getWidgetData<String>(_queueKey);

  @override
  Future<void> writeQueueJson(String queueJson) =>
      HomeWidget.saveWidgetData<String>(_queueKey, queueJson);
}
```

3. Drive `WidgetBridge`:
   - after a sync / a finished review session / at reminder-schedule time → `bridge.publish()`;
   - on **app resume** (`WidgetsBindingObserver.didChangeAppLifecycleState == resumed`) → `bridge.onForeground()`
     (drains the widget's grades, then re-publishes). Surface `outcome.flush.needsReauth` to the re-auth steer.
4. Deep link: subscribe to `app_links`' URI stream → `parseDeepLink(uri)` → route. For a `ReviewDeepLink`,
   open Review (jump to `wordId` if set) and tag the session `source` so the in-app rating is attributed
   like the widget's own grades. Add to `ios/Runner/Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array><dict>
  <key>CFBundleURLSchemes</key><array><string>capecho</string></array>
</dict></array>
```

## 7. On-device verification checklist

- [ ] After an in-app review/sync, the widget shows a due word (the snapshot published).
- [ ] Tap reveals the meaning **instantly** (optimistic — not waiting on a reload).
- [ ] Grading advances to the next card; the ink-dot shows; `№`/count updates.
- [ ] Background the app, grade 2–3 cards in the widget, reopen → the grades sync (Word Book due-count drops); `/analytics` `review.bySource` shows `widget`.
- [ ] Double-tap a grade button fast → exactly one rep on that card (idempotent eventId).
- [ ] Force a stale snapshot (set `staleAfterMs` small, or wait) → "open to refresh", **no** grade buttons, grading does nothing.
- [ ] Unsupported-language card → the back shows the "no meaning for this language" copy but the front is still reviewable.
- [ ] Deep-link from the widget opens Review at the tapped word.
- [ ] Sign out → the widget's queued grades don't leak into a different account (the app clears on sign-out).

## Appendix — proven API quick reference

```
Swift (WidgetReviewKit):
  WidgetReviewSnapshot.decode(from: Data) -> WidgetReviewSnapshot?
  WidgetReviewSnapshot.isStale(atMillis:) ; .cards ; .cursor ; .snapshotId
  WidgetReviewSession(snapshot:cursor:revealed:)
    .face(atMillis:) -> WidgetFace          // front/back/depleted/allCaughtUp/stale
    .revealing(atMillis:) -> WidgetReviewSession
    .grading(_:clientReviewTs:atMillis:) -> (event: WidgetGradeEvent, next: WidgetReviewSession)?
  WidgetGradeEvent.jsonObject() -> [String: Any]   // SyncEvent wire (snake_case)
  WidgetTargetSpan.substring(of: String) -> String?

Dart (capecho_app_core):
  WidgetBridge(host: WidgetHost, builder: WidgetSnapshotBuilder)
    .publish({excludeWordIds}) ; .onForeground() -> WidgetFlushOutcome
  parseDeepLink(Uri) -> DeepLinkTarget?     // ReviewDeepLink / CaptureDeepLink
```
