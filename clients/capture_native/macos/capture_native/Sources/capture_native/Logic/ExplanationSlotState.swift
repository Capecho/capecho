//
//  ExplanationSlotState.swift
//  capture_native
//
//  The overlay's explanation-slot state machine + view-model — pure logic,
//  separated for testability. Extracted from CaptureOverlay.swift so the
//  contract can be exercised by a Flutter-free Swift test target
//  (../../capture_native_logic). Foundation-only; no AppKit, no I/O.
//

import Foundation

// MARK: - Explanation view-model (per-POS senses, grouped by reading)

/// One DISPLAY-READY pronunciation part: its target-profile label ([label] — "US"; nil = unlabeled,
/// e.g. pinyin) and the already-decorated [display] text ("/ˈɑbdʒɛkt/", "xíng"). Both are computed
/// DART-side from the target profile (capecho_app_core `pronunciationParts`) — the native renderer
/// shows them verbatim and never hard-codes an accent label or slash policy.
struct OverlayPronunciation: Equatable {
  let label: String?
  let display: String
}

/// One part-of-speech row under a reading: the POS label + all its senses + a shared form note. The
/// layout (senses, note, the card-level hint) is computed DART-side (capecho_app_core
/// `computeSenseLayout`) and bridged ready-to-render, so this stays presentational — the native side
/// never re-derives the layout rules (the same "Dart computes, Swift renders verbatim" contract as
/// the pronunciation parts).
struct OverlayPosRow: Equatable {
  let partOfSpeech: String
  let senses: [String]

  /// A form note shared by every sense (e.g. "make 的现在分词"), pulled out Dart-side so it shows ONCE
  /// at the front of the row instead of repeating on each sense. Empty when there is none.
  let note: String

  /// The standard dictionary label for this POS (e.g. "adjective" → "adj.").
  var label: String { OverlayPosRow.abbreviatePos(partOfSpeech) }

  /// The standard dictionary label for a POS — 3-4 letter tokens, never single-letter (founder call:
  /// "noun"/"verb" stay full words, "adjective" → "adj.", the convention learner's dictionaries use).
  /// The backend always emits closed-set ENGLISH POS labels whatever the gloss language (prompt
  /// contract; @capecho/lang POS_LABELS), so this map is English-only; an unknown label passes
  /// through unchanged (lowercased) rather than guessing an abbreviation.
  static func abbreviatePos(_ pos: String) -> String {
    let table: [String: String] = [
      "noun": "noun", "verb": "verb", "adjective": "adj.", "adverb": "adv.",
      "phrasal verb": "phr. verb", "preposition": "prep.", "pronoun": "pron.",
      "conjunction": "conj.", "interjection": "interj.", "determiner": "det.",
      "particle": "part.", "measure word": "meas.", "idiom": "idiom", "phrase": "phrase",
    ]
    let key = pos.trimmingCharacters(in: .whitespaces).lowercased()
    return table[key] ?? key
  }
}

/// One pronunciation reading: its display-ready [pronunciations] (0..2; omit-on-failed slots absent),
/// whether it is an [isIdiom] phrase (a badge replaces the IPA), and the per-POS [pos] rows (each
/// with its meanings). A heteronym ("object", "record") is several readings, each rendered as its own
/// block.
struct OverlayReading: Equatable {
  let pronunciations: [OverlayPronunciation]
  let isIdiom: Bool
  let pos: [OverlayPosRow]
  var hasPronunciation: Bool { !pronunciations.isEmpty }
}

/// The word explanation the overlay renders: per-reading blocks of per-POS sense rows. Derived ONCE
/// from the bridge payload by `from(...)`, which is pure + unit-tested. The senses ARE the
/// explanation, and every sense is shown (no cap, no "more" hint — the region scrolls if tall).
struct OverlayExplanation: Equatable {
  let readings: [OverlayReading]

