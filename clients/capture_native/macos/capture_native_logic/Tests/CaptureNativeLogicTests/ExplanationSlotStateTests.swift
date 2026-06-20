//
//  ExplanationSlotStateTests.swift
//  CaptureNativeLogicTests
//
//  Pins the D3 server-driven explanation-slot contract (the client holds NO
//  target allowlist — `langUnsupported` is a pushed state like the others), and
//  the Phase-1 per-POS senses `OverlayExplanation.from` derivation (the senses
//  ARE the explanation; the layout — cap/numbering/hint — is computed Dart-side
//  and bridged ready-to-render).
//

import XCTest

@testable import CaptureNativeLogic

/// Build a raw reading tuple for `OverlayExplanation.from` concisely. Senses carry no shared note here
/// (note consolidation is a Dart-side `computeSenseLayout` concern, tested there); the note carry-
/// through is exercised by its own case below.
private func rawReading(
  _ pron: [(label: String?, display: String)],
  isIdiom: Bool = false,
  _ pos: [(partOfSpeech: String, senses: [String])]
) -> (
  pronunciations: [(label: String?, display: String)], isIdiom: Bool,
  pos: [(partOfSpeech: String, senses: [String], note: String)]
) {
  (
    pronunciations: pron, isIdiom: isIdiom,
    pos: pos.map {
      (partOfSpeech: $0.partOfSpeech, senses: $0.senses, note: "")
    }
  )
}

final class ExplanationSlotStateTests: XCTestCase {

  // MARK: - the D3 state contract

  func testPushedStatesAreDistinct() {
    XCTAssertNotEqual(ExplanationSlotState.notAWord, .failed)
    XCTAssertNotEqual(ExplanationSlotState.notAWord, .hidden)
    XCTAssertNotEqual(ExplanationSlotState.langUnsupported, .failed)
    XCTAssertNotEqual(ExplanationSlotState.langUnsupported, .hidden)
    XCTAssertNotEqual(ExplanationSlotState.langUnsupported, .notAWord)
  }

  // MARK: - OverlayExplanation.from (per-POS senses derivation)

  func testSensesRenderTrimmedUnderTheirReading() {
    let exp = OverlayExplanation.from(
      readings: [
        rawReading(
          [(label: "US", display: "/rʌn/")],
          [
            (partOfSpeech: "verb", senses: ["  to move fast  ", "to operate"]),
            (partOfSpeech: "noun", senses: ["an act of running"]),
          ])
      ])
    guard let exp else { return XCTFail("expected an explanation") }
    XCTAssertEqual(exp.readings.count, 1)
    let pos = exp.readings[0].pos
    XCTAssertEqual(pos[0].partOfSpeech, "verb")
    XCTAssertEqual(pos[0].senses, ["to move fast", "to operate"])  // trimmed
    XCTAssertEqual(pos[1].senses, ["an act of running"])
  }

  func testNoSurvivingSenseReturnsNil() {
    // MUST-PASS core: a blob with no usable sense anywhere is unusable → nil (caller shows .failed).
    XCTAssertNil(OverlayExplanation.from(readings: []))
    XCTAssertNil(
      OverlayExplanation.from(
        readings: [rawReading([(label: "US", display: "/rʌn/")], [(partOfSpeech: "verb", senses: ["   ", ""])])]))
  }

  func testHeteronymKeepsOneBlockPerReading() {
    let exp = OverlayExplanation.from(
      readings: [
        rawReading(
          [(label: "US", display: "/ˈrɛkɚd/"), (label: "UK", display: "/ˈrɛkɔːd/")],
          [(partOfSpeech: "noun", senses: ["a stored account"])]),
        rawReading(
          [(label: "US", display: "/rɪˈkɔːrd/")],
          [(partOfSpeech: "verb", senses: ["to store sound"])]),
      ])
    guard let exp else { return XCTFail("expected an explanation") }
    XCTAssertEqual(exp.readings.count, 2)
    XCTAssertEqual(exp.readings[0].pronunciations.map { $0.display }, ["/ˈrɛkɚd/", "/ˈrɛkɔːd/"])
    XCTAssertEqual(exp.readings[1].pos[0].partOfSpeech, "verb")
    XCTAssertFalse(exp.readings[0].isIdiom)
  }

