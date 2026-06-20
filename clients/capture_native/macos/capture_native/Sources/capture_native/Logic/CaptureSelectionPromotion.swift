//
//  CaptureSelectionPromotion.swift
//  capture_native
//
//  CAP-2 trim/snap — pure logic, separated for testability. Extracted from
//  CaptureOverlay.swift so the contract can be exercised by a Flutter-free
//  Swift test target (../../capture_native_logic) without dragging in AppKit
//  or FlutterFramework. Foundation-only on purpose; the AppKit-facing overlay
//  maps NSTextView.SelectionGranularity onto SelectionGranularity at the call
//  site.
//

import Foundation

// MARK: - CAP-2 trim/snap (pure logic, separated for testability)

/// CAP-2: trim leading/trailing whitespace + punctuation from a span selected
/// inside the context; for space-delimited target languages, snap to nearest
/// word boundaries **only when the selection came from a word-granularity
/// gesture** (double-click or triple-click); a character-granularity drag is a
/// deliberate partial-word selection and is respected verbatim. CJK / no-space
/// scripts always take the trimmed span as is. A punctuation-only or empty
/// selection returns nil (no-op).
enum CaptureSelectionPromotion {
  /// Mirrors NSTextView.SelectionGranularity but lets the pure logic stay
  /// independent of AppKit for testing. Map AppKit's value at the call site.
  enum SelectionGranularity {
    /// A drag-selected character range — the user picked an exact span (e.g.
    /// `"un"` from `"unfair"`, or `"reading the"` from a longer phrase) and
    /// the snap is suppressed: we trust the user's pointer.
    case character
    /// A double-click word selection or triple-click line selection — the
    /// user gestured at a whole-word/line unit, so the snap stays on (and
    /// also corrects for slight off-by-one drags inside a word).
    case word
  }

  /// Whether the target language is space-delimited (en/es/fr/de/pt/it/…).
  /// CJK / no-space scripts (zh-*, ja-*, ko-*, th, my, km, lo) take the
  /// trimmed span as is. Conservative prefix list; expand as targets land.
  static func isSpaceDelimited(targetLanguage: String) -> Bool {
    let lower = targetLanguage.lowercased()
    let noSpacePrefixes = ["zh", "ja", "ko", "th", "my", "km", "lo"]
    for prefix in noSpacePrefixes {
      if lower == prefix || lower.hasPrefix(prefix + "-") {
        return false
      }
    }
    return true
  }

  /// Apply the CAP-2 rules to the selection at [selectionRange] inside
  /// [context]. The raw substring is trimmed first (leading/trailing
  /// whitespace + punctuation); if non-empty AND the target is space-
  /// delimited AND [granularity] is `.word`, the trimmed span is snapped to
  /// nearest word boundaries AROUND THE SELECTION POSITION (not the first
  /// `range(of:)` match — that would mis-target a duplicate token earlier in
  /// the context). For `.character` granularity the trimmed span is returned
  /// verbatim, so a user-drag selection like `"ifecycl"` or `"un"` becomes
  /// the unit as-is. Returns nil for a punctuation-only or empty selection.
  static func promote(
    rawSelection: String,
    in context: String,
    selectionRange: NSRange,
    targetLanguage: String,
    granularity: SelectionGranularity
  ) -> String? {
    let trimSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
    let trimmed = rawSelection.trimmingCharacters(in: trimSet)
    if trimmed.isEmpty {
      return nil
    }
    if !isSpaceDelimited(targetLanguage: targetLanguage) {
      return trimmed
    }
    // A deliberate character-drag selection is respected verbatim — the user
    // picked the exact span they want as the unit (partial-word, multi-word
    // phrase, …). Only word-granularity gestures (double-click) trigger the
    // word-boundary snap below.
    if granularity == .character {
      return trimmed
    }
    // Translate selectionRange (UTF-16) into String.Index, then narrow it to
    // the trimmed substring's actual position so the snap walk happens around
    // the user's selection — not the first text-match.
    guard let selStart = stringIndex(in: context, utf16Offset: selectionRange.location),
      let selEnd = stringIndex(
        in: context, utf16Offset: selectionRange.location + selectionRange.length)
    else {
      return trimmed
    }
    let selSubstring = String(context[selStart..<selEnd])
    guard let trimmedRangeInSel = selSubstring.range(of: trimmed) else {
      return trimmed
    }
    let trimmedStartOffset = selSubstring.distance(
      from: selSubstring.startIndex, to: trimmedRangeInSel.lowerBound)
    let trimmedLength = selSubstring.distance(
      from: trimmedRangeInSel.lowerBound, to: trimmedRangeInSel.upperBound)
    let trimmedStart = context.index(selStart, offsetBy: trimmedStartOffset)
    let trimmedEnd = context.index(trimmedStart, offsetBy: trimmedLength)

    var snappedStart = trimmedStart
    var snappedEnd = trimmedEnd
    context.enumerateSubstrings(
      in: context.startIndex..<context.endIndex, options: [.byWords]
    ) { _, wordRange, _, stop in
      if wordRange.lowerBound <= trimmedStart, wordRange.upperBound > trimmedStart {
        snappedStart = wordRange.lowerBound
      }
      if wordRange.lowerBound < trimmedEnd, wordRange.upperBound >= trimmedEnd {
        snappedEnd = wordRange.upperBound
        stop = true
      }
    }
    return String(context[snappedStart..<snappedEnd])
  }

  /// Convert a UTF-16 offset (the unit AppKit hands us via NSRange) into a
  /// Swift `String.Index`. Returns nil for out-of-bounds or mid-surrogate
  /// offsets.
  private static func stringIndex(in s: String, utf16Offset: Int) -> String.Index? {
    let utf16 = s.utf16
    guard utf16Offset >= 0, utf16Offset <= utf16.count,
      let u16Index = utf16.index(utf16.startIndex, offsetBy: utf16Offset, limitedBy: utf16.endIndex)
    else {
      return nil
    }
    return u16Index.samePosition(in: s)
  }
}