  /// Derive the overlay view-model from the bridge payload. PURE (same input → same output, no I/O).
  /// Drops blank senses, empty POS groups, and readings with nothing to show; returns nil when NO
  /// sense survives anywhere (caller shows `.failed` — a sense-less blob is unusable; MUST-PASS core).
  static func from(
    readings rawReadings: [(
      pronunciations: [(label: String?, display: String)], isIdiom: Bool,
      pos: [(partOfSpeech: String, senses: [String], note: String)]
    )]
  ) -> OverlayExplanation? {
    var readings: [OverlayReading] = []
    var anySense = false
    for r in rawReadings {
      let pronunciations = r.pronunciations
        .filter { !$0.display.trimmingCharacters(in: .whitespaces).isEmpty }
        .map { OverlayPronunciation(label: $0.label, display: $0.display) }
      var posRows: [OverlayPosRow] = []
      for g in r.pos {
        let senses = g.senses
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
        guard !senses.isEmpty,
          !g.partOfSpeech.trimmingCharacters(in: .whitespaces).isEmpty
        else { continue }
        anySense = true
        posRows.append(
          OverlayPosRow(
            partOfSpeech: g.partOfSpeech, senses: senses,
            note: g.note.trimmingCharacters(in: .whitespacesAndNewlines)))
      }
      guard !posRows.isEmpty else { continue }  // a reading with no renderable sense is not a block
      readings.append(
        OverlayReading(pronunciations: pronunciations, isIdiom: r.isIdiom, pos: posRows))
    }
    guard anySense else { return nil }  // MUST-PASS: at least one sense survived
    return OverlayExplanation(readings: readings)
  }
}

// MARK: - In-context preview slot (E2)

/// The opt-in in-context explanation PREVIEW result shown below the ready card's actions row (E2). A
/// calm sub-state of the ready slot: the user taps "Explain in this sentence", sees a spinner, then the
/// in-context gloss — or a quota / failure note. Pure data; the overlay renders it, the host drives it.
enum ContextPreviewSlot: Equatable {
  /// Nothing requested — reset on each new capture + each fresh `/explain` (no stale gloss lingers).
  case idle
  /// The metered `POST /explain/context/preview` is in flight.
  case loading
  /// The in-context gloss resolved — one combined explanation: the unit's meaning here AND what the
  /// whole sentence is saying.
  case ready(meaning: String)
  /// The shared daily context-explanation cap is spent.
  case quotaExhausted
  /// The preview is account-only and the caller is signed out (or the session expired) — a calm prompt
  /// to sign in for the free daily allowance; the word still saves either way.
  case needsLogin
  /// The generation failed or was refused — calm; the word still saves.
  case failed
}

// MARK: - Explanation slot state (pure logic, separated for testability)

/// The state of the overlay's explanation slot — the region between the form
/// (UNIT/CONTEXT) and the footer that hosts the free explanation + POS chip.
///
/// The client holds NO target allowlist: every capture requests `/explain`, and
/// the SERVER's `language_unsupported` status drives `.langUnsupported` (via the
/// bridge phase `lang_unsupported`). The slot shows the calm, future-framed
/// *"no explanation for this language yet — you can still save, review, and
/// export this word"* note. The resting state before any push is `.hidden`.
enum ExplanationSlotState: Equatable {
  case hidden
  case langUnsupported
  /// The `/explain` fetch is in flight.
  case loading
  /// The free word-layer explanation resolved. Carries the reading-centric view-model: one
  /// `US /…/ · pos` line per reading.
  case ready(OverlayExplanation)
  /// The fetch failed or returned no explanation — a calm note; the word still saves and the Word Book
  /// fetches the meaning later.
  case failed
  /// The captured unit isn't a word — pure punctuation/number/URL, or a single-token keyboard-mash /
  /// repeated-key string ("asdfgh", "aaaa"). Caught locally before any `/explain` call (the host's junk
  /// + gibberish gates); a calm note. The capture still SAVES (照常入库、仅不查) — the user can delete it
  /// from the Word Book. No Retry: re-asking won't turn a non-word into a word.
  case notAWord
}
