//
//  CapechoReviewWidget.swift
//  CapechoReviewWidget
//
//  The fragmented-time review widget. ALL the logic (decode / faces / reveal / grade / dedupe) lives in
//  WidgetReviewKit and is unit-tested (`swift test`); this is the thin WidgetKit shell + the Caffeine
//  visual layer (DESIGN.md §4.5): warm canvas, coffee-brown serif word, Charter sentence, the static
//  echo due-meter, muted oxblood/sage grade buttons, espresso dark. @main is in
//  CapechoReviewWidgetBundle.swift. Reveal/grade App Intents are in ReviewWidgetIntents.swift.
//

import AppIntents
import SwiftUI
import UIKit
import WidgetKit
import WidgetReviewKit

// MARK: - App Group bridge (shared with ReviewWidgetIntents.swift)

enum AppGroup {
  static let id = "group.com.capecho.app"
  static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
  enum Key {
    static let snapshot = "widget_review_snapshot"
    static let queue = "widget_review_queue"
    static let cursor = "widget_review_cursor"
    static let revealed = "widget_review_revealed"
    static let cursorSnapshotId = "widget_review_cursor_snapshot_id"
  }
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

/// Rebuild the session the App Intents mutate, scoping the cursor to its snapshotId (D6).
func loadSession() -> WidgetReviewSession? {
  let d = AppGroup.defaults
  guard let data = d.string(forKey: AppGroup.Key.snapshot)?.data(using: .utf8),
    let snap = WidgetReviewSnapshot.decode(from: data)
  else { return nil }
  if d.string(forKey: AppGroup.Key.cursorSnapshotId) == snap.snapshotId {
    return WidgetReviewSession(
      snapshot: snap, cursor: d.integer(forKey: AppGroup.Key.cursor),
      revealed: d.bool(forKey: AppGroup.Key.revealed))
  }
  return WidgetReviewSession(snapshot: snap)
}

func saveSession(_ s: WidgetReviewSession) {
  let d = AppGroup.defaults
  d.set(s.cursor, forKey: AppGroup.Key.cursor)
  d.set(s.revealed, forKey: AppGroup.Key.revealed)
  d.set(s.snapshot.snapshotId, forKey: AppGroup.Key.cursorSnapshotId)
}

// MARK: - Caffeine palette (design/tokens.css --app-*) + type

extension Color {
  fileprivate init(_ light: UInt, _ dark: UInt) {
    self = Color(
      UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
  }
}
extension UIColor {
  fileprivate convenience init(rgb: UInt) {
    self.init(
      red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
      blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
  }
}

private enum Caffeine {
  static let canvas = Color(0xf6_f3ef, 0x22_1b17)
  static let ink = Color(0x2b_2320, 0xf0_e9e0)
  static let ink2 = Color(0x6b_5d54, 0xc3_b4a6)
  static let ink3 = Color(0xa2_958a, 0x8d_7e71)
  static let primary = Color(0x64_4a40, 0xe6_c49b)  // coffee → latte
  static let chip = Color(0xff_dfb5, 0x4a_3a2e)  // latte highlight
  static let oxblood = Color(0x8a_2a1e, 0xd9_8a72)  // Forget
  static let sage = Color(0x5a_6a48, 0xa9_bd86)  // Good
  static let ochre = Color(0xa8_741e, 0xc8_9a4e)  // Hard
  static let slate = Color(0x4a_5a6a, 0x8a_a0b4)  // Easy
}

/// The word: editorial serif (system "New York" stands in for Fraunces until the font is bundled).
private func wordFont(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }
/// The sentence + meaning: Charter is preinstalled on iOS, so it renders the brand body face directly.
private func bodyFont(_ size: CGFloat) -> Font { .custom("Charter", size: size) }
private func monoFont(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .monospaced) }

// MARK: - Echo mark (static three-ripple due meter — DESIGN.md signature motif)

/// The brand echo mark (the exact three-ripple SVG path, EchoMark.imageset, template-tinted) — static,
/// so it reads as the memory/due meter (DESIGN.md disambiguation: motion = "working", still = state).
private struct EchoMark: View {
  var color: Color
  var size: CGFloat = 18
  var body: some View {
    Image("EchoMark")
      .renderingMode(.template)
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
      .foregroundStyle(color)
  }
}

/// The echo mark + compact progress (e.g. "5/12" — words left / batch total), pinned to the top-RIGHT
/// corner of every review face (no catalog № — that's a Word Book concept, meaningless here). The mark
/// and the fraction are vertically CENTERED on each other, so they share one horizontal line; the cluster
/// as a whole baseline-aligns to the word + POS via its text (see HeaderRow).
private struct DueMeter: View {
  var trailing: String  // compact progress, e.g. "5/12"
  var body: some View {
    HStack(spacing: 5) {
      EchoMark(color: Caffeine.primary, size: 15)
      Text(trailing).font(monoFont(13)).foregroundStyle(Caffeine.ink3).lineLimit(1)
    }
  }
}

/// The header (logo + "N to review") is the ONLY app-entry tap target: a Link, so the card body is free
/// to flip (front) or grade (back) without opening the app. A bare meter when there's no destination.
private struct AppHeader: View {
  let due: String
  let url: URL?
  var body: some View {
    if let url = url {
      Link(destination: url) { DueMeter(trailing: due) }
    } else {
      DueMeter(trailing: due)
    }
  }
}

// MARK: - Faces

/// The sentence with the target word highlighted (coffee-brown on a latte chip) — recognition review,
/// the word is SHOWN. Defensive: a missing/out-of-range span just renders plain.
private func highlighted(_ card: WidgetReviewCard) -> AttributedString {
  var attr = AttributedString(card.contextText)
  guard let span = card.targetSpan,
    let lo = AttributedString.Index(
      card.contextText.utf16.index(
        card.contextText.utf16.startIndex, offsetBy: span.start,
        limitedBy: card.contextText.utf16.endIndex) ?? card.contextText.utf16.endIndex,
      within: attr),
    let hi = AttributedString.Index(
      card.contextText.utf16.index(
        card.contextText.utf16.startIndex, offsetBy: span.end,
        limitedBy: card.contextText.utf16.endIndex) ?? card.contextText.utf16.endIndex,
      within: attr), lo < hi
  else { return attr }
  attr[lo..<hi].foregroundColor = Caffeine.primary
  attr[lo..<hi].backgroundColor = Caffeine.chip
  return attr
}

/// The fixed recognition head: the word (coffee-brown serif, ONE fixed size on every face/size) + its
/// POS inline on the left, the "N due" meter pinned to the top-right corner. The reading is NOT here —
/// it lives on its own line beneath (`ReadingLine`), so a long unit AND a long reading each get a full
/// row. The due meter is a `Link` (opens the app); it sits as a SIBLING of the card's reveal/grade
/// controls, never nested inside them — WidgetKit forbids nesting interactive elements.
private struct HeaderRow: View {
  let unit: String
  let due: String
  let appURL: URL?
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Text(unit).font(wordFont(24)).foregroundStyle(Caffeine.primary)
        .lineLimit(1).layoutPriority(1)  // the word stays whole (POS now sits on each meaning line)
      Spacer(minLength: 8)
      // The meter exposes its OWN text baseline, so it lands on the word's baseline — same line.
      AppHeader(due: due, url: appURL)
    }
  }
}

