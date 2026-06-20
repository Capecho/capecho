//
//  UnitLanguage.swift
//  capture_native
//
//  Pure logic: the captured unit's writing system → the effective capture target
//  language, plus the same-script "suggest a switch" decision. A native MIRROR of
//  the Dart `shared/capture-core/lib/src/unit_language.dart` (kept in parity by
//  UnitLanguageTests, which port that module's test cases verbatim).
//
//  Why a native copy: the overlay re-derives the target the MOMENT the unit
//  changes (a "set as word" promotion or an inline edit) so attribution follows
//  the word the user actually ends up with — and that must be synchronous (no
//  Dart round-trip) for the chip to update as you type/switch. The Dart copy still
//  runs at capture time (initial attribution + dedup + the alreadySaved check); this
//  one runs on every subsequent unit change inside the overlay.
//
//  The rule (identical to the Dart side): the configured learning language is the
//  default; it auto-switches to the unit's own language ONLY when the unit's script
//  is provably incompatible (a 中文/Han unit while learning English, or 한국어/kana) —
//  a deterministic 100%-certain "different language", never a probabilistic guess.
//  A SAME-script difference (English vs Spanish) is never certain from script alone,
//  so it stays on the configured target and is surfaced as a pre-save suggestion the
//  user confirms. The mapping is deterministic, so the dedup key stays stable.
//
//  No Flutter, NaturalLanguage, or Vision — just the script ranges + the language
//  map, so it lives in ../../capture_native_logic for `swift test`.
//

import Foundation

/// Writing systems distinguished for the capture-target decision.
enum UnitScript {
  case latin, han, kana, hangul, cyrillic, other
}

/// The captured unit's writing system → the effective capture target language, and
/// the same-script suggestion. Mirrors `unit_language.dart`.
enum UnitLanguage {

  /// The dominant writing system of [text]: the most language-identifying script
  /// present, scanned by code point, ignoring punctuation / digits / whitespace.
  ///
  /// Priority Hangul > Kana > Han > Cyrillic > Latin, so a Japanese unit carrying
  /// kana (勉強する) resolves to `.kana` (→ ja) despite its Han, and Korean to
  /// `.hangul`. A pure-Han unit is `.han` (defaulting to Chinese — kana/Hangul are
  /// what distinguish ja/ko). Empty / symbol-only text is `.other`.
  static func dominantScript(_ text: String) -> UnitScript {
    var hasHan = false
    var hasCyrillic = false
    var hasLatin = false
    for scalar in text.unicodeScalars {
      let r = scalar.value
      if isHangul(r) { return .hangul }
      if isKana(r) { return .kana }
      if isHan(r) {
        hasHan = true
      } else if isCyrillic(r) {
        hasCyrillic = true
      } else if isLatin(r) {
        hasLatin = true
      }
    }
    if hasHan { return .han }
    if hasCyrillic { return .cyrillic }
    if hasLatin { return .latin }
    return .other
  }

  /// The writing systems a BCP-47 learning-language tag is normally written in
  /// (matched on the primary subtag). Used to decide whether a captured unit's
  /// script is compatible with the learning language.
  static func scriptsOfLanguage(_ bcp47: String) -> Set<UnitScript> {
    switch primarySubtag(bcp47) {
    case "zh", "yue":
      return [.han]
    case "ja":
      return [.han, .kana]
    case "ko":
      return [.hangul]
    case "ru", "uk", "be", "bg", "sr", "mk":
      return [.cyrillic]
    default:
      // The learning-language set is Latin-script (en/es/de/it/fr/pt) plus zh-Hans
      // (handled above); an unknown tag is treated as Latin so a Han / Hangul / kana
      // unit still reads as "different" and auto-switches.
      return [.latin]
    }
  }

