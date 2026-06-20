//
//  UnitSpanResolverTests.swift
//  CaptureNativeLogicTests
//
//  Pins the captured-span contract documented on `UnitSpanResolver.span`:
//  UTF-16 [start, end) of the (trimmed) unit within the context, first
//  case-insensitive match, nil when there is no context or no match.
//

import XCTest

@testable import CaptureNativeLogic

final class UnitSpanResolverTests: XCTestCase {

  func testReturnsUTF16HalfOpenRange() {
    // "world" sits at UTF-16 [6, 11) in "hello world".
    let span = UnitSpanResolver.span(unit: "world", in: "hello world")
    XCTAssertEqual(span?.start, 6)
    XCTAssertEqual(span?.end, 11)
  }

  func testCaseInsensitiveSingleOccurrence() {
    // A single occurrence in a different case still matches. "world" at UTF-16 [10, 15).
    let span = UnitSpanResolver.span(unit: "WORLD", in: "say hello world")
    XCTAssertEqual(span?.start, 10)
    XCTAssertEqual(span?.end, 15)
  }

  func testNilWhenUnitOccursMoreThanOnce() {
    // "the" appears twice ("The" + "the") — we can't tell which one was captured,
    // so the span is ambiguous and must be nil rather than a guessed first match.
    XCTAssertNil(UnitSpanResolver.span(unit: "the", in: "The cat sat on the mat"))
  }

  func testNilWhenUnitAlsoAppearsAsSubstring() {
    // "art" appears inside "partial" AND standalone — ambiguous, so nil (would
    // otherwise highlight the "art" inside "partial").
    XCTAssertNil(UnitSpanResolver.span(unit: "art", in: "partial art"))
  }

  func testNilWhenSecondOccurrenceOverlapsTheFirst() {
    // "ana" matches "banana" at offset 1 AND 3 (overlapping). The ambiguity scan
    // starts one unit past the first match's START, so it catches the overlap → nil.
    XCTAssertNil(UnitSpanResolver.span(unit: "ana", in: "banana"))
  }

  func testUnitIsTrimmedBeforeMatching() {
    let span = UnitSpanResolver.span(unit: "  world \n", in: "hello world")
    XCTAssertEqual(span?.start, 6)
    XCTAssertEqual(span?.end, 11)
  }

  func testOffsetsAreUTF16NotCharacterCounts() {
    // A leading emoji is one Character but two UTF-16 code units, so "apple"
    // begins at UTF-16 offset 3 (emoji = 2, space = 1), not 2.
    let span = UnitSpanResolver.span(unit: "apple", in: "🍎 apple")
    XCTAssertEqual(span?.start, 3)
    XCTAssertEqual(span?.end, 8)
  }

  func testNilWhenUnitAbsent() {
    XCTAssertNil(UnitSpanResolver.span(unit: "zebra", in: "hello world"))
  }

  func testNilWhenContextNil() {
    XCTAssertNil(UnitSpanResolver.span(unit: "world", in: nil))
  }

  func testNilWhenContextEmpty() {
    XCTAssertNil(UnitSpanResolver.span(unit: "world", in: ""))
  }

  func testNilWhenUnitEmptyOrWhitespaceOnly() {
    XCTAssertNil(UnitSpanResolver.span(unit: "", in: "hello world"))
    XCTAssertNil(UnitSpanResolver.span(unit: "   \n", in: "hello world"))
  }
}
