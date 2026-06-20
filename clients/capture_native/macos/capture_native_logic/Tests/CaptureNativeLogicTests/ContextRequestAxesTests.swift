import XCTest

@testable import CaptureNativeLogic

/// Pins the context-layer request axes the PLUGIN glue forwards — the Save stamp rule and the
/// preview payload's KEY SPELLINGS, which must byte-match the Dart
/// `OverlayContextPreviewRequest.fromMap` keys ("spanStart" / "spanEnd" / "contextLanguage").
/// A typo in either side now fails here instead of silently dropping the axis on the wire.
final class ContextRequestAxesTests: XCTestCase {

  // MARK: Save stamp (context_language)

  func testSaveStampIsScriptCertainOrNil() {
    // A mono-script zh sentence pins its language; the normal mixed capture and Latin text do not;
    // nil context stays nil. NEVER the target language.
    XCTAssertEqual(ContextRequestAxes.contextLanguage(of: "我们今天学习新词。"), "zh-Hans")
    XCTAssertNil(ContextRequestAxes.contextLanguage(of: "The word 学习 means to study."))
    XCTAssertNil(ContextRequestAxes.contextLanguage(of: "The cell divides rapidly."))
    XCTAssertNil(ContextRequestAxes.contextLanguage(of: nil))
  }

  // MARK: Preview payload fields

  func testPayloadCarriesSpanAndLanguageUnderTheExactDartKeys() {
    // "我们今天学习新词。" — "学习" sits at UTF-16 [4, 6), unique → span present; mono-script → language.
    let fields = ContextRequestAxes.previewPayloadFields(unit: "学习", contextText: "我们今天学习新词。")
    XCTAssertEqual(fields["spanStart"] as? Int, 4)
    XCTAssertEqual(fields["spanEnd"] as? Int, 6)
    XCTAssertEqual(fields["contextLanguage"] as? String, "zh-Hans")
    XCTAssertEqual(Set(fields.keys), ["spanStart", "spanEnd", "contextLanguage"])
  }

  func testUncomputableAxesAreABSENTNotPresentNull() {
    // Repeated unit → no span; mixed-script text → no language. The keys must not exist at all.
    let fields = ContextRequestAxes.previewPayloadFields(
      unit: "bow", contextText: "He gave a bow, then another bow.")
    XCTAssertTrue(fields.isEmpty)
  }

  func testUniqueLatinOccurrenceCarriesSpanButNoLanguage() {
    // "The cell divides rapidly." — "cell" at UTF-16 [4, 8); Latin text never pins a language.
    let fields = ContextRequestAxes.previewPayloadFields(
      unit: "cell", contextText: "The cell divides rapidly.")
    XCTAssertEqual(fields["spanStart"] as? Int, 4)
    XCTAssertEqual(fields["spanEnd"] as? Int, 8)
    XCTAssertNil(fields["contextLanguage"])
    XCTAssertEqual(Set(fields.keys), ["spanStart", "spanEnd"])
  }
}
