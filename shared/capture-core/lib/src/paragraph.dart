import 'geometry.dart';
import 'ocr_snapshot.dart';
import 'tokenizer.dart';

/// Geometric paragraph reconstruction + flow-text assembly.
///
/// Originally a port of the paragraph/flow functions in ScreenOCRService.swift
/// (paragraphLineIndices, sameColumn, isBlockBreak, differentTextSize,
/// startsNewBlock, endsWithTerminator, flowText, cursorOffset,
/// comesBeforeInReadingOrder, and the cleaned / hyphen / leading-whitespace
/// helpers).
///
/// PARAGRAPH GROUPING DIVERGES from that port to follow the standard
/// document-layout-analysis approach (XY-cut / Docstrum family, and what
/// pdfplumber / PyMuPDF / Tesseract use in practice): a paragraph break is a
/// LINE-SPACING jump relative to the column's typical spacing, a FONT-SIZE
/// change, or a fresh INDENT — NOT line "fullness". The spike broke a paragraph
/// whenever a line failed to reach the right margin, which wrongly split
/// left-aligned / ragged-right prose (most web + news text) and truncated the
/// captured sentence. See [_isBlockBreak].
///
/// Coordinates are normalized, BOTTOM-LEFT origin, y up (Vision convention), so
/// "top of screen" == higher y.

/// port of ScreenOCRModels.OCRLineSpan (ScreenOCRModels.swift lines 67-76):
/// where one source OCR line lands inside the reconstructed flowing text.
class OcrLineSpan {
  /// UTF-16 offset where this line's cleaned text starts in the paragraph.
  final int start;

  /// UTF-16 length of this line's cleaned text within the paragraph.
  final int cleanedLength;

  /// Leading whitespace stripped from the raw line, used to realign offsets.
  final int leadingWhitespace;

  const OcrLineSpan({
    required this.start,
    required this.cleanedLength,
    required this.leadingWhitespace,
  });
}

/// The flowing-paragraph text plus the per-line spans into it.
class FlowText {
  final String text;
  final Map<int, OcrLineSpan> spans;
  const FlowText(this.text, this.spans);
}

class ParagraphReconstructor {
  const ParagraphReconstructor();

  // ---- Paragraph reconstruction thresholds ----
  // Column membership keeps the spike's alignment/overlap tolerances; the
  // paragraph-break signals (below) follow the standard line-spacing + font-size
  // + indent approach rather than the spike's line-"fullness" test.
  static const String _compoundSeparators = '-_‐‑‒–—';
  static const double _columnLeftAlignTolerance = 0.035;
  static const double _columnOverlapRatio = 0.6;
  // LINE-SPACING is the PRIMARY block signal (cleaner than box height — see
  // [_isBlockBreak]). The block's own leading is estimated from the gaps around
  // the seed; a break is a gap beyond that leading + this fraction of a line of
  // EXTRA whitespace. Judging against the LOCAL leading (not a fixed line-height
  // multiple) adapts to tight OR loose layouts. Real Vision data (BBC,
  // capture-debug.jsonl 2026-06-05): intra-line gaps ~0.1–0.2× line height, a
  // heading↔body boundary ~0.45× — cleanly separated.
  static const double _spacingExtraGapFactor = 0.25;
  // Gaps each side of the seed used to estimate the block's leading (median).
  static const int _localLeadingWindow = 3;
  // A gap ≥ this many line-heights is a hard break regardless — the backstop for
  // a tiny column where the local leading can't be estimated (it IS the gap).
  static const double _hugeGapFactor = 1.0;
  static const double _paragraphIndentThreshold = 0.025;
  // FONT-SIZE is the SECONDARY (backup) vote — box height is noisier than line
  // spacing (real Vision data: same-size body lines vary up to ~1.16× from
  // ascender/descender composition, while a heading box is ~1.28×, so the
  // [1.16,1.28] window is narrow). 1.2 sits in it. Useful mainly when a heading
  // shares the body's leading (so the spacing signal can't see it).
  static const double _blockHeightRatioThreshold = 1.2;

  /// port of ScreenOCRService.comesBeforeInReadingOrder (ScreenOCRService.swift
  /// lines 538-544). Returns true when `a` reads before `b`. In Vision space
  /// (y up), the higher-y (top of screen) line comes first; ties within 0.015
  /// fall back to left-to-right.
  static bool comesBeforeInReadingOrder(NormRect a, NormRect b) {
    final yDelta = (a.midY - b.midY).abs();
    if (yDelta > 0.015) {
      return a.midY > b.midY;
    }
    return a.minX < b.minX;
  }

