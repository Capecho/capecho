import 'geometry.dart';
import 'ocr_snapshot.dart';

/// Word tokenization + per-token geometry consumed from native OCR adapters.
///
/// The OCR bridge carries native [OcrWordRun] records for hover tokenization —
/// the OS word boundary is authoritative, so there is no regex fallback. The
/// proportional geometry helpers below remain for selection sub-line extraction
/// and test fixtures (CJK / full-width characters weighted 2x, as those glyphs
/// render wider than Latin). [isHanRun] / [hanCharCount] remain too — they feed
/// the selection cut-through guard and the Chinese sentence-length heuristic.

/// A tokenized word within a line, with its estimated normalized box.
///
/// Mirrors the spike's `OCRToken` (see `ScreenOCRModels.swift` lines 60-65),
/// minus the Swift `Range<String.Index>`; instead we keep the token's UTF-16
/// [utf16Start]/[utf16Length] within its source line (`OcrLine.text`), which is
/// what `cursorOffset` needs (the Swift code used `NSRange(token.range, …)`,
/// i.e. UTF-16 offsets, and Dart `String` is already UTF-16).
class OcrToken {
  final String text;
  final int lineIndex;

  /// UTF-16 offset of this token within its source line's text.
  final int utf16Start;

  /// UTF-16 length of this token within its source line's text.
  final int utf16Length;

  final NormRect box;

  const OcrToken({
    required this.text,
    required this.lineIndex,
    required this.utf16Start,
    required this.utf16Length,
    required this.box,
  });

  @override
  String toString() => 'OcrToken("$text", line: $lineIndex, $box)';
}

/// Native word-run adapter + proportional box estimator.
class Tokenizer {
  const Tokenizer();

  /// Whether [text] is a non-empty run of CJK ideographs ONLY — exactly the
  /// BMP ranges Vision commonly returns for Chinese OCR text.
  ///
  /// Used by script-aware capture heuristics. Deliberately excludes kana /
  /// Hangul because those scripts should not count toward Chinese sentence
  /// length heuristics.
  static bool isHanRun(String text) {
    if (text.isEmpty) return false;
    for (final unit in text.codeUnits) {
      if (!_isHanUnit(unit)) return false;
    }
    return true;
  }

  /// One UTF-16 code unit is a CJK ideograph (the BMP ranges above; one code
  /// unit per character). The single source of the range numbers for both
  /// [isHanRun] and [hanCharCount].
  static bool _isHanUnit(int unit) =>
      (unit >= 0x3400 && unit <= 0x4DBF) || // CJK Extension A
      (unit >= 0x4E00 && unit <= 0x9FFF) || // CJK Unified Ideographs
      (unit >= 0xF900 && unit <= 0xFAFF); // CJK Compatibility Ideographs

  /// How many CJK ideographs are in [text]. CJK has no inter-word spaces, so the
  /// sentence heuristic ([looksLikeSentence]) counts ideographs instead of
  /// whitespace words to tell a 词组 ("学习") from a full sentence ("我在学习中文。").
  static int hanCharCount(String text) {
    var n = 0;
    for (final unit in text.codeUnits) {
      if (_isHanUnit(unit)) n++;
    }
    return n;
  }

  /// Builds tokens for a single line from native system word-boundary hints.
  /// macOS supplies these with `NLTokenizer(unit: .word)`. There is deliberately
  /// no regex fallback here: if the system boundary is imperfect, the user can
  /// edit the captured unit.
  List<OcrToken> tokensForLine(
    String text,
    int lineIndex,
    NormRect lineBox, {
    List<OcrWordRun> wordRuns = const [],
  }) {
    return _nativeTokensForLine(text, lineIndex, wordRuns);
  }

  List<OcrToken> _nativeTokensForLine(
    String text,
    int lineIndex,
    List<OcrWordRun> wordRuns,
  ) {
    if (wordRuns.isEmpty) {
      return const [];
    }

    final tokens = <OcrToken>[];
    for (final run in wordRuns) {
      final length = run.utf16End - run.utf16Start;
      if (length <= 0 || run.utf16Start < 0 || run.utf16End > text.length) {
        continue;
      }
      final tokenText = _substring(text, run.utf16Start, run.utf16End);
      if (tokenText.isEmpty || !_looksLikeWordToken(tokenText)) {
        continue;
      }
      tokens.add(OcrToken(
        text: tokenText,
        lineIndex: lineIndex,
        utf16Start: run.utf16Start,
        utf16Length: length,
        box: run.box,
      ));
    }
    tokens.sort((a, b) => a.utf16Start.compareTo(b.utf16Start));
    return tokens;
  }

