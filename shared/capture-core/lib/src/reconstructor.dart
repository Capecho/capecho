import 'dart:math' as math;

import 'capture_result.dart';
import 'geometry.dart';
import 'ocr_snapshot.dart';
import 'paragraph.dart';
import 'sentence_context.dart';
import 'surface_unit.dart';
import 'text_shape.dart';
import 'tokenizer.dart';

/// The shared capture reconstruction pipeline: given a platform-neutral
/// [OcrSnapshot] it targets the token under the cursor, reconstructs the
/// paragraph/sentence/context (or uses the selection), and returns a
/// [CaptureResult].
///
/// port of the PURE portion of ScreenOCRService.recognizeWordAtMouse
/// (ScreenOCRService.swift lines 44-116) — everything after OCR/capture: the
/// reading-order sort, cursor→line→token targeting, the selection-vs-OCR
/// branch, and the learning-text assembly. The capture / Vision / NSScreen
/// parts stay native; this core consumes the [OcrSnapshot] the adapter emits.
///
/// All targeting thresholds (the inset margins, the hit-score weights
/// X*8 + Y*4 + center + width*0.05, the 0.035 / 0.06 nearest cutoffs) are
/// preserved VERBATIM from the Swift.
class CaptureReconstructor {
  const CaptureReconstructor();

  static const _tokenizer = Tokenizer();
  static const _paragraph = ParagraphReconstructor();