  /// Stable reading-order sort of [lines], returning the permutation of
  /// original indices in reading order. Mirrors Swift's `sorted` using
  /// `comesBeforeInReadingOrder`.
  static List<int> readingOrder(List<OcrLine> lines) {
    final indices = List<int>.generate(lines.length, (i) => i);
    // Comparator from the strict "comes before" predicate. Dart's List.sort is
    // not guaranteed stable, but the predicate is a total order on distinct
    // boxes; ties (identical geometry) are inconsequential here.
    indices.sort((i, j) {
      final a = lines[i].box;
      final b = lines[j].box;
      if (comesBeforeInReadingOrder(a, b)) return -1;
      if (comesBeforeInReadingOrder(b, a)) return 1;
      return 0;
    });
    return indices;
  }

  /// The line indices of the paragraph containing [seed], ordered top→bottom.
  ///
  /// NATIVE LAYOUT HINT first: when the adapter tagged lines with an
  /// [OcrLine.paragraphId] (macOS 26+ `RecognizeDocumentsRequest`), the
  /// paragraph IS the set of lines sharing the seed's id — the platform's trained
  /// layout model, returned directly with no geometric heuristic. Otherwise it
  /// grows the paragraph geometrically: walking the seed's column (sorted
  /// top→bottom) outward while [_isBlockBreak] is false (line-spacing + font-size
  /// + indent). The geometric path is the fallback for older macOS + Windows.
  List<int> paragraphLineIndices(int seed, List<OcrLine> lines) {
    // Native paragraph grouping — trust the platform model when present.
    final seedPara = lines[seed].paragraphId;
    if (seedPara != null) {
      final members = <int>[
        for (var i = 0; i < lines.length; i++)
          if (lines[i].paragraphId == seedPara) i,
      ]..sort((a, b) {
          // Reading order (top→bottom, then left→right on a y-tie) — same total
          // order [flowText] assembles in. Dart's sort is unstable, so a bespoke
          // midY-only comparator could flow same-row lines out of order.
          if (comesBeforeInReadingOrder(lines[a].box, lines[b].box)) return -1;
          if (comesBeforeInReadingOrder(lines[b].box, lines[a].box)) return 1;
          return 0;
        });
      // members always contains seed; guard against an empty result anyway.
      return members.isEmpty ? [seed] : members;
    }

    final seedBox = lines[seed].box;

    final column = <int>[
      for (var i = 0; i < lines.length; i++)
        if (_sameColumn(lines[i].box, seedBox)) i,
    ]..sort((a, b) {
        // sorted { midY(a) > midY(b) }  (descending midY)
        final ay = lines[a].box.midY;
        final by = lines[b].box.midY;
        if (ay > by) return -1;
        if (ay < by) return 1;
        return 0;
      });

    final seedPosition = column.indexOf(seed);
    if (seedPosition < 0) {
      return [seed];
    }

    // The block's own line spacing (leading), estimated from the gaps AROUND the
    // seed — the reference a gap must clearly exceed to be a paragraph / heading
    // break. Local (not column-wide) so a dense list of short articles can't
    // inflate it, and median so a boundary gap or two in the window don't either.
    final localLeading = _localLeading(column, lines, seedPosition);

    var lower = seedPosition;
    var upper = seedPosition;

    while (upper + 1 < column.length &&
        !_isBlockBreak(
          lines[column[upper]],
          lines[column[upper + 1]],
          localLeading,
        )) {
      upper += 1;
    }

    while (lower - 1 >= 0 &&
        !_isBlockBreak(
          lines[column[lower - 1]],
          lines[column[lower]],
          localLeading,
        )) {
      lower -= 1;
    }

    return column.sublist(lower, upper + 1);
  }

