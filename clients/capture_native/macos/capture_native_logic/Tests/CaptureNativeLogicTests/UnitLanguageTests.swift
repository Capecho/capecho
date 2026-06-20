import XCTest

@testable import CaptureNativeLogic

/// Parity mirror of `shared/capture-core/test/unit_language_test.dart` — the same
/// inputs must yield the same outputs in the native `UnitLanguage` the overlay uses
/// to re-derive the target on a unit change. (The Dart-only CursorVisualSpan
/// round-trip cases aren't relevant to this pure-logic port.)
final class UnitLanguageTests: XCTestCase {

  // MARK: dominantScript

  func testClassifiesSingleScriptUnits() {
    XCTAssertEqual(UnitLanguage.dominantScript("hello"), .latin)
    XCTAssertEqual(UnitLanguage.dominantScript("café"), .latin)  // accented Latin
    XCTAssertEqual(UnitLanguage.dominantScript("中文"), .han)
    XCTAssertEqual(UnitLanguage.dominantScript("한국어"), .hangul)
    XCTAssertEqual(UnitLanguage.dominantScript("Привет"), .cyrillic)
  }

  func testKanaWinsOverHanForJapanese() {
    XCTAssertEqual(UnitLanguage.dominantScript("勉強する"), .kana)  // kanji + kana → ja
    XCTAssertEqual(UnitLanguage.dominantScript("がくしゅう"), .kana)
    XCTAssertEqual(UnitLanguage.dominantScript("勉強"), .han)  // pure kanji → Han (zh default)
  }

  func testHanWinsOverLatinAndSymbolsEmptyAreOther() {
    XCTAssertEqual(UnitLanguage.dominantScript("中A"), .han)
    XCTAssertEqual(UnitLanguage.dominantScript(""), .other)
    XCTAssertEqual(UnitLanguage.dominantScript("123 …"), .other)
  }

  // MARK: scriptsOfLanguage

  func testMapsLearningTagsToWritingSystems() {
    XCTAssertEqual(UnitLanguage.scriptsOfLanguage("en"), [.latin])
    XCTAssertEqual(UnitLanguage.scriptsOfLanguage("es"), [.latin])
    XCTAssertEqual(UnitLanguage.scriptsOfLanguage("zh-Hans"), [.han])
    XCTAssertEqual(UnitLanguage.scriptsOfLanguage("ja"), [.han, .kana])
    XCTAssertEqual(UnitLanguage.scriptsOfLanguage("ko"), [.hangul])
    XCTAssertEqual(UnitLanguage.scriptsOfLanguage("ru"), [.cyrillic])
    XCTAssertEqual(UnitLanguage.scriptsOfLanguage("xx"), [.latin])  // unknown → Latin
  }

  // MARK: effectiveTargetLanguage — auto-switch on script-disjoint certainty

  func testLearningEnglishChineseUnitAutoSwitches() {
    XCTAssertEqual(UnitLanguage.effectiveTargetLanguage(unit: "中文", learningLanguage: "en"), "zh-Hans")
    XCTAssertEqual(UnitLanguage.effectiveTargetLanguage(unit: "猫", learningLanguage: "en"), "zh-Hans")
  }

  func testLearningEnglishKoreanOrKanaSwitches() {
    XCTAssertEqual(UnitLanguage.effectiveTargetLanguage(unit: "한국어", learningLanguage: "en"), "ko")
    XCTAssertEqual(UnitLanguage.effectiveTargetLanguage(unit: "がくしゅう", learningLanguage: "en"), "ja")
    XCTAssertEqual(UnitLanguage.effectiveTargetLanguage(unit: "勉強する", learningLanguage: "en"), "ja")  // kana → ja
  }

  // MARK: effectiveTargetLanguage — no switch (compatible or deferred)

