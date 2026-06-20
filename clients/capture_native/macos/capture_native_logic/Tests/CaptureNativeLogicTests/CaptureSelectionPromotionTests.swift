//
//  CaptureSelectionPromotionTests.swift
//  CaptureNativeLogicTests
//
//  Pins the CAP-2 trim/snap contract documented on
//  `CaptureSelectionPromotion.promote` / `.isSpaceDelimited`.
//

import XCTest

@testable import CaptureNativeLogic

final class CaptureSelectionPromotionTests: XCTestCase {

  private typealias Promotion = CaptureSelectionPromotion

  // MARK: - isSpaceDelimited

  func testSpaceDelimitedLanguagesAreTrue() {
    for tag in ["en", "en-US", "es", "fr", "de", "pt", "it", "ru", "EN", "Fr-CA"] {
      XCTAssertTrue(Promotion.isSpaceDelimited(targetLanguage: tag), tag)
    }
  }

  func testNoSpaceScriptsAreFalse() {
    // zh / ja / ko / th / my / km / lo — exact tag or "<prefix>-…" variant.
    for tag in [
      "zh", "zh-Hans", "zh-Hant", "ja", "ja-JP", "ko", "ko-KR",
      "th", "my", "km", "lo", "ZH", "JA-jp",
    ] {
      XCTAssertFalse(Promotion.isSpaceDelimited(targetLanguage: tag), tag)
    }
  }

  func testPrefixHyphenSafety() {
    // A longer tag that merely STARTS with a no-space prefix (but isn't that
    // tag or a "<prefix>-…" variant) stays space-delimited.
    for tag in ["java", "korean", "zhuang", "lodash", "thai-ish"] {
      XCTAssertTrue(Promotion.isSpaceDelimited(targetLanguage: tag), tag)
    }
  }

  // MARK: - promote: trim + no-op

  func testEmptySelectionReturnsNil() {
    XCTAssertNil(
      Promotion.promote(
        rawSelection: "", in: "hello",
        selectionRange: NSRange(location: 0, length: 0),
        targetLanguage: "en", granularity: .word))
  }

  func testPunctuationOnlySelectionReturnsNil() {
    XCTAssertNil(
      Promotion.promote(
        rawSelection: " ... ", in: "a ... b",
        selectionRange: NSRange(location: 2, length: 3),
        targetLanguage: "en", granularity: .word))
  }

  func testTrimsLeadingAndTrailingWhitespaceAndPunctuation() {
    // Use the CJK path (returns the trimmed span verbatim) to isolate trimming
    // from the word snap. Spaces + parens + period are stripped from the ends.
    let result = Promotion.promote(
      rawSelection: " (word). ", in: "anything",
      selectionRange: NSRange(location: 0, length: 0),
      targetLanguage: "zh-Hans", granularity: .word)
    XCTAssertEqual(result, "word")
  }

  // MARK: - promote: CJK / no-space targets take the trimmed span as-is

  func testNoSpaceTargetReturnsTrimmedSpanWithoutSnap() {
    // Japanese: a partial selection is taken verbatim (after trim); no snap,
    // selectionRange is irrelevant on this path.
    let result = Promotion.promote(
      rawSelection: "本語", in: "日本語",
      selectionRange: NSRange(location: 1, length: 2),
      targetLanguage: "ja", granularity: .word)
    XCTAssertEqual(result, "本語")
  }

  // MARK: - promote: character granularity is respected verbatim

  func testCharacterGranularityKeepsPartialWord() {
    // Drag-selected "ifecycl" from "lifecycle" is a deliberate partial pick.
    let context = "the lifecycle of apps"
    let result = Promotion.promote(
      rawSelection: "ifecycl", in: context,
      selectionRange: NSRange(location: 5, length: 7),
      targetLanguage: "en", granularity: .character)
    XCTAssertEqual(result, "ifecycl")
  }

  func testCharacterGranularityKeepsMultiWordPhrase() {
    let context = "while reading the news"
    let result = Promotion.promote(
      rawSelection: "reading the", in: context,
      selectionRange: NSRange(location: 6, length: 11),
      targetLanguage: "en", granularity: .character)
    XCTAssertEqual(result, "reading the")
  }

  // MARK: - promote: word granularity snaps to word boundaries

  func testWordGranularityExactWordIsUnchanged() {
    let context = "an unfair deal"
    let result = Promotion.promote(
      rawSelection: "unfair", in: context,
      selectionRange: NSRange(location: 3, length: 6),
      targetLanguage: "en", granularity: .word)
    XCTAssertEqual(result, "unfair")
  }

  func testWordGranularitySnapsPartialUpToFullWord() {
    // A word gesture that slightly under-covers the word snaps to the whole word.
    let context = "the lifecycle of apps"
    let result = Promotion.promote(
      rawSelection: "ifecycl", in: context,
      selectionRange: NSRange(location: 5, length: 7),
      targetLanguage: "en", granularity: .word)
    XCTAssertEqual(result, "lifecycle")
  }

  func testWordGranularityTrimsPunctuationThenSnaps() {
    let context = "it was unfair, really"
    let result = Promotion.promote(
      rawSelection: "unfair,", in: context,
      selectionRange: NSRange(location: 7, length: 7),
      targetLanguage: "en", granularity: .word)
    XCTAssertEqual(result, "unfair")
  }

  // MARK: - promote: the snap walks from the SELECTION position, not first match

  func testWordSnapUsesSelectionPositionForADuplicateSubstring() {
    // "at" occurs inside BOTH "cat" and "hat". Selecting the "at" in the second
    // word must snap to "hat" — a naive range(of:) first-match would give "cat".
    let context = "cat hat"
    let result = Promotion.promote(
      rawSelection: "at", in: context,
      selectionRange: NSRange(location: 5, length: 2),  // the "at" inside "hat"
      targetLanguage: "en", granularity: .word)
    XCTAssertEqual(result, "hat")
  }

  func testWordSnapAtFirstOccurrenceStillSnapsToFirstWord() {
    // The mirror of the above: the "at" inside the FIRST word snaps to "cat".
    let context = "cat hat"
    let result = Promotion.promote(
      rawSelection: "at", in: context,
      selectionRange: NSRange(location: 1, length: 2),  // the "at" inside "cat"
      targetLanguage: "en", granularity: .word)
    XCTAssertEqual(result, "cat")
  }

  // MARK: - promote: robustness

  func testWordGranularityFallsBackToTrimmedOnOutOfBoundsRange() {
    // An un-mappable (out-of-bounds) selectionRange returns the trimmed
    // selection rather than crashing.
    let result = Promotion.promote(
      rawSelection: "word", in: "a word",
      selectionRange: NSRange(location: 999, length: 4),
      targetLanguage: "en", granularity: .word)
    XCTAssertEqual(result, "word")
  }
}
