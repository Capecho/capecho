//
//  WordSegmenter.swift
//  capture_native
//
//  Pure logic: system word boundaries for OCR text, via `NLTokenizer`.
//  The native adapter emits these ranges as platform-neutral `wordRuns` so the
//  shared Dart core uses the OS word-boundary engine for every script instead
//  of maintaining a regex tokenizer. Windows should emit the same shape from
//  its own word-boundary API later.
//

import Foundation
import NaturalLanguage

struct WordSegment {
  let utf16Start: Int
  let utf16End: Int
  let text: String
}

enum WordSegmenter {
  static func segments(in text: String) -> [WordSegment] {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return []
    }

    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text

    var segments: [WordSegment] = []
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      let token = String(text[range])
      guard containsWordScalar(token) else { return true }

      let nsRange = NSRange(range, in: text)
      guard nsRange.location != NSNotFound, nsRange.length > 0 else { return true }

      segments.append(WordSegment(
        utf16Start: nsRange.location,
        utf16End: nsRange.location + nsRange.length,
        text: token
      ))
      return true
    }
    return segments
  }

  private static func containsWordScalar(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
  }
}