  CaptureResult reconstruct(OcrSnapshot snapshot) {
    final rawLines = snapshot.lines;

    // Degenerate: nothing recognized.
    if (rawLines.isEmpty) {
      return CaptureResult(
        word: null,
        line: null,
        sentence: null,
        context: '',
        recognizedLineCount: 0,
        screenName: snapshot.screenName,
        sourceApp: snapshot.sourceApp,
        sourceTitle: snapshot.sourceTitle,
        contextSource: CaptureContextSource.ocr,
        confidence: 0.0,
      );
    }

    // sortedLines: lines in reading order (port of the `recognized.sorted`
    // step, ScreenOCRService.swift lines 75-79).
    final order = ParagraphReconstructor.readingOrder(rawLines);
    final sortedLines = <OcrLine>[
      for (final i in order) rawLines[i],
    ];

    // tokens: rebuild per-line via the tokenizer (port of buildTokens, minus
    // the Vision plumbing — see tokenizer.dart). Tokens carry the index into
    // `sortedLines`.
    final tokens = <OcrToken>[];
    for (var li = 0; li < sortedLines.length; li++) {
      tokens.addAll(
        _tokenizer.tokensForLine(
          sortedLines[li].text,
          li,
          sortedLines[li].box,
          wordRuns: sortedLines[li].wordRuns,
        ),
      );
    }

    final cursor = snapshot.cursor;

    // selectedLineIndex = lineIndex(at:) ?? nearestLineIndex(to:)
    final selectedLineIndex =
        _lineIndexAt(cursor, sortedLines) ?? _nearestLineIndex(cursor, sortedLines);

    // selectedToken = token(at:) ?? nearestToken(lineIndex:) ?? nearestToken(nil)
    final selectedToken = _tokenAt(cursor, tokens, selectedLineIndex) ??
        _nearestToken(cursor, tokens, selectedLineIndex) ??
        _nearestToken(cursor, tokens, null);

    // Selection branch: if the user highlighted a passage, use the selection's
    // lines as the sentence directly (port of ScreenOCRService.swift lines
    // 92-103, with native highlight detection replaced by the bridged
    // `selectionRect`).
    //
    // The Swift used the highlight whenever the detector returned a rect and the
    // selected text was non-empty — there was NO cursor-containment re-test. The
    // native detector only emits a `selectionRect` when the cursor already sits
    // on a distinct highlight (it floods from the cursor pixel), so we must NOT
    // re-test containment here: doing so would flip selection→ocr on a float
    // rounding at the rect boundary, diverging from the spike.
    String? sentence;
    String context;
    var contextSource = CaptureContextSource.ocr;

    final selectionRect = snapshot.selectionRect;
    String? selectionText;
    if (selectionRect != null) {
      final selected = _textOfLines(selectionRect, sortedLines);
      if (selected.isNotEmpty) {
        selectionText = selected;
      }
    }

    double confidence;
    String? unitOverride;
    if (selectionText != null) {
      // Bound a whole-page / huge highlight the way OCR reconstruction is bounded — the selection has
      // no inherent size limit, so an unbounded sentence/context would bloat the overlay + journal +
      // /explain (capture P1). selectionText itself stays intact for the unit-override geometry below.
      final clippedSelection = LearningContextBuilder.clip(selectionText);
      sentence = clippedSelection;
      context = clippedSelection;
      contextSource = CaptureContextSource.selection;
      // selectionText is only set when selectionRect != null (above).
      confidence = _maxConfidenceInSelection(selectionRect!, sortedLines);
      // Phase 2: a SINGLE-line, unit-shaped highlight = the user pointing at a
      // specific word / 词组 → the highlighted span becomes the UNIT (the line
      // stays the context above). A multi-line or sentence-shaped highlight is a
      // passage → no override, so the unit stays the token under the cursor and
      // the selection is the context (the pre-Phase-2 behavior).
      unitOverride = _selectionUnitOverride(selectionRect, sortedLines);
    } else {
      // Choose between the native visual span and the geometric paragraph for sentence/context.
      // When present, the visual span is trusted even if it is a single line: native has already
      // applied the cursor-anchored visual block walk, which is the only layer that can reliably
      // reject same-column but unrelated list items/headlines. Geometric paragraph reconstruction is
      // now a fallback for older/native-missing snapshots only.
      final span = snapshot.cursorVisualSpan;
      final visual = _visualLearningText(span);
      final learning =
          visual ?? _geometricLearningText(selectedLineIndex, selectedToken, sortedLines);
      sentence = learning.sentence;
      context = learning.context;
      contextSource = CaptureContextSource.ocr;
      // Gate on the confidence of the line actually under the cursor — NOT a
      // screen-wide max — so a confident line elsewhere can't vouch for a
      // blurry word at the cursor.
      final targetedLine = selectedLineIndex ?? selectedToken?.lineIndex;
      confidence = (targetedLine != null && targetedLine >= 0 && targetedLine < sortedLines.length)
          ? sortedLines[targetedLine].confidence
          : 0.0;
    }

    // The captured unit: a single-line unit-shaped SELECTION → the highlighted
    // span ([unitOverride], Phase 2); otherwise the OS word token under the cursor.
    // [surfaceUnit] then strips stray edge punctuation — now a near-no-op for an OS
    // word token (NLTokenizer doesn't include leading/trailing punctuation), so it
    // mainly serves the SELECTION path ("(non-governmental)," → "non-governmental")
    // and keeps the unit aligned with its own dedup key. Internal hyphens /
    // apostrophes stay; an all-punctuation unit trims to empty → null (the junk
    // gate's job anyway). selectedToken stays WHOLE for the legacy cursor offset
    // above, so the sentence window is unaffected; sentence/context carry the full
    // run / selected line.
    final rawUnit = unitOverride ?? selectedToken?.text;
    final trimmedUnit = rawUnit == null ? null : surfaceUnit(rawUnit);
    final word = (trimmedUnit == null || trimmedUnit.isEmpty) ? null : trimmedUnit;

    // Final scrub of the learning text (both the selection and OCR branches):
    // strip invisible / zero-width / control characters Vision can inject and a
    // space wedged between two CJK characters (a line-wrap join / split-word
    // artifact). The captured unit is left as-is so its dedup key stays
    // byte-aligned with the backend's localDedupKey.
    sentence = sentence == null ? null : LearningContextBuilder.sanitizeOutput(sentence);
    context = LearningContextBuilder.sanitizeOutput(context);

    return CaptureResult(
      word: word,
      line: selectedLineIndex == null ? null : sortedLines[selectedLineIndex].text,
      sentence: sentence,
      context: context,
      recognizedLineCount: sortedLines.length,
      screenName: snapshot.screenName,
      sourceApp: snapshot.sourceApp,
      sourceTitle: snapshot.sourceTitle,
      contextSource: contextSource,
      confidence: confidence,
      // Pass the span's natively-detected language through so the app can offer a
      // target-language suggestion (Phase 2). A hint only — never attribution.
      detectedSpanLanguage: snapshot.cursorVisualSpan?.detectedLanguage,
      detectedSpanLanguageConfidence: snapshot.cursorVisualSpan?.detectedLanguageConfidence ?? 0,
    );
  }