  /// The effective capture target for [unit]: the configured [learningLanguage],
  /// auto-switched to the unit's own language ONLY when the unit's script is provably
  /// incompatible with the learning language's (a deterministic "different language",
  /// never a probabilistic guess). Returns [learningLanguage] unchanged when the
  /// scripts are compatible, the unit is empty, or the disjoint unit's script doesn't
  /// pin a supported target (Latin → which language? deferred to the confirm prompt;
  /// Cyrillic / other → no supported target, stays on the configured language).
  static func effectiveTargetLanguage(unit: String, learningLanguage: String) -> String {
    let trimmed = unit.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return learningLanguage }
    let script = dominantScript(trimmed)
    if scriptsOfLanguage(learningLanguage).contains(script) { return learningLanguage }
    switch script {
    case .han:
      return "zh-Hans"
    case .kana:
      return "ja"
    case .hangul:
      return "ko"
    case .latin, .cyrillic, .other:
      return learningLanguage
    }
  }

  /// Targets the app can attribute a capture to + explain (the learning-language set
  /// plus the CJK targets the script auto-switch produces). A suggestion is only
  /// offered for one of these. Mirrors `unit_language.dart`'s `supportedTargetLanguages`.
  static let supportedTargetLanguages: Set<String> = [
    "en", "es", "de", "it", "fr", "pt", "zh-Hans", "ja", "ko",
  ]

  /// The minimum span-language confidence to surface a suggestion — a floor against
  /// noise, NOT an auto-switch bar (the suggestion is itself the pre-save confirm).
  static let suggestedTargetConfidenceGate = 0.65

  /// The capture target the overlay should SUGGEST switching to (a pre-save confirm,
  /// never auto-applied), or nil when no suggestion is warranted. Covers exactly the
  /// cases [effectiveTargetLanguage] does NOT auto-switch — where the difference isn't
  /// script-certain (a Spanish passage while learning English; a Latin word while
  /// learning Chinese). It offers the span's confidently detected language when (a)
  /// it's a supported target, (b) it differs from [effectiveTarget], and (c) that
  /// language can be written in the [unit]'s script — so a script-disjoint unit the
  /// auto-switch already attributed is never second-guessed (its English surrounding
  /// sentence won't drag a 中文 unit back to English).
  static func suggestedTargetLanguage(
    unit: String,
    effectiveTarget: String,
    spanLanguage: String?,
    spanLanguageConfidence: Double,
    confidenceGate: Double = suggestedTargetConfidenceGate
  ) -> String? {
    guard let detected = spanLanguage, !detected.isEmpty else { return nil }
    if spanLanguageConfidence < confidenceGate { return nil }
    if !supportedTargetLanguages.contains(detected) { return nil }
    if detected == effectiveTarget { return nil }
    if !scriptsOfLanguage(detected).contains(dominantScript(unit)) { return nil }
    return detected
  }

  /// The TEXT's language when its writing system alone makes it certain, else nil.
  ///
  /// The context-language axis for a captured sentence (sent on the preview request,
  /// stamped on the saved context): a language is named ONLY when the text is
  /// mono-script in a script that pins one — the same deterministic bar (and the same
  /// accepted Han→zh-Hans / kana→ja defaults) as [effectiveTargetLanguage]. A letter of
  /// ANY other script kills certainty — Latin/Cyrillic (which Latin language? and the
  /// normal capture — a zh unit inside an English article — is exactly such a mix), but
  /// equally Arabic, Thai, full-width Latin, …: one Han char must never "pin" zh-Hans
  /// on text that is mostly something else. Nil means the backend prompt says "the text
  /// below" and lets the model read the text — an absent label is always correct; a
  /// guessed one can be wrong. Mirrors `unit_language.dart`'s `scriptCertainLanguage`
  /// (keep the twins in parity).
  static func scriptCertainLanguage(_ text: String) -> String? {
    var han = false
    var kana = false
    var hangul = false
    for scalar in text.unicodeScalars {
      let r = scalar.value
      if isHangul(r) {
        hangul = true
      } else if isKana(r) {
        kana = true
      } else if isHan(r) || r == 0x3005 {
        // 々 (U+3005, the CJK iteration mark — 人々/山々) reads as Han here: it is a letter
        // (category Lm) outside the Han ranges, so without the carve-out it would hit the
        // any-other-letter branch and wrongly kill certainty for everyday zh/ja text.
        han = true
      } else if isOtherLetter(scalar) {
        return nil  // a letter of any non-pinning script — never certain
      }
    }
    if hangul { return kana ? nil : "ko" }  // Hangul pins Korean (rare hanja OK); +kana = nonsense mix
    if kana { return "ja" }  // kana pins Japanese (kanji OK)
    if han { return "zh-Hans" }  // pure Han: the same accepted default as the unit auto-switch
    return nil  // symbols / digits only
  }

  /// Unicode general category L* (any letter) — the same set Dart's `\p{L}` matches, spelled
  /// via generalCategory (NOT `properties.isAlphabetic`, which also covers Other_Alphabetic
  /// marks/symbols and would diverge from the Dart twin). Digits, punctuation, and marks are
  /// not letters and never affect certainty.
  private static func isOtherLetter(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
      return true
    default:
      return false
    }
  }

  private static func primarySubtag(_ tag: String) -> String {
    // omittingEmptySubsequences: false mirrors Dart's `tag.split('-').first` (Dart keeps
    // empty parts, so a leading-dash tag yields "" exactly as Dart would).
    String(tag.split(separator: "-", omittingEmptySubsequences: false).first ?? "").lowercased()
  }

  private static func isHan(_ r: UInt32) -> Bool {
    (r >= 0x4E00 && r <= 0x9FFF)  // CJK Unified Ideographs
      || (r >= 0x3400 && r <= 0x4DBF)  // Extension A
      || (r >= 0xF900 && r <= 0xFAFF)  // Compatibility Ideographs
      || (r >= 0x20000 && r <= 0x2A6DF)  // Extension B
  }

  private static func isKana(_ r: UInt32) -> Bool {
    (r >= 0x3040 && r <= 0x30FF)  // Hiragana + Katakana
      || (r >= 0xFF66 && r <= 0xFF9D)  // half-width Katakana
  }

  private static func isHangul(_ r: UInt32) -> Bool {
    (r >= 0xAC00 && r <= 0xD7A3)  // Hangul syllables
      || (r >= 0x1100 && r <= 0x11FF)  // Jamo
      || (r >= 0x3130 && r <= 0x318F)  // compatibility Jamo
  }

  private static func isCyrillic(_ r: UInt32) -> Bool {
    (r >= 0x0400 && r <= 0x04FF) || (r >= 0x0500 && r <= 0x052F)
  }

  private static func isLatin(_ r: UInt32) -> Bool {
    (r >= 0x41 && r <= 0x5A)  // A-Z
      || (r >= 0x61 && r <= 0x7A)  // a-z
      || (r >= 0x00C0 && r <= 0x024F)  // Latin-1 Supplement + Extended-A/B (accents)
  }
}
