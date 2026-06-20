//
//  LanguageDetector.swift
//  capture_native
//
//  Pure logic: the dominant language of a piece of recognized text, via
//  `NLLanguageRecognizer`. NaturalLanguage-only, separated for testability
//  (../../capture_native_logic). No `import Vision`, no Flutter.
//
//  Used on the cursor's visual span to label what language the user is reading
//  (the Phase-2 unit-language confirm: suggest switching the capture target when a
//  SAME-script passage isn't the learning target). It is a HINT the shared core
//  reads, never a decision it makes — the saved unit's `target_language` stays the
//  user's explicit choice (auto-switching it is barred except on the deterministic,
//  script-disjoint path, which doesn't use this detector).
//

import Foundation
import NaturalLanguage

enum LanguageDetector {

  /// The dominant BCP-47 language code (`NLLanguage.rawValue`, e.g. "en", "es",
  /// "zh-Hans") for [text] plus its [0,1] confidence, or nil for empty /
  /// unrecognizable text. The single-hypothesis probability is reported as the
  /// confidence. Sentence-length input (a visual span) detects far more reliably
  /// than a bare word, which is why the span — not the lone unit — is fed here.
  static func detect(_ text: String) -> (language: String, confidence: Double)? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(trimmed)
    guard let dominant = recognizer.dominantLanguage else { return nil }
    let confidence = recognizer.languageHypotheses(withMaximum: 1)[dominant] ?? 0
    return (dominant.rawValue, confidence)
  }
}