  /// The most-confident OCR line inside [rect] — the freshness signal for a
  /// user selection (a deliberate highlight; if those lines OCR'd poorly the
  /// cascade should still be able to fall back).
  double _maxConfidenceInSelection(NormRect rect, List<OcrLine> lines) {
    double best = 0.0;
    for (final line in lines) {
      if (_lineInsideSelection(line.box, rect) && line.confidence > best) {
        best = line.confidence;
      }
    }
    return best;
  }

  // ---- line targeting ----

  /// Adapted from ScreenOCRService.lineIndex(at:in:) (ScreenOCRService.swift
  /// lines 308-312). Prefer a line whose REAL box contains the cursor (the cursor
  /// is genuinely on it); only if none does, consider lines that contain it just
  /// via the (0.008, 0.01) outset. In each tier pick the line whose vertical
  /// CENTER is nearest the cursor.
  ///
  /// WHY: the y-outset is a FIXED 0.01, but line height is
  /// not — it shrinks with font size. For small body text two tight-leading
  /// lines' outset boxes OVERLAP, and the old code returned the FIRST match
  /// (reading order top→bottom), so the UPPER line stole the top band of the line
  /// below (pointing at a word captured the one ABOVE it). Real-box-first fixes
  /// that directly (a cursor inside the lower line's real box wins), and stops a
  /// nearer-center SHORT line from stealing a cursor genuinely inside a TALL line.
  /// Nearest-center then breaks an outset-only overlap toward the closer line; a
  /// genuine tie keeps the upper (reading-order-first) line.
  int? _lineIndexAt(NormPoint point, List<OcrLine> lines) {
    int? real;
    double? realDistance;
    int? outset;
    double? outsetDistance;
    for (var i = 0; i < lines.length; i++) {
      final box = lines[i].box;
      final d = (box.midY - point.y).abs();
      if (box.contains(point)) {
        if (realDistance == null || d < realDistance) {
          realDistance = d;
          real = i;
        }
      } else if (_insetBy(box, 0.008, 0.01).contains(point)) {
        if (outsetDistance == null || d < outsetDistance) {
          outsetDistance = d;
          outset = i;
        }
      }
    }
    return real ?? outset;
  }

  /// port of ScreenOCRService.nearestLineIndex(to:in:) (ScreenOCRService.swift
  /// lines 314-320). Nearest line within 0.06 normalized distance.
  int? _nearestLineIndex(NormPoint point, List<OcrLine> lines) {
    int? best;
    double? bestDistance;
    for (var i = 0; i < lines.length; i++) {
      final d = _normalizedDistance(point, lines[i].box);
      if (d < 0.06 && (bestDistance == null || d < bestDistance)) {
        bestDistance = d;
        best = i;
      }
    }
    return best;
  }

  // ---- token targeting ----

  /// port of ScreenOCRService.token(at:in:lineIndex:) (ScreenOCRService.swift
  /// lines 269-277). Candidates are tokens whose box, inset by (-0.003,
  /// -0.006), contains the cursor; pick the min by hit-score.
  OcrToken? _tokenAt(NormPoint point, List<OcrToken> tokens, int? lineIndex) {
    OcrToken? best;
    double? bestScore;
    for (final t in _filteredTokens(tokens, lineIndex)) {
      if (_insetBy(t.box, 0.003, 0.006).contains(point)) {
        final s = _tokenHitScore(t, point);
        if (bestScore == null || s < bestScore) {
          bestScore = s;
          best = t;
        }
      }
    }
    return best;
  }

  /// port of ScreenOCRService.nearestToken(to:in:lineIndex:)
  /// (ScreenOCRService.swift lines 279-290). Nearest token within 0.035
  /// distance; ties broken by hit-score.
  OcrToken? _nearestToken(NormPoint point, List<OcrToken> tokens, int? lineIndex) {
    OcrToken? best;
    double? bestDistance;
    double? bestScore;
    for (final t in _filteredTokens(tokens, lineIndex)) {
      final d = _normalizedDistance(point, t.box);
      if (d >= 0.035) continue;
      if (bestDistance == null || d < bestDistance) {
        bestDistance = d;
        bestScore = _tokenHitScore(t, point);
        best = t;
      } else if (d == bestDistance) {
        // tie: prefer lower hit-score (matches Swift's min closure).
        final s = _tokenHitScore(t, point);
        if (bestScore == null || s < bestScore) {
          bestScore = s;
          best = t;
        }
      }
    }
    return best;
  }