  /// Whether the boundary between two vertically-adjacent same-column lines is a
  /// block / paragraph break rather than a prose wrap.
  ///
  /// LINE SPACING is the PRIMARY signal: a gap beyond the block's own
  /// [localLeading] by more than [_spacingExtraGapFactor] of a line of extra
  /// whitespace (or a [_hugeGapFactor]-line absolute gap). Judging against the
  /// LOCAL leading adapts to tight OR loose layouts, and it is far cleaner than
  /// box height — in real Vision output a heading↔body GAP is ~4× the intra-line
  /// gap, while heading vs body box HEIGHTS overlap (descenders swing height up
  /// to ~1.16× within one paragraph). FONT SIZE is only a secondary vote (catches
  /// a heading that shares the body's leading). Plus a fresh first-line INDENT.
  ///
  /// It deliberately does NOT test line "fullness" (whether [upper] reaches the
  /// right margin): most prose is left-aligned / ragged-right, so a short line is
  /// normal mid-paragraph, and treating it as a break split real sentences (the
  /// reported truncation on news / web text).
  bool _isBlockBreak(OcrLine upper, OcrLine lower, double localLeading) {
    final gap = upper.box.minY - lower.box.maxY;
    final lineHeight = _max3(upper.box.height, lower.box.height, 0.0001);

    // Overlap → not adjacent body lines.
    if (gap < -lineHeight * 0.5) return true;
    // LINE-SPACING jump (primary): beyond the block's own leading + a fraction of
    // a line of extra whitespace, OR a huge absolute gap (the tiny-column
    // backstop, where localLeading IS this gap so the adaptive test can't fire).
    if (gap > localLeading + lineHeight * _spacingExtraGapFactor) return true;
    if (gap > lineHeight * _hugeGapFactor) return true;
    // FONT-SIZE change (secondary vote) → a heading / caption boundary.
    if (_differentTextSize(upper.box, lower.box)) return true;
    // Fresh first-line indent after a finished sentence → new paragraph.
    if (_startsNewBlock(upper, lower)) return true;
    return false;
  }

  /// The block's line spacing (leading), estimated as the MEDIAN of the gaps in a
  /// ±[_localLeadingWindow] window around the seed. Local — so a dense column of
  /// short articles can't inflate it with inter-block gaps — and median, so the
  /// one or two boundary gaps that fall in the window don't either. The seed sits
  /// mid-block in the common case, so its neighbouring gaps are intra-line.
  double _localLeading(List<int> column, List<OcrLine> lines, int seedPos) {
    final lo = seedPos - _localLeadingWindow < 0 ? 0 : seedPos - _localLeadingWindow;
    final hi = seedPos + _localLeadingWindow >= column.length
        ? column.length - 1
        : seedPos + _localLeadingWindow;
    final gaps = <double>[
      for (var i = lo; i < hi; i++) lines[column[i]].box.minY - lines[column[i + 1]].box.maxY,
    ];
    return gaps.isEmpty ? 0 : _median(gaps);
  }