/// The reading (IPA), mono ink-3, on its own line beneath the header. Renders nothing when absent.
/// The negative top inset pulls it UP toward the word (the row spacing alone left too big a gap) — and
/// only when a reading is present, so a card without one keeps the full gap down to the context/meaning.
private struct ReadingLine: View {
  let card: WidgetReviewCard
  var body: some View {
    if let ipa = card.ipa, !ipa.isEmpty {
      Text("/\(ipa)/").font(monoFont(12)).foregroundStyle(Caffeine.ink3).lineLimit(1)
        .padding(.top, -4)
    }
  }
}

private struct FrontView: View {
  let card: WidgetReviewCard
  let due: String
  let large: Bool
  let appURL: URL?
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Row 1: word + "N due" (corner). The due Link opens the app; it's a sibling of the reveal Button
      // below, so the two interactive elements never nest.
      HeaderRow(unit: card.surfaceUnit, due: due, appURL: appURL)
      // Tapping the reading + context flips the card to the answer (the whole region IS the reveal
      // target — no "tap to reveal" affordance needed).
      Button(intent: RevealIntent()) {
        VStack(alignment: .leading, spacing: 8) {
          ReadingLine(card: card)  // reading on its OWN line
          // The context FILLS the card down to the bottom — no fixed line cap; the maxHeight frame
          // bounds it, so it shows every line that fits and truncates the last with … on overflow.
          Text(highlighted(card)).font(bodyFont(large ? 16 : 15)).foregroundStyle(Caffeine.ink2)
            .lineLimit(nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }
}

private struct BackView: View {
  let card: WidgetReviewCard
  let due: String
  let fourGrades: Bool
  let appURL: URL?
  var body: some View {
    // On large, the answer face pairs the meaning with a SECONDARY block. Prefer the in-sentence
    // "Explain here" gloss (the in-context explanation — the user already saw the raw sentence on the
    // FRONT); fall back to the sentence when no gloss exists. On medium the meaning fills alone.
    let gloss = (card.contextMeaning ?? "").isEmpty ? nil : card.contextMeaning
    let hasSecondary = fourGrades && (gloss != nil || !card.contextText.isEmpty)
    VStack(alignment: .leading, spacing: 7) {
      // Row 1: word + "N due" (corner). The due Link opens the app; the grade buttons grade — siblings,
      // never nested. The word is the SAME fixed size as the front (24).
      HeaderRow(unit: card.surfaceUnit, due: due, appURL: appURL)
      ReadingLine(card: card)  // reading on its OWN line, same fixed position as the front
      // The MEANING (answer) and the secondary block share the space down to the grade buttons. No fixed
      // line caps: FairSplit shows both IN FULL when they fit, and when they overflow splits the height
      // evenly — except a block shorter than its half yields the surplus to the other, so the region is
      // always filled as completely as possible.
      Group {
        if hasSecondary {
          FairSplit(spacing: 6) {
            meaningText
            if gloss != nil { glossText } else { exampleText }
          }
        } else {
          meaningText
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      HStack(spacing: 9) {
        GradeButton("Forget", 1, Caffeine.oxblood)
        if fourGrades { GradeButton("Hard", 2, Caffeine.ochre) }
        GradeButton("Good", 3, Caffeine.sage)
        if fourGrades { GradeButton("Easy", 4, Caffeine.slate) }
      }
    }
  }

  /// The answer — primary: ink, regular Charter. Uncapped; FairSplit (or the maxHeight frame on medium)
  /// bounds it and truncates the last line with … on overflow.
  private var meaningText: some View {
    Text(meaning).font(bodyFont(fourGrades ? 16 : 15)).foregroundStyle(Caffeine.ink)
      .lineLimit(nil)
      .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  /// The example sentence — clearly SECONDARY: a latte left-bar + italic ink-3, so the two never read as
  /// the same thing. The bar overlays the TEXT, so it tracks the sentence's rendered height.
  private var exampleText: some View {
    Text(highlighted(card)).font(bodyFont(13)).italic().foregroundStyle(Caffeine.ink3)
      .lineLimit(nil)
      .padding(.leading, 11)
      .overlay(alignment: .leading) {
        RoundedRectangle(cornerRadius: 1.5).fill(Caffeine.chip).frame(width: 3)
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  /// The in-sentence "Explain here" gloss — SECONDARY like the example, but a primary-tinted bar + ink2,
  /// upright (it's an explanation, not a quote). Mirrors the in-app Review card's gloss callout.
  private var glossText: some View {
    Text(card.contextMeaning ?? "").font(bodyFont(13)).foregroundStyle(Caffeine.ink2)
      .lineLimit(nil)
      .padding(.leading, 11)
      .overlay(alignment: .leading) {
        RoundedRectangle(cornerRadius: 1.5).fill(Caffeine.primary).frame(width: 3)
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var meaning: String {
    switch card.meaningStatus {
    case .ready: return card.meaning ?? ""
    case .unsupported: return "No meaning for this language yet"
    case .unavailable: return "Meaning unavailable — still worth recalling"
    }
  }
}

/// Two stacked text blocks that SHARE a fixed height. If both fit at their natural heights, each gets
/// exactly what it needs (the leftover sits below). If together they overflow, the height splits evenly
/// — but a block shorter than its half hands the surplus to the other, so the space is filled as fully
/// as possible. The meaning + example on the answer face (DESIGN.md §4.5).
private struct FairSplit: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let w = proposal.width ?? 0
    if let h = proposal.height { return CGSize(width: w, height: h) }
    // Unbounded proposal: report the natural stacked height.
    let ideals = subviews.map { $0.sizeThatFits(.init(width: w, height: nil)).height }
    let gaps = CGFloat(max(0, subviews.count - 1)) * spacing
    return CGSize(width: w, height: ideals.reduce(0, +) + gaps)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let w = bounds.width
    guard subviews.count == 2 else {
      // Degenerate: stack at natural heights from the top.
      var y = bounds.minY
      for sv in subviews {
        let h = sv.sizeThatFits(.init(width: w, height: nil)).height
        sv.place(at: CGPoint(x: bounds.minX, y: y), proposal: .init(width: w, height: h))
        y += h + spacing
      }
      return
    }
    let usable = max(0, bounds.height - spacing)
    let i0 = subviews[0].sizeThatFits(.init(width: w, height: nil)).height
    let i1 = subviews[1].sizeThatFits(.init(width: w, height: nil)).height
    var h0 = i0  // the first block's allotment
    if i0 + i1 > usable {
      let half = usable / 2
      if i0 <= half {
        h0 = i0  // first block short → it keeps what it needs; the rest goes to the second
      } else if i1 <= half {
        h0 = usable - i1  // second block short → first takes everything the second doesn't need
      } else {
        h0 = half  // both want more than half → even split
      }
    }
    // Place the first block at its ACTUAL (whole-line) height so the second sits flush beneath it, then
    // let the second fill all remaining height to the bottom of the region (truncating with … if needed).
    let a0 = subviews[0].sizeThatFits(.init(width: w, height: h0)).height
    subviews[0].place(
      at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: .init(width: w, height: a0))
    let remaining = max(0, bounds.height - a0 - spacing)
    subviews[1].place(
      at: CGPoint(x: bounds.minX, y: bounds.minY + a0 + spacing),
      proposal: .init(width: w, height: remaining))
  }
}

/// A muted, outlined grade button — never bright SaaS (DESIGN.md). Labels only.
private struct GradeButton: View {
  let label: String
  let rating: Int
  let tint: Color
  init(_ label: String, _ rating: Int, _ tint: Color) {
    self.label = label
    self.rating = rating
    self.tint = tint
  }
  var body: some View {
    Button(intent: GradeIntent(rating: rating)) {
      Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
        .frame(maxWidth: .infinity).padding(.vertical, 9)
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(tint.opacity(0.45), lineWidth: 1.5))
    }
    .buttonStyle(.plain)
  }
}

/// Warm empty / depleted / stale faces — a settled (faded) echo + a warm line, never "No items found".
private struct MessageView: View {
  let title: String
  let subtitle: String
  var appURL: URL? = nil
  var body: some View {
    // A message face has no body actions, so the WHOLE card opens the app ("Open Capecho to continue").
    if let appURL = appURL {
      Link(destination: appURL) { label }
    } else {
      label
    }
  }
  @ViewBuilder private var label: some View {
    VStack(spacing: 9) {
      EchoMark(color: Caffeine.ink3).opacity(0.5).scaleEffect(1.5)
      Text(title).font(wordFont(19)).foregroundStyle(Caffeine.ink2)
      Text(subtitle).font(.system(size: 13)).foregroundStyle(Caffeine.ink3)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Timeline + entry view

struct ReviewEntry: TimelineEntry {
  let date: Date
  let session: WidgetReviewSession?
}

struct ReviewProvider: TimelineProvider {
  func placeholder(in context: Context) -> ReviewEntry { ReviewEntry(date: Date(), session: loadSession()) }
  func getSnapshot(in context: Context, completion: @escaping (ReviewEntry) -> Void) {
    completion(ReviewEntry(date: Date(), session: loadSession()))
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<ReviewEntry>) -> Void) {
    let entry = ReviewEntry(date: Date(), session: loadSession())
    let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
    completion(Timeline(entries: [entry], policy: .after(next)))
  }
}

struct ReviewWidgetEntryView: View {
  @Environment(\.widgetFamily) private var family
  var entry: ReviewEntry

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .containerBackground(Caffeine.canvas, for: .widget)
    // No whole-widget .widgetURL: the card BODY is reserved for the reveal/grade App Intents, so the
    // app opens only from the header (review faces) or the whole card (message faces) — both Links.
  }

  /// `capecho://review?word=<current>&src=widget` so the app opens at the SAME word the widget shows.
  /// Wired into the header on the review faces and the whole card on the message faces — never the body.
  private var appURL: URL? {
    var c = URLComponents()
    c.scheme = "capecho"
    c.host = "review"
    var items = [URLQueryItem(name: "src", value: "widget")]
    if let card = entry.session?.currentCard {
      items.append(URLQueryItem(name: "word", value: card.wordId))
    }
    c.queryItems = items
    return c.url
  }

  private var isLarge: Bool { family == .systemLarge }

  @ViewBuilder private var content: some View {
    if let session = entry.session {
      let due = dueCount(session)  // same "N due" burn-down on both sizes — one mental model
      switch session.face(atMillis: nowMs()) {
      case .front(let card): FrontView(card: card, due: due, large: isLarge, appURL: appURL)
      case .back(let card): BackView(card: card, due: due, fourGrades: isLarge, appURL: appURL)
      case .depleted:
        MessageView(title: "Reviewed this batch", subtitle: "Open Capecho to continue", appURL: appURL)
      case .allCaughtUp:
        MessageView(
          title: "All caught up",
          subtitle: "Nothing due right now. Your words are resting in memory.", appURL: appURL)
      case .stale:
        MessageView(title: "Open to refresh", subtitle: "Tap to load fresh words", appURL: appURL)
      }
    } else {
      MessageView(title: "Capecho", subtitle: "Open the app to start reviewing", appURL: appURL)
    }
  }

  // The glance burn-down as a compact fraction — words left / batch total, e.g. "5/12". The icon carries
  // the meaning; no "to review" words needed. The queue mixes due + new cards (so it's not strictly "due").
  private func dueCount(_ s: WidgetReviewSession) -> String {
    let total = s.snapshot.cards.count
    let remaining = max(0, total - s.cursor)
    return "\(remaining)/\(total)"
  }
}

// MARK: - Widget (StaticConfiguration; @main is in CapechoReviewWidgetBundle.swift)

struct CapechoReviewWidget: Widget {
  let kind = "CapechoReviewWidget"
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: ReviewProvider()) { entry in
      ReviewWidgetEntryView(entry: entry)
    }
    .configurationDisplayName("Review")
    .description("Review a due word in a tap.")
    .supportedFamilies([.systemMedium, .systemLarge])
  }
}
