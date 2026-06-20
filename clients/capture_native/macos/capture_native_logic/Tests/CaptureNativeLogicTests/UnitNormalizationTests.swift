//
//  UnitNormalizationTests.swift
//  CaptureNativeLogicTests
//
//  Pins `UnitNormalization.hasWordContent` against the dedup-key rule it mirrors: a unit has word
//  content iff it keeps >= 1 letter/mark/number, i.e. its `localDedupKey` (capture_repository.dart) is
//  non-empty. This is the guard that stops a punctuation-only "Saved" from silently creating no word.
//

import XCTest

@testable import CaptureNativeLogic

final class UnitNormalizationTests: XCTestCase {

  func testRealWordsHaveContent() {
    for unit in ["serendipity", "café", "naïve", "co-operate", "U.S.A.", "word123", "42", "3.14"] {
      XCTAssertTrue(UnitNormalization.hasWordContent(unit), "\(unit) should have word content")
    }
  }

  func testNonLatinAndCjkHaveContent() {
    // Letters/marks/numbers in any script count (the dedup key is language-independent).
    for unit in ["框架", "日本語", "한국어", "Привет", "العربية", "naïveté", "①②③"] {
      XCTAssertTrue(UnitNormalization.hasWordContent(unit), "\(unit) should have word content")
    }
  }

  func testPunctuationOrSymbolOnlyHasNoContent() {
    // These all normalize to "" via localDedupKey (only edge non-L/M/N runs, which is the WHOLE string)
    // — the silent-save-loss footgun. The Save gate must reject them like an empty unit.
    for unit in ["", "   ", "###", "•••", "—", "→", "...", "!?", "()", "\"\"", "  -- ", "💡", "🎉🎉"] {
      XCTAssertFalse(UnitNormalization.hasWordContent(unit), "\(unit) should have NO word content")
    }
  }

  func testEdgePunctuationAroundAWordKeepsContent() {
    // A real letter/number anywhere survives the edge-strip → still has content (and saves fine).
    for unit in ["“word”", "(note)", "#hashtag", "word!", "-led-", "C++", "a"] {
      XCTAssertTrue(UnitNormalization.hasWordContent(unit), "\(unit) should have word content")
    }
  }
}