  static final RegExp _wordTokenChar = RegExp(r'[\p{L}\p{M}\p{N}]', unicode: true);

  bool _looksLikeWordToken(String text) => _wordTokenChar.hasMatch(text);

  String _substring(String text, int utf16Start, int utf16End) {
    final start = utf16Start.clamp(0, text.length).toInt();
    final end = utf16End.clamp(start, text.length).toInt();
    return text.substring(start, end);
  }

  /// Turn the adapter's raw [charBoxes] into genuinely per-character boxes.
  ///
  /// macOS Vision's `boundingBox(for:)` returns the box of the whole
  /// WHITESPACE-DELIMITED WORD for EVERY character in it — every char of
  /// "notation" shares one box; every char of "flutter_tts," shares one box
  /// (verified empirically). When the platform word-boundary engine splits
  /// inside that Vision word — "flutter_tts" → "flutter"+"tts",
  /// "heteronym-correct)" → "heteronym"+"correct" — every sub-token would
  /// otherwise share the SAME box.
  ///
  /// Refinement spreads each maximal run of EQUAL non-empty boxes (one Vision
  /// word) proportionally across its characters — CJK/full-width weighted 2x,
  /// the same width model as the estimate — so each split token gets its own
  /// horizontal slice of the word. It is a no-op when boxes are already distinct
  /// (an adapter that emits true per-character geometry) or absent, and is
  /// idempotent. Separator gaps (zero boxes, e.g. spaces) are left untouched.
  /// Returns the input unchanged if it can't be aligned to [text].
  List<NormRect>? refineCharBoxes(String text, List<NormRect>? charBoxes) {
    if (charBoxes == null) return null;
    final units = text.codeUnits;
    if (charBoxes.length != units.length) return charBoxes; // misaligned: as-is
    final refined = List<NormRect>.of(charBoxes);
    var i = 0;
    while (i < charBoxes.length) {
      final box = charBoxes[i];
      if (box.isEmpty) {
        i++; // separator (space) — not part of any word/token
        continue;
      }
      // The maximal run of characters sharing this exact box = one Vision word.
      var j = i + 1;
      while (j < charBoxes.length && _sameBox(charBoxes[j], box)) {
        j++;
      }
      if (j - i > 1) {
        final total = _weight(units, i, j);
        if (total > 0) {
          var acc = 0.0;
          for (var k = i; k < j; k++) {
            final w = _weight(units, k, k + 1);
            final startX = box.minX + box.width * (acc / total);
            final endX = box.minX + box.width * ((acc + w) / total);
            refined[k] = NormRect(startX, box.minY, endX - startX, box.height);
            acc += w;
          }
        }
      }
      i = j;
    }
    return refined;
  }

  /// Whether two boxes are the same Vision word-box (equal horizontal extent
  /// within a float epsilon). Only x matters for word grouping; separator gaps
  /// are zero-size and excluded by the [NormRect.isEmpty] check at the call site.
  bool _sameBox(NormRect a, NormRect b) {
    const eps = 1e-6;
    return (a.minX - b.minX).abs() < eps && (a.maxX - b.maxX).abs() < eps;
  }

  /// The normalized box of the token at `[utf16Start, utf16Start+utf16Length)`
  /// within [text].
  ///
  /// ACCURATE PATH: when [charBoxes] carries the OCR engine's real per-character
  /// geometry (one entry per UTF-16 code unit, see [OcrLine.charBoxes]), the
  /// token's box is the UNION of its glyphs' boxes — the horizontal extent from
  /// the real glyphs, the vertical extent (y/height) kept from [lineBox]. Taking
  /// only x/width from glyphs is deliberate: the fix is horizontal targeting, so
  /// the line's vertical band stays identical to the proportional model and the
  /// line/token inset-containment checks behave unchanged. This is what keeps
  /// cursor→token targeting from drifting onto the previous word on
  /// proportional-width fonts. Returns to the estimate below if [charBoxes] is
  /// absent, the range is out of bounds, or any covered glyph is a zero-size gap.
  ///
  /// PROPORTIONAL FALLBACK (port of ScreenOCRService.proportionalBoundingBox,
  /// ScreenOCRService.swift lines 239-255), extended with the CJK / full-width
  /// 2x width weighting that the spike documented as its mixed-script fix.
  ///
  /// The Swift original measured position as a ratio of raw UTF-16 character
  /// COUNT:
  ///   startRatio = nsRange.location / totalLength
  ///   widthRatio = nsRange.length   / totalLength
  /// Here we replace the raw count with a WEIGHTED count where each CJK /
  /// full-width code unit counts as 2 and every other code unit counts as 1, so
  /// a half-Latin / half-Han line apportions horizontal space the way it
  /// actually renders. This is only a guess (it assumes uniform per-weight
  /// advance widths); the accurate path above supersedes it when glyph geometry
  /// is available.
  NormRect tokenBoundingBox(
    String text,
    int utf16Start,
    int utf16Length,
    NormRect lineBox, {
    List<NormRect>? charBoxes,
  }) {
    final accurate = _accurateTokenBox(charBoxes, utf16Start, utf16Length, lineBox);
    if (accurate != null) return accurate;

    final units = text.codeUnits;
    // total weighted "width units" of the whole line, min 1 (matches Swift's
    // `max(totalLength, 1)`).
    final double totalWeight = _weight(units, 0, units.length).clamp(1.0, double.infinity);
    final double startWeight = _weight(units, 0, utf16Start);
    final double tokenWeight = _weight(units, utf16Start, utf16Start + utf16Length);

    final startRatio = startWeight / totalWeight;
    final widthRatio = tokenWeight / totalWeight;

    return NormRect(
      lineBox.minX + lineBox.width * startRatio,
      lineBox.minY,
      lineBox.width * widthRatio,
      lineBox.height,
    );
  }