  /// port of ScreenOCRService.filteredTokens(_:lineIndex:)
  /// (ScreenOCRService.swift lines 292-297).
  Iterable<OcrToken> _filteredTokens(List<OcrToken> tokens, int? lineIndex) {
    if (lineIndex == null) return tokens;
    return tokens.where((t) => t.lineIndex == lineIndex);
  }

  /// port of ScreenOCRService.tokenHitScore(_:point:) (ScreenOCRService.swift
  /// lines 299-306). Weighted distance: outsideX*8 + outsideY*4 + centerDist +
  /// width*0.05. Weights preserved VERBATIM.
  double _tokenHitScore(OcrToken token, NormPoint point) {
    final rect = token.box;
    final outsideXDistance = _max3(rect.minX - point.x, 0, point.x - rect.maxX);
    final outsideYDistance = _max3(rect.minY - point.y, 0, point.y - rect.maxY);
    final centerDistance = (rect.midX - point.x).abs();

    return outsideXDistance * 8 + outsideYDistance * 4 + centerDistance + rect.width * 0.05;
  }

  /// port of ScreenOCRService.normalizedDistance(from:to:)
  /// (ScreenOCRService.swift lines 322-326). Euclidean distance from point to
  /// the nearest edge of rect (0 when inside).
  double _normalizedDistance(NormPoint point, NormRect rect) {
    final dx = _max3(rect.minX - point.x, 0, point.x - rect.maxX);
    final dy = _max3(rect.minY - point.y, 0, point.y - rect.maxY);
    return math.sqrt(dx * dx + dy * dy);
  }

  // ---- selection path ----

  /// port of ScreenOCRService.textOfLines(within:in:) (ScreenOCRService.swift
  /// lines 331-343). The text of OCR lines whose midY is inside [rect] and that
  /// overlap it horizontally, joined in reading order.
  String _textOfLines(NormRect rect, List<OcrLine> lines) {
    final matching = <OcrLine>[
      for (final line in lines)
        if (_lineInsideSelection(line.box, rect)) line,
    ]..sort((a, b) {
        if (ParagraphReconstructor.comesBeforeInReadingOrder(a.box, b.box)) {
          return -1;
        }
        if (ParagraphReconstructor.comesBeforeInReadingOrder(b.box, a.box)) {
          return 1;
        }
        return 0;
      });

    final parts = <String>[];
    for (final line in matching) {
      final c = _paragraph.cleaned(line.text);
      if (c.isNotEmpty) parts.add(c);
    }
    return parts.join(' ');
  }

  bool _lineInsideSelection(NormRect box, NormRect rect) {
    final verticallyInside = box.midY >= rect.minY && box.midY <= rect.maxY;
    final horizontallyOverlaps = box.maxX > rect.minX && box.minX < rect.maxX;
    return verticallyInside && horizontallyOverlaps;
  }

  /// The captured UNIT when the user highlighted a specific term (Phase 2): the
  /// sub-line span of a SINGLE-line, unit-shaped selection. Returns null —
  /// leaving the unit as the token under the cursor — for a multi-line selection
  /// (a passage → context) or a sentence-shaped one (a highlighted sentence
  /// stays the context, not the unit).
  ///
  /// Sub-line, not whole-line: a pure-CJK line is ONE token, so "学习" inside
  /// "我在学习中文" can only be isolated by intersecting the selection's X-range
  /// with per-character positions. The unit is the user's own selected span (no
  /// segmenter), so the normalized dedup key stays consistent across the
  /// client/server ports.
  String? _selectionUnitOverride(NormRect rect, List<OcrLine> lines) {
    final matching = <OcrLine>[
      for (final line in lines)
        if (_lineInsideSelection(line.box, rect)) line,
    ];
    // Multi-line selection = a passage (a bounding rect can't recover sub-line
    // spans across lines anyway) → keep it as context, not the unit.
    if (matching.length != 1) return null;
    final lineText = matching.first.text;
    final selected = _selectedSubstringOnLine(
      lineText,
      matching.first.box,
      rect,
      matching.first.charBoxes,
    );
    // A span that cuts THROUGH a Latin word — a non-CJK letter sits right against
    // either edge of the kept range — is NEVER a real captured unit: you highlight
    // whole words / 词组, never a slice of one ("study" → "tud"). It is the
    // tell-tale of a SPURIOUS selection rect (e.g. a false highlight detected on
    // plain text), so drop the override and let the unit stay the whole token under
    // the cursor. This backstops the unit at the reconstruction layer no matter how
    // the bogus rect arose. CJK is exempt: a Han run has no word boundaries, so a
    // sub-run 词组 is the intended Phase-2 behavior.
    if (selected.start >= 0 && _cutsThroughLatinWord(lineText, selected.start, selected.end)) {
      return null;
    }
    final span = _paragraph.cleaned(selected.text);
    if (span.isEmpty || looksLikeSentence(span)) return null;
    return span;
  }

