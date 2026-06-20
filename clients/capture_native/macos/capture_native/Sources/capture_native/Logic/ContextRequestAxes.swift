//
//  ContextRequestAxes.swift
//  capture_native
//
//  The two optional context-layer request axes — the unit's span and the text's
//  script-certain language — computed on the CURRENT (possibly user-edited) text.
//  Pure logic, separated from CaptureNativePlugin for the same reason as
//  UnitSpanResolver: the plugin glue imports FlutterMacOS and can't run under
//  `swift test`, but the axes RULES (and the payload KEY SPELLINGS, which must
//  byte-match the Dart `OverlayContextPreviewRequest.fromMap` keys) are exactly
//  the line class a review flagged as untestable — so they live here, symlinked
//  into ../../capture_native_logic and pinned by ContextRequestAxesTests.
//

import Foundation

enum ContextRequestAxes {
  /// The script-certain language of [text], or nil — the Save path's `context_language`
  /// stamp (never defaulted to the target: the unit's language and the sentence's
  /// genuinely diverge, e.g. a zh unit captured inside an English article).
  static func contextLanguage(of text: String?) -> String? {
    guard let text else { return nil }
    return UnitLanguage.scriptCertainLanguage(text)
  }

  /// The preview request's optional axes as method-channel payload fields, ABSENT when
  /// uncomputable (absent ≠ present-null is the bridge contract): the unit's UTF-16
  /// span when it occurs exactly once (`UnitSpanResolver` — nil on a repeat, so the
  /// backend never marks a guessed occurrence) + the script-certain context language.
  static func previewPayloadFields(unit: String, contextText: String) -> [String: Any] {
    var fields: [String: Any] = [:]
    if let span = UnitSpanResolver.span(unit: unit, in: contextText) {
      fields["spanStart"] = span.start
      fields["spanEnd"] = span.end
    }
    if let language = UnitLanguage.scriptCertainLanguage(contextText) {
      fields["contextLanguage"] = language
    }
    return fields
  }
}