  /// The accurate token box from real glyph geometry: the horizontal union of
  /// [charBoxes] over `[utf16Start, utf16Start+utf16Length)`, with the vertical
  /// extent kept from [lineBox]. Returns null — signalling the proportional
  /// fallback — when [charBoxes] is null, the range is empty / out of bounds, or
  /// any covered glyph is a zero-size gap the engine couldn't box (a partial
  /// estimate would be worse than the uniform one). A non-BMP glyph's box is
  /// repeated across its two surrogate code units, so unioning the raw UTF-16
  /// range is correct without special-casing surrogates.
  NormRect? _accurateTokenBox(
    List<NormRect>? charBoxes,
    int utf16Start,
    int utf16Length,
    NormRect lineBox,
  ) {
    if (charBoxes == null || utf16Length <= 0) return null;
    final end = utf16Start + utf16Length;
    if (utf16Start < 0 || end > charBoxes.length) return null;

    var minX = double.infinity;
    var maxX = double.negativeInfinity;
    for (var i = utf16Start; i < end; i++) {
      final b = charBoxes[i];
      if (b.isEmpty) return null; // per-glyph gap → fall back for this token
      if (b.minX < minX) minX = b.minX;
      if (b.maxX > maxX) maxX = b.maxX;
    }
    if (!(maxX > minX)) return null;
    return NormRect(minX, lineBox.minY, maxX - minX, lineBox.height);
  }

  /// Weighted count of code units in [units] over [from, to): CJK / full-width
  /// units count 2, everything else counts 1.
  double _weight(List<int> units, int from, int to) {
    var sum = 0.0;
    final end = to < units.length ? to : units.length;
    for (var i = from < 0 ? 0 : from; i < end; i++) {
      sum += _isWideCodeUnit(units[i]) ? 2.0 : 1.0;
    }
    return sum;
  }

  /// Whether a UTF-16 code unit renders roughly double-width: CJK ideographs,
  /// CJK symbols/punctuation, hiragana/katakana, Hangul, and the full-width /
  /// half-width forms block. (BMP ranges; high surrogates are treated as
  /// single-weight, which is acceptable for the coarse proportional estimate.)
  bool _isWideCodeUnit(int u) {
    return (u >= 0x1100 && u <= 0x115F) || // Hangul Jamo
        (u >= 0x2E80 && u <= 0x303E) || // CJK radicals, Kangxi, CJK symbols/punct
        (u >= 0x3041 && u <= 0x33FF) || // Hiragana, Katakana, CJK compatibility
        (u >= 0x3400 && u <= 0x4DBF) || // CJK Extension A
        (u >= 0x4E00 && u <= 0x9FFF) || // CJK Unified Ideographs
        (u >= 0xA000 && u <= 0xA4CF) || // Yi
        (u >= 0xAC00 && u <= 0xD7A3) || // Hangul Syllables
        (u >= 0xF900 && u <= 0xFAFF) || // CJK Compatibility Ideographs
        (u >= 0xFE30 && u <= 0xFE4F) || // CJK Compatibility Forms
        (u >= 0xFF00 && u <= 0xFF60) || // Full-width forms
        (u >= 0xFFE0 && u <= 0xFFE6); // Full-width signs
  }
}