  func testSameScriptKeepsConfiguredTarget() {
    XCTAssertEqual(UnitLanguage.effectiveTargetLanguage(unit: "hello", learningLanguage: "en"), "en")
    XCTAssertEqual(UnitLanguage.effectiveTargetLanguage(unit: "casa", learningLanguage: "en"), "en")  // en-vs-es deferred
    XCTAssertEqual(UnitLanguage.effectiveTargetLanguage(unit: "中文", learningLanguage: "zh-Hans"), "zh-Hans")
    XCTAssertEqual(UnitLanguage.effectiveTargetLanguage(unit: "勉強", learningLanguage: "ja"), "ja")  // Han ∈ ja
    XCTAssertEqual(UnitLanguage.effectiveTargetLanguage(unit: "がく", learningLanguage: "ja"), "ja")
  }

  func testLatinUnitWhileLearningCJKIsNotGuessed() {
    // Which Latin language ("hello" → en?) needs real detection, so it stays on the
    // configured target rather than hard-code English.
    XCTAssertEqual(UnitLanguage.effectiveTargetLanguage(unit: "hello", learningLanguage: "zh-Hans"), "zh-Hans")
  }

  func testEmptyUnitKeepsConfiguredTarget() {
    XCTAssertEqual(UnitLanguage.effectiveTargetLanguage(unit: "", learningLanguage: "en"), "en")
    XCTAssertEqual(UnitLanguage.effectiveTargetLanguage(unit: "   ", learningLanguage: "en"), "en")
  }

  func testChineseLearnerCapturingKanaSwitchesToJapanese() {
    XCTAssertEqual(UnitLanguage.effectiveTargetLanguage(unit: "がく", learningLanguage: "zh-Hans"), "ja")
  }

  // MARK: suggestedTargetLanguage — the same-script / which-Latin confirm

  func testSpanishPassageWhileLearningEnglishSuggestsSpanish() {
    XCTAssertEqual(
      UnitLanguage.suggestedTargetLanguage(
        unit: "casa", effectiveTarget: "en", spanLanguage: "es", spanLanguageConfidence: 0.95),
      "es")
  }

  func testLatinWordWhileLearningChineseSuggestsDetectedLatin() {
    XCTAssertEqual(
      UnitLanguage.suggestedTargetLanguage(
        unit: "hello", effectiveTarget: "zh-Hans", spanLanguage: "en", spanLanguageConfidence: 0.97),
      "en")
  }

  func testNeverSecondGuessesAScriptDisjointUnit() {
    // A 中文 unit captured while reading English → effectiveTarget set zh-Hans. The span
    // is English, but the unit is Han, so the English span must NOT drag it back to en.
    XCTAssertNil(
      UnitLanguage.suggestedTargetLanguage(
        unit: "中文", effectiveTarget: "zh-Hans", spanLanguage: "en", spanLanguageConfidence: 0.99))
  }

  func testNoSuggestionWhenSpanEqualsTarget() {
    XCTAssertNil(
      UnitLanguage.suggestedTargetLanguage(
        unit: "hello", effectiveTarget: "en", spanLanguage: "en", spanLanguageConfidence: 0.99))
  }

  func testNoSuggestionBelowConfidenceGate() {
    XCTAssertNil(
      UnitLanguage.suggestedTargetLanguage(
        unit: "casa", effectiveTarget: "en", spanLanguage: "es", spanLanguageConfidence: 0.40))
  }

  func testNoSuggestionForUnsupportedOrUndetectedLanguage() {
    XCTAssertNil(
      UnitLanguage.suggestedTargetLanguage(
        unit: "hallo", effectiveTarget: "en", spanLanguage: "nl", spanLanguageConfidence: 0.95))  // Dutch: unsupported
    XCTAssertNil(
      UnitLanguage.suggestedTargetLanguage(
        unit: "casa", effectiveTarget: "en", spanLanguage: nil, spanLanguageConfidence: 0.0))
  }

  // MARK: more parity cases