  /// Whether the kept sub-line range `[start, end)` slices a Latin word — i.e. a
  /// non-CJK word letter / combining mark sits immediately BEFORE [start] or AT
  /// [end] in [lineText], so the word continues past the cut. A range covering the
  /// whole line is never a cut. CJK is exempt (Han runs have no word boundaries),
  /// so a Han neighbour does not count.
  bool _cutsThroughLatinWord(String lineText, int start, int end) {
    if (start <= 0 && end >= lineText.length) return false;
    final cutsBefore = start > 0 && _isLatinWordChar(lineText, start - 1);
    final cutsAfter = end < lineText.length && _isLatinWordChar(lineText, end);
    return cutsBefore || cutsAfter;
  }

  static final RegExp _latinWordChar = RegExp(r'[\p{L}\p{M}]', unicode: true);

  /// Whether the UTF-16 code unit at [index] in [s] is a word letter / combining
  /// mark that is NOT a CJK ideograph — i.e. a script (Latin, Cyrillic, Greek, …)
  /// whose words have boundaries. A Han unit or a lone surrogate returns false, so
  /// neither counts as cutting a word.
  bool _isLatinWordChar(String s, int index) {
    final ch = s[index];
    if (Tokenizer.isHanRun(ch)) return false;
    return _latinWordChar.hasMatch(ch);
  }

  /// The substring of [lineText] whose characters fall within [rect]'s X-range,
  /// using the SAME proportional per-character model as token boxes (CJK
  /// weighted 2x). A character is kept when its estimated cell center sits inside
  /// the selection horizontally — a best-effort sub-line extractor (OCR gives
  /// only line boxes), with the overlay edit as the safety net.
  ///
  /// Also returns the UTF-16 `[start, end)` of the kept run within [lineText]
  /// (`start == -1` when nothing was kept) so the caller can tell a whole-word /
  /// 词组 selection from a span that slices through a word (a spurious rect).
  ({String text, int start, int end}) _selectedSubstringOnLine(
    String lineText,
    NormRect lineBox,
    NormRect rect,
    List<NormRect>? charBoxes,
  ) {
    // Refine Vision's word-level boxes into per-character boxes once (see
    // Tokenizer.refineCharBoxes) so the per-character hit-test below is accurate.
    final refined = _tokenizer.refineCharBoxes(lineText, charBoxes);
    final buffer = StringBuffer();
    var start = -1;
    var end = -1;
    var i = 0;
    while (i < lineText.length) {
      // Advance by a WHOLE code point: a non-BMP char (emoji, CJK Ext B, styled-math letter) is a
      // 2-code-unit surrogate pair, so testing / writing the halves independently would emit a lone
      // surrogate — a mojibake unit + dedup key. The box spans the full code point.
      final hi = lineText.codeUnitAt(i);
      final len = (hi >= 0xD800 && hi <= 0xDBFF && i + 1 < lineText.length) ? 2 : 1;
      final charBox = _tokenizer.tokenBoundingBox(lineText, i, len, lineBox, charBoxes: refined);
      if (charBox.midX >= rect.minX && charBox.midX <= rect.maxX) {
        buffer.write(lineText.substring(i, i + len));
        if (start < 0) start = i;
        end = i + len;
      }
      i += len;
    }
    return (text: buffer.toString(), start: start, end: end);
  }

  // ---- OCR learning-text path ----

