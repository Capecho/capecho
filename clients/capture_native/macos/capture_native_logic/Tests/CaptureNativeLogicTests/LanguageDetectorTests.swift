//
//  LanguageDetectorTests.swift
//  CaptureNativeLogicTests
//
//  Pins `LanguageDetector.detect` — the NLLanguageRecognizer wrapper run on the
//  cursor's visual span (Phase-2 unit-language confirm). Asserts the dominant
//  language for sentence-length input across the scripts the confirm cares about,
//  and the empty/whitespace guards.
//

import XCTest

@testable import CaptureNativeLogic

final class LanguageDetectorTests: XCTestCase {

  func testDetectsEnglish() {
    XCTAssertEqual(LanguageDetector.detect("Good morning, everyone, how are you today")?.language, "en")
  }

  func testDetectsSpanish() {
    XCTAssertEqual(
      LanguageDetector.detect("Hola, ¿cómo estás? Esto es una frase en español.")?.language, "es")
  }

  func testDetectsChineseAsZh() {
    XCTAssertEqual(LanguageDetector.detect("这是一段中文测试文本")?.language.prefix(2), "zh")
  }

  func testDetectsJapanese() {
    XCTAssertEqual(LanguageDetector.detect("これは日本語のテスト文章です")?.language, "ja")
  }

  func testReportsAConfidence() {
    let result = LanguageDetector.detect("Good morning, everyone, how are you today")
    XCTAssertNotNil(result)
    XCTAssertGreaterThan(result?.confidence ?? 0, 0)
  }

  func testEmptyAndWhitespaceReturnNil() {
    XCTAssertNil(LanguageDetector.detect(""))
    XCTAssertNil(LanguageDetector.detect("   \n\t "))
  }
}