  func testPureKanjiInJapaneseSpanSuggestsJa() {
    // effectiveTarget left 勉強 on zh-Hans (Han default); a confidently-Japanese span (ja's
    // scripts include Han) is the one case a suggestion fires on a Han unit.
    XCTAssertEqual(
      UnitLanguage.suggestedTargetLanguage(
        unit: "勉強", effectiveTarget: "zh-Hans", spanLanguage: "ja", spanLanguageConfidence: 0.97),
      "ja")
  }

  func testConfidenceGateInclusiveAtExactly065() {
    XCTAssertEqual(
      UnitLanguage.suggestedTargetLanguage(
        unit: "casa", effectiveTarget: "en", spanLanguage: "es", spanLanguageConfidence: 0.65),
      "es")
    XCTAssertNil(
      UnitLanguage.suggestedTargetLanguage(
        unit: "casa", effectiveTarget: "en", spanLanguage: "es", spanLanguageConfidence: 0.649))
  }

  func testCyrillicUnitNeitherAutoSwitchedNorSuggested() {
    XCTAssertEqual(UnitLanguage.effectiveTargetLanguage(unit: "Привет", learningLanguage: "en"), "en")
    XCTAssertNil(
      UnitLanguage.suggestedTargetLanguage(
        unit: "Привет", effectiveTarget: "en", spanLanguage: "ru", spanLanguageConfidence: 0.98))
  }

  // MARK: scriptCertainLanguage (parity with unit_language_test.dart)

  func testMonoScriptCjkSentencesPinTheirLanguage() {
    XCTAssertEqual(UnitLanguage.scriptCertainLanguage("我们今天学习新词。"), "zh-Hans")
    XCTAssertEqual(UnitLanguage.scriptCertainLanguage("第3章：序言"), "zh-Hans")  // digits/symbols OK
    XCTAssertEqual(UnitLanguage.scriptCertainLanguage("勉強が好きです。"), "ja")  // kana (+kanji)
    XCTAssertEqual(UnitLanguage.scriptCertainLanguage("한국어를 공부해요."), "ko")
  }

  func testAnyLatinOrCyrillicLetterKillsCertainty() {
    XCTAssertNil(UnitLanguage.scriptCertainLanguage("The word 学习 means to study."))  // zh-in-en
    XCTAssertNil(UnitLanguage.scriptCertainLanguage("我们学习 English"))
    XCTAssertNil(UnitLanguage.scriptCertainLanguage("Hello world."))  // which Latin language?
    XCTAssertNil(UnitLanguage.scriptCertainLanguage("café au lait"))  // accented Latin too
    XCTAssertNil(UnitLanguage.scriptCertainLanguage("Привет мир"))
  }

  func testDegenerateInputsAreUnknownAndKanaHangulMixIsNonsense() {
    XCTAssertNil(UnitLanguage.scriptCertainLanguage(""))
    XCTAssertNil(UnitLanguage.scriptCertainLanguage("123 …"))  // no letters at all
    XCTAssertNil(UnitLanguage.scriptCertainLanguage("한국어です"))  // hangul+kana
  }

  func testAnyNonPinningScriptLetterKillsCertainty() {
    XCTAssertNil(UnitLanguage.scriptCertainLanguage("كتاب 书"))  // Arabic-dominant + one Han char
    XCTAssertNil(UnitLanguage.scriptCertainLanguage("ＨＥＬＬＯ 学习"))  // full-width Latin
    XCTAssertNil(UnitLanguage.scriptCertainLanguage("𝐀𝐁 学习"))  // astral math alphanumerics
    XCTAssertNil(UnitLanguage.scriptCertainLanguage("สวัสดี 中文"))  // Thai
  }

  func testIterationMarkCountsAsHanNotCertaintyKiller() {
    XCTAssertEqual(UnitLanguage.scriptCertainLanguage("人々の暮らし"), "ja")  // 々 + kana
    XCTAssertEqual(UnitLanguage.scriptCertainLanguage("山々相连。"), "zh-Hans")  // pure Han + 々
  }
}