  /// Median of [values] (ascending). [values] is non-empty at every call site.
  double _median(List<double> values) {
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  /// port of ScreenOCRService.sameColumn (ScreenOCRService.swift lines
  /// 429-435).
  bool _sameColumn(NormRect a, NormRect b) {
    if ((a.minX - b.minX).abs() < _columnLeftAlignTolerance) {
      return true;
    }
    final overlap = _min(a.maxX, b.maxX) - _max(a.minX, b.minX);
    return overlap / _min(a.width, b.width) > _columnOverlapRatio;
  }

  /// port of ScreenOCRService.differentTextSize (ScreenOCRService.swift lines
  /// 437-444).
  bool _differentTextSize(NormRect a, NormRect b) {
    final larger = _max(a.height, b.height);
    final smaller = _min(a.height, b.height);
    if (!(smaller > 0)) return false;
    return larger / smaller > _blockHeightRatioThreshold;
  }

  /// port of ScreenOCRService.startsNewBlock (ScreenOCRService.swift lines
  /// 453-456).
  bool _startsNewBlock(OcrLine above, OcrLine below) {
    return below.box.minX - above.box.minX > _paragraphIndentThreshold &&
        _endsWithTerminator(above.text);
  }

  /// port of ScreenOCRService.flowText (ScreenOCRService.swift lines 461-486).
  /// Joins the paragraph's lines into one flowing string (line wraps → spaces,
  /// end-of-line hyphens kept and joined without a space) and records each
  /// source line's span. Offsets are UTF-16, as in the Swift NSString math.
  FlowText flowText(List<int> indices, List<OcrLine> lines) {
    var text = '';
    final spans = <int, OcrLineSpan>{};
    var previousEndedWithHyphen = false;

    for (var position = 0; position < indices.length; position++) {
      final lineIndex = indices[position];
      final rawLine = lines[lineIndex].text;
      final cleanedLine = cleaned(rawLine);

      if (position > 0 && !previousEndedWithHyphen) {
        text += ' ';
      }

      final start = text.length; // UTF-16 code-unit length, == NSString length
      text += cleanedLine;
      spans[lineIndex] = OcrLineSpan(
        start: start,
        cleanedLength: cleanedLine.length,
        leadingWhitespace: leadingWhitespaceCount(rawLine),
      );

      previousEndedWithHyphen = position < indices.length - 1 && _endsWithHyphen(cleanedLine);
    }

    return FlowText(text, spans);
  }

  /// Maps the selected token onto a character offset in the flowing text.
  ///
  /// DIVERGES (intentionally) from the spike's ScreenOCRService.cursorOffset
  /// (lines 491-504), which subtracted only the line's LEADING whitespace. That
  /// is wrong when a line contains INTERNAL whitespace runs, because [cleaned]
  /// collapses each run to a single space: the raw token offset then overshoots
  /// into a later word (e.g. "First.        Second. Third." targeting "Second"
  /// would land inside "Third"), capturing the wrong sentence/context. We instead
  /// map the raw offset through the SAME collapse rule applied to the line prefix
  /// [0, rawLocation), so it accounts for both leading and internal whitespace.
  int cursorOffset(
    OcrLineSpan lineSpan,
    int lineIndex,
    OcrToken? selectedToken,
    List<OcrLine> lines,
  ) {
    final token = selectedToken;
    if (token == null || token.lineIndex != lineIndex) {
      return lineSpan.start;
    }
    final rawLine = lines[lineIndex].text;
    final rawLocation = _minInt(_max(0, token.utf16Start.toDouble()).toInt(), rawLine.length);
    // Collapse the prefix exactly as cleaned() does: whitespace runs → one
    // space, and a single leading space (from a collapsed leading run) dropped
    // (cleaned()'s trim()).
    final collapsedPrefix = rawLine.substring(0, rawLocation).replaceAll(_whitespaceRun, ' ');
    final leading = collapsedPrefix.startsWith(' ') ? 1 : 0;
    final cleanedPrefixLength = collapsedPrefix.length - leading;
    return lineSpan.start + _minInt(cleanedPrefixLength, lineSpan.cleanedLength);
  }

  // ---- text helpers (verbatim ports) ----

  /// port of ScreenOCRService.cleaned (ScreenOCRService.swift lines 506-510).
  static final RegExp _whitespaceRun = RegExp(r'\s+');
  String cleaned(String text) => text.replaceAll(_whitespaceRun, ' ').trim();

  /// port of ScreenOCRService.leadingWhitespaceCount (ScreenOCRService.swift
  /// lines 512-521). Counts leading UTF-16 whitespace units of the raw line.
  int leadingWhitespaceCount(String text) {
    final units = text.codeUnits;
    var count = 0;
    while (count < units.length && _isWhitespaceUnit(units[count])) {
      count += 1;
    }
    return count;
  }

  /// port of ScreenOCRService.endsWithHyphen (ScreenOCRService.swift lines
  /// 523-528).
  bool _endsWithHyphen(String text) {
    if (text.isEmpty) return false;
    final last = text.runes.last;
    return _compoundSeparators.runes.contains(last);
  }

  /// port of ScreenOCRService.endsWithTerminator (ScreenOCRService.swift lines
  /// 530-536). Terminators set: . ! ? 。！？
  static const String _terminators = '.!?。！？';
  bool _endsWithTerminator(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    final last = trimmed.runes.last;
    return _terminators.runes.contains(last);
  }

  // CharacterSet.whitespacesAndNewlines analogue for UTF-16 units.
  bool _isWhitespaceUnit(int c) =>
      c == 0x20 ||
      c == 0x09 ||
      c == 0x0A ||
      c == 0x0B ||
      c == 0x0C ||
      c == 0x0D ||
      c == 0x85 || // NEL
      c == 0xA0 ||
      c == 0x2028 ||
      c == 0x2029 ||
      c == 0x3000;

  static double _min(double a, double b) => a < b ? a : b;
  static double _max(double a, double b) => a > b ? a : b;
  static int _minInt(int a, int b) => a < b ? a : b;
  static double _max3(double a, double b, double c) => _max(_max(a, b), c);
}