  func testIdiomReadingFlaggedWithNoPronunciation() {
    let exp = OverlayExplanation.from(
      readings: [
        rawReading([], isIdiom: true, [(partOfSpeech: "idiom", senses: ["打破僵局"])])
      ])
    guard let block = exp?.readings.first else { return XCTFail("expected a reading") }
    XCTAssertTrue(block.isIdiom)
    XCTAssertFalse(block.hasPronunciation)
    XCTAssertEqual(block.pos[0].senses, ["打破僵局"])
  }

  func testSharedFormNoteCarriedThroughTrimmed() {
    // The shared form note (pulled out Dart-side so it shows once at the front) rides through `from`,
    // trimmed — it is NOT folded back into the senses.
    let exp = OverlayExplanation.from(
      readings: [
        (
          pronunciations: [(label: "US", display: "/ˈmeɪkɪŋ/")], isIdiom: false,
          pos: [(partOfSpeech: "verb", senses: ["制造", "做", "使得"], note: "  make 的现在分词  ")]
        )
      ])
    let row = exp?.readings.first?.pos.first
    XCTAssertEqual(row?.note, "make 的现在分词")
    XCTAssertEqual(row?.senses, ["制造", "做", "使得"])
  }

  func testBlankSensesEmptyPosAndEmptyReadingsPruned() {
    let exp = OverlayExplanation.from(
      readings: [
        rawReading([(label: "US", display: "/x/")], [(partOfSpeech: "noun", senses: ["  "])]),  // all-blank → pruned
        rawReading(
          [(label: "US", display: "/rʌn/")],
          [
            (partOfSpeech: "adj", senses: [""]),  // empty → dropped
            (partOfSpeech: "verb", senses: ["a real meaning"]),  // kept
          ]),
      ])
    guard let exp else { return XCTFail("expected an explanation") }
    XCTAssertEqual(exp.readings.count, 1)
    XCTAssertEqual(exp.readings[0].pos.count, 1)
    XCTAssertEqual(exp.readings[0].pos[0].partOfSpeech, "verb")
  }

  func testUnlabeledPronunciationPassesThroughVerbatim() {
    let exp = OverlayExplanation.from(
      readings: [rawReading([(label: nil, display: "xíng")], [(partOfSpeech: "verb", senses: ["to walk"])])])
    let part = exp?.readings.first?.pronunciations.first
    XCTAssertNil(part?.label)
    XCTAssertEqual(part?.display, "xíng")
  }

  // MARK: - POS abbreviation (the per-row label)

  func testAbbreviatePosUsesStandardDictionaryForms() {
    XCTAssertEqual(OverlayPosRow.abbreviatePos("noun"), "noun")
    XCTAssertEqual(OverlayPosRow.abbreviatePos("Verb"), "verb")  // case-insensitive
    XCTAssertEqual(OverlayPosRow.abbreviatePos(" adjective "), "adj.")  // trimmed
    XCTAssertEqual(OverlayPosRow.abbreviatePos("adverb"), "adv.")
    XCTAssertEqual(OverlayPosRow.abbreviatePos("phrasal verb"), "phr. verb")
    XCTAssertEqual(OverlayPosRow.abbreviatePos("idiom"), "idiom")
    XCTAssertEqual(OverlayPosRow.abbreviatePos("particle"), "part.")
    XCTAssertEqual(OverlayPosRow.abbreviatePos("measure word"), "meas.")
    XCTAssertEqual(OverlayPosRow.abbreviatePos("Sparkle-Word"), "sparkle-word")  // unknown → pass-through
  }

  func testPosRowLabelIsTheAbbreviation() {
    let row = OverlayPosRow(
      partOfSpeech: "adjective", senses: ["able to be received gladly"], note: "")
    XCTAssertEqual(row.label, "adj.")
  }
}
