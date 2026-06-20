import XCTest

@testable import CaptureNativeLogic

/// Exercises the REAL `NLTokenizer` word boundaries that the captured unit now relies
/// on. The shared Dart tokenizer tests can only SIMULATE NLTokenizer (it can't run in
/// pure-Dart CI), so this is the one place the actual system segmentation — including
/// CJK dictionary segmentation — is verified. Assertions favour robust invariants over
/// exact dictionary splits, which vary by OS version.
final class WordSegmenterTests: XCTestCase {

  private func texts(_ s: String) -> [String] { WordSegmenter.segments(in: s).map(\.text) }

  func testSplitsLatinOnSpaces() {
    XCTAssertEqual(texts("the quick brown fox"), ["the", "quick", "brown", "fox"])
  }

  func testDropsPunctuationOnlyTokens() {
    // Commas / bangs / parens aren't word scalars (containsWordScalar) → filtered out.
    XCTAssertEqual(texts("hi, there! (yes)"), ["hi", "there", "yes"])
  }

  func testKeepsNumericTokens() {
    // A digit has a numericType, so a standalone number survives the word-scalar gate.
    XCTAssertTrue(texts("buy 3 apples").contains("3"))
  }

  func testEmptyAndPunctuationOnlyYieldNothing() {
    XCTAssertTrue(WordSegmenter.segments(in: "").isEmpty)
    XCTAssertTrue(WordSegmenter.segments(in: "   ").isEmpty)
    XCTAssertTrue(WordSegmenter.segments(in: "!!! …").isEmpty)
  }

  func testOffsetsRoundTripToTheTokenText() {
    // The Dart side indexes [OcrLine.text] with these UTF-16 offsets, so each run's
    // [start, end) must slice back to exactly its own token text (incl. a BMP accent).
    let source = "café au lait 中文"
    let units = Array(source.utf16)
    for seg in WordSegmenter.segments(in: source) {
      XCTAssertGreaterThanOrEqual(seg.utf16Start, 0)
      XCTAssertLessThanOrEqual(seg.utf16End, units.count)
      XCTAssertGreaterThan(seg.utf16End, seg.utf16Start)
      let slice = Array(units[seg.utf16Start..<seg.utf16End])
      XCTAssertEqual(String(utf16CodeUnits: slice, count: slice.count), seg.text)
      XCTAssertEqual(seg.utf16End - seg.utf16Start, seg.text.utf16.count)
    }
    XCTAssertEqual(texts("café au lait"), ["café", "au", "lait"])
  }

  func testSegmentsChineseIntoMultipleWords() {
    // NLTokenizer dictionary-segments Chinese into WORDS — more than one token for a
    // multi-word phrase, and NOT one token per character. Exact boundaries are
    // dictionary/OS-dependent, so assert the robust shape: ≥2 sorted, non-overlapping,
    // in-bounds, non-empty word runs.
    let source = "我在学习中文"
    let segs = WordSegmenter.segments(in: source)
    XCTAssertGreaterThanOrEqual(segs.count, 2, "Chinese should segment into multiple words")
    let u16count = source.utf16.count
    var prevEnd = -1
    for seg in segs {
      XCTAssertFalse(seg.text.isEmpty)
      XCTAssertGreaterThanOrEqual(seg.utf16Start, 0)
      XCTAssertLessThanOrEqual(seg.utf16End, u16count)
      XCTAssertGreaterThan(seg.utf16End, seg.utf16Start)
      XCTAssertGreaterThanOrEqual(seg.utf16Start, prevEnd, "runs must be sorted + non-overlapping")
      prevEnd = seg.utf16End
    }
  }
}