  /// Builds sentence/context from the native visual span around the cursor. The span may be a single
  /// line or a multi-line visual paragraph; either way it is the preferred OCR context input because
  /// native has already excluded visually unrelated rows that the geometric pass can merge.
  ///
  /// The native adapter owns visual continuity (font size, line height/leading, mixed-size row
  /// splitting, same-column filtering) and Dart windows sentences over that text.
  /// (The span's detected-language hint is read separately in `reconstruct`.)
  LearningContext? _visualLearningText(CursorVisualSpan? span) {
    if (span == null || !span.isUsable) return null;

    final visual = _flowVisualSpan(span);
    if (visual.text.trim().isEmpty) return null;
    return LearningContextBuilder.build(visual.text, visual.anchorOffset);
  }

  ({String text, int anchorOffset}) _flowVisualSpan(CursorVisualSpan span) {
    if (span.segments.isEmpty) {
      return (text: span.text, anchorOffset: 0);
    }

    final buffer = StringBuffer();
    var anchorOffset = -1;
    for (var i = 0; i < span.segments.length; i++) {
      final segment = span.segments[i];
      if (i > 0) buffer.write('\n');
      if (anchorOffset < 0 &&
          segment.lineIndex == span.anchor.lineIndex &&
          segment.runIndex == span.anchor.runIndex) {
        final localOffset = span.anchor.utf16Offset < 0
            ? 0
            : (span.anchor.utf16Offset - segment.utf16Start).clamp(0, segment.text.length).toInt();
        anchorOffset = buffer.length + localOffset;
      }
      buffer.write(segment.text);
    }

    final text = buffer.toString();
    if (anchorOffset >= 0) {
      return (text: text, anchorOffset: anchorOffset);
    }

    final fallback = span.anchor.lineIndex >= 0
        ? span.segments.indexWhere((segment) => segment.lineIndex == span.anchor.lineIndex)
        : -1;
    if (fallback < 0) {
      return (text: text, anchorOffset: 0);
    }

    var offset = 0;
    for (var i = 0; i < fallback; i++) {
      offset += span.segments[i].text.length;
      offset += 1; // newline separator
    }
    return (text: text, anchorOffset: offset);
  }

  /// Geometric OCR paragraph reconstruction — used when the native visual span collapsed to a
  /// single line or is absent (see `reconstruct`).
  ///
  /// Reconstructs the paragraph around the cursor by grouping its column's lines on line-spacing /
  /// font-size / indent — so ALL of a paragraph's wrapped lines are gathered (see
  /// [ParagraphReconstructor]) — then flows them, maps the cursor to an offset, and windows
  /// sentence/context. This is what recovers a full wrapped sentence when the span's run-walk
  /// truncated it to the cursor's own line.
  LearningContext _geometricLearningText(
    int? lineIndex,
    OcrToken? selectedToken,
    List<OcrLine> lines,
  ) {
    final effectiveLineIndex = lineIndex ?? selectedToken?.lineIndex;
    if (effectiveLineIndex == null ||
        effectiveLineIndex < 0 ||
        effectiveLineIndex >= lines.length) {
      return const LearningContext(sentence: null, context: '');
    }

    final memberIndices = _paragraph.paragraphLineIndices(effectiveLineIndex, lines);
    final flow = _paragraph.flowText(memberIndices, lines);
    final span = flow.spans[effectiveLineIndex];

    if (flow.text.isEmpty || span == null) {
      final line = _paragraph.cleaned(lines[effectiveLineIndex].text);
      return LearningContext(
        sentence: line.isEmpty ? null : line,
        context: line,
      );
    }

    final offset = _paragraph.cursorOffset(
      span,
      effectiveLineIndex,
      selectedToken,
      lines,
    );

    return LearningContextBuilder.build(flow.text, offset);
  }

  static double _max3(double a, double b, double c) {
    final m = a > b ? a : b;
    return m > c ? m : c;
  }

  /// Expand [box] outward by [dx]/[dy] on each side — the equivalent of Swift's
  /// `CGRect.insetBy(dx: -dx, dy: -dy)` (negative inset = outset) used by the
  /// line/token containment checks (ScreenOCRService.swift lines 271 & 310).
  static NormRect _insetBy(NormRect box, double dx, double dy) => NormRect(
        box.x - dx,
        box.y - dy,
        box.width + 2 * dx,
        box.height + 2 * dy,
      );
}
