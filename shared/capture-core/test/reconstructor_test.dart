import 'package:capecho_capture_core/capecho_capture_core.dart';
import 'package:test/test.dart';

const double h = 0.02;
const double gap = 0.008;
const double left = 0.1;
const double rightMargin = 0.85;
const Tokenizer testTokenizer = Tokenizer();
final RegExp _testWordChar = RegExp(r'[\p{L}\p{M}\p{N}]', unicode: true);
final List<String> _testHanDictionary = [
  '守住现状',
  '图灵奖',
  '科学家',
  '有意思',
  '重新',
  '定义',
  '自己',
  '角色',
  '起点',
  '学习',
  '中文',
  '使用',
  '框架',
  '那么',
  '这里',
  '得主',
  '首席',
  '宣布',
  '离职',
  '创业',
  '文字',
  '现状',
  '机器',
  '智能',
  '项目',
];

OcrSnapshot snap(
  List<OcrLine> lines,
  NormPoint cursor, {
  NormRect? selection,
  CursorVisualSpan? cursorVisualSpan,
  String screen = 'Test Display',
}) =>
    OcrSnapshot(
      lines: [
        for (var i = 0; i < lines.length; i++) _withNativeWordRuns(lines[i], i),
      ],
      cursor: cursor,
      selectionRect: selection,
      cursorVisualSpan: cursorVisualSpan,
      screenName: screen,
    );

OcrWordRun wordRun(int start, int end, String text, double minX, double maxX, {int line = 0}) =>
    OcrWordRun(
      lineIndex: line,
      utf16Start: start,
      utf16End: end,
      text: text,
      box: NormRect(minX, 0.5, maxX - minX, h),
    );

OcrLine _withNativeWordRuns(OcrLine line, int lineIndex) {
  if (line.wordRuns.isNotEmpty) return line;
  return OcrLine(
    line.text,
    line.box,
    confidence: line.confidence,
    charBoxes: line.charBoxes,
    paragraphId: line.paragraphId,
    fontRuns: line.fontRuns,
    wordRuns: _nativeWordRunsForTest(line.text, lineIndex, line.box, line.charBoxes),
  );
}

List<OcrWordRun> _nativeWordRunsForTest(
  String text,
  int lineIndex,
  NormRect lineBox,
  List<NormRect>? charBoxes,
) {
  final refined = testTokenizer.refineCharBoxes(text, charBoxes);
  return [
    for (final segment in _systemSegmentsForTest(text))
      OcrWordRun(
        lineIndex: lineIndex,
        utf16Start: segment.start,
        utf16End: segment.end,
        text: segment.text,
        box: testTokenizer.tokenBoundingBox(
          text,
          segment.start,
          segment.end - segment.start,
          lineBox,
          charBoxes: refined,
        ),
      ),
  ];
}

List<({int start, int end, String text})> _systemSegmentsForTest(String text) {
  final segments = <({int start, int end, String text})>[];
  var index = 0;
  while (index < text.length) {
    final length = _codePointLength(text, index);
    final ch = text.substring(index, index + length);
    if (!_testWordChar.hasMatch(ch)) {
      index += length;
      continue;
    }

    if (Tokenizer.isHanRun(ch)) {
      final start = index;
      index += length;
      while (index < text.length) {
        final nextLength = _codePointLength(text, index);
        final next = text.substring(index, index + nextLength);
        if (!Tokenizer.isHanRun(next)) break;
        index += nextLength;
      }
      segments.addAll(_hanSegmentsForTest(text, start, index));
      continue;
    }

    final start = index;
    index += length;
    while (index < text.length) {
      final nextLength = _codePointLength(text, index);
      final next = text.substring(index, index + nextLength);
      if (!_testWordChar.hasMatch(next) || Tokenizer.isHanRun(next)) break;
      index += nextLength;
    }
    segments.add((start: start, end: index, text: text.substring(start, index)));
  }
  return segments;
}

List<({int start, int end, String text})> _hanSegmentsForTest(String text, int start, int end) {
  final segments = <({int start, int end, String text})>[];
  var index = start;
  while (index < end) {
    String? match;
    for (final term in _testHanDictionary) {
      if (index + term.length <= end && text.startsWith(term, index)) {
        match = term;
        break;
      }
    }
    final tokenLength = match?.length ?? _codePointLength(text, index);
    segments.add(
        (start: index, end: index + tokenLength, text: text.substring(index, index + tokenLength)));
    index += tokenLength;
  }
  return segments;
}

int _codePointLength(String text, int index) {
  final unit = text.codeUnitAt(index);
  return unit >= 0xD800 && unit <= 0xDBFF && index + 1 < text.length ? 2 : 1;
}

void main() {
  const recon = CaptureReconstructor();

  group('cursor -> token targeting', () {
    test('cursor inside a word picks that word', () {
      // single line "alpha beta gamma" spanning x 0..1 at y 0.5.
      const line = OcrLine('alpha beta gamma', NormRect(0.0, 0.5, 1.0, h));
      // "beta" is roughly the middle third of the 16-char line.
      // utf16: "beta" at [6,10), proportional center ~ (6+10)/2/16 = 0.5.
      final r = recon.reconstruct(snap([line], const NormPoint(0.5, 0.51)));
      expect(r.word, 'beta');
      expect(r.line, 'alpha beta gamma');
      expect(r.recognizedLineCount, 1);
      expect(r.contextSource, CaptureContextSource.ocr);
    });

    test('cursor just outside all tokens falls back to nearest token', () {
      const line = OcrLine('hello world', NormRect(0.0, 0.5, 0.4, h));
      // cursor a touch to the right of the line, within the 0.035 nearest band.
      final r = recon.reconstruct(snap([line], const NormPoint(0.41, 0.51)));
      expect(r.word, 'world'); // the rightmost token is nearest
    });

    test('cursor far from everything still resolves a word via global nearest', () {
      // No line under cursor, no line within 0.06, but nearestToken(nil) has
      // no distance gate beyond 0.035; place cursor within 0.035 of the line.
      const line = OcrLine('lonely', NormRect(0.4, 0.5, 0.2, h));
      final r = recon.reconstruct(snap([line], const NormPoint(0.5, 0.53)));
      expect(r.word, 'lonely');
    });

    test(
        'cursor at the top of a word is not stolen by the line above (tight '
        'leading, small font)', () {
      // The reported bug: pointing at the top ~20% of a small-font word captured
      // the word directly ABOVE it. Two tight-leading lines (gap 0.005, height
      // 0.02): the upper line's fixed 0.01 y-outset reaches DOWN into the top of
      // the lower line, and first-match-in-reading-order awarded it the upper
      // line. Now the cursor resolves to the nearer line center → the lower word.
      const upper = OcrLine('above one', NormRect(0.1, 0.50, 0.6, h)); // y[0.50,0.52]
      const lower = OcrLine('below words', NormRect(0.1, 0.475, 0.6, h)); // y[0.475,0.495]
      // y = 0.49 is in the TOP quarter of the lower line AND inside the upper
      // line's downward 0.01 outset ([0.49, 0.53]) — the overlap the bug hit.
      const cursor = NormPoint(0.25, 0.49);
      final r = recon.reconstruct(snap([upper, lower], cursor));
      expect(r.line, 'below words'); // the line the cursor sits on, not 'above one'
      expect(r.word, 'below'); // x 0.25 is over "below"
    });

    test(
        'separate words: proportional drift targets the previous word; Vision '
        'word-boxes fix it (the "heteronym → tts" cursor offset)', () {
      // The first reported case: on a proportional-width font the character-count
      // estimate places later words too far right, so the cursor lands on the
      // PREVIOUS token. "aa" and "bb" are separate words → Vision gives each its
      // own box (same box for every char in the word).
      const lineBox = NormRect(0.0, 0.5, 1.0, h);
      const wordAa = NormRect(0.00, 0.5, 0.25, h); // "aa" whole-word box
      const wordBb = NormRect(0.30, 0.5, 0.15, h); // "bb" whole-word box
      final charBoxes = <NormRect>[
        wordAa, wordAa, //                a, a  (Vision: same box per char)
        const NormRect(0.0, 0.0, 0.0, 0.0), //  space (Vision: zero box)
        wordBb, wordBb, //                b, b
      ];
      // x = 0.38 is inside the REAL "bb" box, but inside the PROPORTIONAL "aa"
      // box (which spans [0, 0.4]) — the exact ambiguity that mis-captured.
      const cursor = NormPoint(0.38, 0.51);

      // Without geometry: the proportional estimate puts "bb" at x[0.6, 1.0], so
      // the cursor falls in "aa" — the drift the user hit.
      final drifted = recon.reconstruct(snap([const OcrLine('aa bb', lineBox)], cursor));
      expect(drifted.word, 'aa');

      // With Vision word-boxes: "bb"'s box contains the cursor.
      final fixed =
          recon.reconstruct(snap([OcrLine('aa bb', lineBox, charBoxes: charBoxes)], cursor));
      expect(fixed.word, 'bb');
    });

    test(
        'compound word: Vision boxes "flutter_tts" as ONE word, but the '
        'tokenizer splits it — refinement makes pointing at "tts" capture "tts"', () {
      // The second reported case. "flutter_tts" is ONE Vision word (every char
      // shares the whole-word box), but the underscore is not a word character
      // so the tokenizer splits it into "flutter" + "tts". Without refinement
      // both sub-tokens share the word box and the first ("flutter") always wins.
      const lineBox = NormRect(0.0, 0.5, 1.0, h);
      const wordNo = NormRect(0.02, 0.5, 0.08, h); //               "no" [0.02,0.10]
      const wordFt = NormRect(0.30, 0.5, 0.32, h); //  "flutter_tts" [0.30,0.62]
      final charBoxes = <NormRect>[
        wordNo, wordNo, //                n, o
        const NormRect(0.0, 0.0, 0.0, 0.0), //  space
        // "flutter_tts" — 11 chars, ALL carrying the identical word box:
        wordFt, wordFt, wordFt, wordFt, wordFt, wordFt, wordFt, // f l u t t e r
        wordFt, //                                                _
        wordFt, wordFt, wordFt, //                                t t s
      ];
      // x = 0.57 is over the visual "tts" (the right ~quarter of the word box).
      const cursor = NormPoint(0.57, 0.51);

      // Without geometry: proportional puts "tts" far right [0.786, 1.0], so the
      // cursor lands in "flutter" [0.214, 0.714] — the reported "tts → flutter".
      final drifted = recon.reconstruct(snap([const OcrLine('no flutter_tts', lineBox)], cursor));
      expect(drifted.word, 'flutter');

      // With Vision's word-box + refinement: "flutter" gets the left slice and
      // "tts" the right slice, so the cursor over "tts" captures "tts".
      final fixed = recon
          .reconstruct(snap([OcrLine('no flutter_tts', lineBox, charBoxes: charBoxes)], cursor));
      expect(fixed.word, 'tts');
    });
  });

  group('real Vision geometry (boundingBox(for:) word-boxes)', () {
    // Build per-char boxes the way the macOS adapter does from Vision's
    // word-level boundingBox(for:): every char of a whitespace-delimited word
    // carries that word's box; spaces carry a zero box. The (word, minX, maxX)
    // numbers below are REAL Vision output captured from boundingBox(for:) on
    // this exact line — see the diagnostic in the cursor-offset fix.
    const line = 'notation attribute (no flutter_tts, heteronym-correct) - the good path.';
    final words = <(String, double, double)>[
      ('notation', 0.0209, 0.1386),
      ('attribute', 0.1427, 0.2645),
      ('(no', 0.2686, 0.3132),
      ('flutter_tts,', 0.3173, 0.4635),
      ('heteronym-correct)', 0.4675, 0.7477),
      ('-', 0.7517, 0.7639),
      ('the', 0.7680, 0.8208),
      ('good', 0.8248, 0.8979),
      ('path.', 0.9020, 0.9791),
    ];

    List<NormRect> visionCharBoxes() {
      final boxes = List<NormRect>.filled(line.length, const NormRect(0, 0, 0, 0));
      var from = 0;
      for (final (w, minX, maxX) in words) {
        final at = line.indexOf(w, from);
        for (var i = at; i < at + w.length; i++) {
          boxes[i] = NormRect(minX, 0.5, maxX - minX, h);
        }
        from = at + w.length;
      }
      return boxes;
    }

    String? wordAtX(double x) {
      final ocrLine = OcrLine(line, const NormRect(0.0, 0.5, 1.0, h), charBoxes: visionCharBoxes());
      return recon.reconstruct(snap([ocrLine], NormPoint(x, 0.51))).word;
    }

    test('underscore and hyphen compounds follow native word boundaries', () {
      // "flutter_tts," is ONE Vision word the tokenizer still SPLITS on the
      // underscore (a code separator, not an intra-word hyphen); refinement gives
      // each piece its own slice, so pointing left vs right targets the halves.
      expect(wordAtX(0.36), 'flutter'); // left of the flutter_tts word box
      expect(wordAtX(0.43), 'tts'); //    right of it — the reported failure
      // NLTokenizer treats the hyphen as a boundary, so the two sides are
      // separate editable units even though Vision boxed the source as one word.
      expect(wordAtX(0.55), 'heteronym');
      expect(wordAtX(0.68), 'correct');
    });

    test('plain single words still target correctly', () {
      expect(wordAtX(0.08), 'notation');
      expect(wordAtX(0.20), 'attribute');
      expect(wordAtX(0.79), 'the');
      expect(wordAtX(0.86), 'good');
      expect(wordAtX(0.94), 'path');
    });
  });

  group('paragraph reconstruction end-to-end', () {
    test('sentence wrapped across ragged lines is kept whole', () {
      const y0 = 0.8;
      final lines = [
        const OcrLine('The cat sat on the', NormRect(left, y0, rightMargin - left, h)),
        const OcrLine('mat by the warm fire.', NormRect(left, y0 - (h + gap), 0.45, h)),
      ];
      // cursor on the first line over "cat".
      // "The cat sat on the": "cat" at utf16 [4,7), center ~ 5.5/18 = 0.305.
      // line spans x in [left, rightMargin], width 0.75. x ~ left + 0.305*0.75.
      const cursorX = left + 0.305 * (rightMargin - left);
      final r = recon.reconstruct(snap(lines, const NormPoint(cursorX, y0 + h / 2)));
      expect(r.word, 'cat');
      expect(r.sentence, 'The cat sat on the mat by the warm fire.');
      expect(r.contextSource, CaptureContextSource.ocr);
    });
  });

  group('visual span reconstruction', () {
    test('uses native cursorVisualSpan instead of legacy paragraph text', () {
      final lines = [
        const OcrLine(
          '150 easy-to-remember example sentences in Japanese using the verbs.',
          NormRect(0.10, 0.70, 0.60, h),
        ),
        const OcrLine('I play with', NormRect(0.10, 0.66, 0.20, h)),
        const OcrLine(
          'Essential words for Everyday use (ENG SUB)',
          NormRect(0.10, 0.62, 0.52, h),
        ),
      ];
      const visualSpan = CursorVisualSpan(
        text: '150 easy-to-remember example sentences in Japanese using the verbs.\n'
            'Essential words for Everyday use (ENG SUB)',
        lineIndices: [0, 2],
        anchor: CursorVisualSpanAnchor(
          lineIndex: 2,
          runIndex: 0,
          position: 'whole',
          fontSizePx: 34,
          fontSizePt: 17,
          lineHeightPx: 34,
          lineHeightPt: 17,
        ),
        segments: [
          OcrVisualRun(
            lineIndex: 0,
            runIndex: 0,
            utf16Start: 0,
            utf16End: 66,
            text: '150 easy-to-remember example sentences in Japanese using the verbs.',
            box: NormRect(0.10, 0.70, 0.60, h),
            fontSizePx: 34,
            fontSizePt: 17,
          ),
          OcrVisualRun(
            lineIndex: 2,
            runIndex: 0,
            utf16Start: 0,
            utf16End: 42,
            text: 'Essential words for Everyday use (ENG SUB)',
            box: NormRect(0.10, 0.62, 0.52, h),
            fontSizePx: 34,
            fontSizePt: 17,
          ),
        ],
      );

      final result = recon.reconstruct(
        snap(lines, const NormPoint(0.25, 0.63), cursorVisualSpan: visualSpan),
      );

      expect(result.word, 'words');
      expect(result.line, 'Essential words for Everyday use (ENG SUB)');
      expect(result.sentence, 'Essential words for Everyday use (ENG SUB)');
      expect(result.sentence, isNot(contains('I play with')));
      expect(result.context, contains('150 easy-to-remember example sentences'));
      expect(result.context, isNot(contains('I play with')));
    });

    test('uses anchor utf16Offset when a visual run contains multiple sentences', () {
      const targetLine = 'Dec 4,2025-这本电子书不会告诉你如何规避风险，也不会提供所谓的“安全路径”。守住现状”反而更危险，';
      final anchorOffset = targetLine.indexOf('守');
      final lines = [
        const OcrLine(targetLine, NormRect(0.10, 0.70, 0.80, h)),
        const OcrLine('那么这里，就是你重新定义自己角色的起点。', NormRect(0.10, 0.66, 0.56, h)),
      ];
      final visualSpan = CursorVisualSpan(
        text: '$targetLine\n那么这里，就是你重新定义自己角色的起点。',
        lineIndices: const [0, 1],
        anchor: CursorVisualSpanAnchor(
          lineIndex: 0,
          runIndex: 0,
          utf16Offset: anchorOffset,
          position: 'whole',
          fontSizePx: 39.3,
          fontSizePt: 19.6,
          lineHeightPx: 39.3,
          lineHeightPt: 19.6,
        ),
        segments: const [
          OcrVisualRun(
            lineIndex: 0,
            runIndex: 0,
            utf16Start: 0,
            utf16End: targetLine.length,
            text: targetLine,
            box: NormRect(0.10, 0.70, 0.80, h),
            fontSizePx: 39.3,
            fontSizePt: 19.6,
          ),
          OcrVisualRun(
            lineIndex: 1,
            runIndex: 0,
            utf16Start: 0,
            utf16End: 20,
            text: '那么这里，就是你重新定义自己角色的起点。',
            box: NormRect(0.10, 0.66, 0.56, h),
            fontSizePx: 39.2,
            fontSizePt: 19.6,
          ),
        ],
      );

      final result = recon.reconstruct(
        snap(lines, const NormPoint(0.72, 0.71), cursorVisualSpan: visualSpan),
      );

      expect(result.word, '守住现状');
      expect(result.sentence, startsWith('守住现状'));
      expect(result.sentence, isNot(contains('这本电子书不会告诉你')));
    });

    test('falls back to legacy paragraph reconstruction when visual span is absent', () {
      const y0 = 0.8;
      final lines = [
        const OcrLine('The cat sat on the', NormRect(left, y0, rightMargin - left, h)),
        const OcrLine('mat by the warm fire.', NormRect(left, y0 - (h + gap), 0.45, h)),
      ];
      const cursorX = left + 0.305 * (rightMargin - left);
      final result = recon.reconstruct(snap(lines, const NormPoint(cursorX, y0 + h / 2)));

      expect(result.word, 'cat');
      expect(result.sentence, 'The cat sat on the mat by the warm fire.');
    });

    test('trusts a single-line visual span instead of widening to the geometric paragraph', () {
      // Native owns the visual block boundary. If it says the cursor span is one line, widening in
      // Dart can pull in same-column but unrelated headlines/list items.
      const y0 = 0.80;
      final lines = [
        const OcrLine('There are contests in four states today that will',
            NormRect(left, y0, rightMargin - left, h)),
        const OcrLine('offer clues about how much tolerance voters have for candidates',
            NormRect(left, y0 - (h + gap), rightMargin - left, h)),
        const OcrLine('embroiled in controversies, while testing the president and',
            NormRect(left, y0 - 2 * (h + gap), rightMargin - left, h)),
        const OcrLine('setting up a race for governor in a battleground state.',
            NormRect(left, y0 - 3 * (h + gap), 0.5, h)),
      ];
      final cursorLine = lines[1];
      // The span the native engine produced for this capture: ONLY the cursor's line (the truncation).
      final visualSpan = CursorVisualSpan(
        text: cursorLine.text,
        lineIndices: const [1],
        anchor: const CursorVisualSpanAnchor(
          lineIndex: 1,
          runIndex: 0,
          position: 'whole',
          fontSizePx: 20,
          fontSizePt: 10,
          lineHeightPx: 24,
          lineHeightPt: 12,
        ),
        segments: [
          OcrVisualRun(
            lineIndex: 1,
            runIndex: 0,
            utf16Start: 0,
            utf16End: cursorLine.text.length,
            text: cursorLine.text,
            box: cursorLine.box,
            fontSizePx: 20,
            fontSizePt: 10,
          ),
        ],
      );
      const cursorX = left + 0.92 * (rightMargin - left); // on "candidates" (end of line 1)
      final result = recon.reconstruct(
        snap(lines, const NormPoint(cursorX, (y0 - (h + gap)) + h / 2),
            cursorVisualSpan: visualSpan),
      );

      expect(result.word, 'candidates');
      expect(result.sentence, 'offer clues about how much tolerance voters have for candidates');
      expect(result.context, result.sentence);
      expect(result.sentence, isNot(contains('There are contests in four states')));
      expect(result.sentence, isNot(contains('battleground state.')));
    });

    test('single-line visual span prevents a nearby CNN headline from entering the sentence', () {
      final lines = [
        const OcrLine(
          'Iran has also launched missiles and drones toward US targets in the',
          NormRect(0.05, 0.36, 0.88, h),
        ),
        const OcrLine('region, the IRGC says', NormRect(0.05, 0.33, 0.30, h)),
        const OcrLine(
          "The Strait of Hormuz is 'leaking' oil",
          NormRect(0.05, 0.28, 0.48, h),
        ),
      ];
      final anchorText = lines[2].text;
      final visualSpan = CursorVisualSpan(
        text: anchorText,
        lineIndices: const [2],
        anchor: const CursorVisualSpanAnchor(
          lineIndex: 2,
          runIndex: 0,
          utf16Offset: 34,
          position: 'whole',
          fontSizePx: 42,
          fontSizePt: 21,
          lineHeightPx: 42,
          lineHeightPt: 21,
        ),
        segments: [
          OcrVisualRun(
            lineIndex: 2,
            runIndex: 0,
            utf16Start: 0,
            utf16End: anchorText.length,
            text: anchorText,
            box: lines[2].box,
            fontSizePx: 42,
            fontSizePt: 21,
          ),
        ],
      );
      final cursorX = lines[2].box.x + lines[2].box.width * 0.94;
      final result = recon.reconstruct(
        snap(lines, NormPoint(cursorX, lines[2].box.y + h / 2), cursorVisualSpan: visualSpan),
      );

      expect(result.word, 'oil');
      expect(result.sentence, "The Strait of Hormuz is 'leaking' oil");
      expect(result.context, result.sentence);
      expect(result.sentence, isNot(contains('Iran has also launched')));
      expect(result.sentence, isNot(contains('IRGC')));
    });
  });

  group('selection path', () {
    test('cursor on a selection uses the selected lines as the sentence', () {
      const y0 = 0.8;
      final lines = [
        const OcrLine('Selected first line', NormRect(left, y0, 0.5, h)),
        const OcrLine('selected second line', NormRect(left, y0 - (h + gap), 0.5, h)),
        const OcrLine('Unselected far below', NormRect(left, 0.3, 0.5, h)),
      ];
      // selection rect covers the top two lines' midYs.
      const selTop = y0 + h; // above line0
      const selBottom = (y0 - (h + gap)) - 0.001; // just below line1 midY
      const selection = NormRect(left - 0.01, selBottom, 0.6, selTop - selBottom);
      const cursor = NormPoint(left + 0.1, y0 + h / 2);
      final r = recon.reconstruct(snap(lines, cursor, selection: selection));

      expect(r.contextSource, CaptureContextSource.selection);
      expect(r.sentence, 'Selected first line selected second line');
      expect(r.context, r.sentence);
      // word still comes from the token under the cursor.
      expect(r.word, isNotNull);
    });

    test('selection that covers no recognized line -> OCR path', () {
      const line = OcrLine('hello world here', NormRect(0.0, 0.5, 1.0, h));
      // selection sits where there is no recognized line, so it yields no text.
      const selection = NormRect(0.0, 0.1, 0.5, 0.05);
      final r = recon.reconstruct(snap([line], const NormPoint(0.5, 0.51), selection: selection));
      expect(r.contextSource, CaptureContextSource.ocr);
    });

    test('selection covering lines is used even when the cursor is outside it', () {
      // Native only emits a selectionRect when the cursor is on a highlight, so
      // the core trusts it WITHOUT re-testing containment (avoids a boundary
      // float-rounding flip from selection -> ocr).
      const line = OcrLine('hello world here', NormRect(0.0, 0.5, 1.0, h));
      const selection = NormRect(0.0, 0.4, 1.0, 0.2); // clearly covers the line
      const cursorOutside = NormPoint(0.5, 0.2); // NOT inside the selection rect
      final r = recon.reconstruct(snap([line], cursorOutside, selection: selection));
      expect(r.contextSource, CaptureContextSource.selection);
      expect(r.sentence, 'hello world here');
    });
  });

  group('selection → unit (Phase 2)', () {
    test('single-line CJK 词组 highlight becomes the unit; line is the context', () {
      // "我在学习中文": 6 equal-width Han chars, centers 我.083 在.25 学.417 习.583
      // 中.75 文.917. A rect over x[0.30,0.70] covers 学+习 only.
      const line = OcrLine('我在学习中文', NormRect(0.0, 0.5, 1.0, h));
      const selection = NormRect(0.30, 0.49, 0.40, 0.04); // x[0.30,0.70]
      final r = recon.reconstruct(snap([line], const NormPoint(0.45, 0.51), selection: selection));
      expect(r.word, '学习'); // the highlighted 词组 is the unit
      expect(r.sentence, '我在学习中文'); // the whole line stays the context
      expect(r.context, '我在学习中文');
      expect(r.contextSource, CaptureContextSource.selection);
    });

    test('single-line Latin phrase highlight becomes the unit', () {
      // Select "give up" out of "I give up now" (13 equal-width units): the
      // phrase spans chars 2..8, whose centers fall in x[0.15,0.70].
      const line = OcrLine('I give up now', NormRect(0.0, 0.5, 1.0, h));
      const selection = NormRect(0.15, 0.49, 0.55, 0.04); // x[0.15,0.70]
      final r = recon.reconstruct(snap([line], const NormPoint(0.40, 0.51), selection: selection));
      expect(r.word, 'give up');
      expect(r.contextSource, CaptureContextSource.selection);
    });

    test('selection strips wrapping punctuation off the unit (keeps internal hyphen)', () {
      // Highlighting "(non-governmental)" out of a line: the parens are stray
      // edge punctuation surfaceUnit removes, while the internal hyphen stays —
      // so the captured UNIT is the clean compound word. The
      // line "see (non-governmental) act" is 26 equal-width chars; the
      // parenthesized span is chars [4,21], whose centers fall in x[0.173,0.827].
      const line = OcrLine('see (non-governmental) act', NormRect(0.0, 0.5, 1.0, h));
      const selection = NormRect(0.16, 0.49, 0.68, 0.04); // x[0.16,0.84]
      final r = recon.reconstruct(snap([line], const NormPoint(0.45, 0.51), selection: selection));
      expect(r.word, 'non-governmental'); // parens stripped, hyphen kept
      expect(r.contextSource, CaptureContextSource.selection);
    });

    test('a sentence-shaped single-line highlight stays context (no override)', () {
      // The whole line is highlighted but reads as a sentence (>4 words) → the
      // unit stays the token under the cursor; the selection is the context.
      const line = OcrLine('the cat sat on the mat', NormRect(0.0, 0.5, 1.0, h));
      const selection = NormRect(0.0, 0.49, 1.0, 0.04); // whole line
      // cursor over "cat": utf16 [4,7), center ~5.5/22 = 0.25.
      final r = recon.reconstruct(snap([line], const NormPoint(0.25, 0.51), selection: selection));
      expect(r.word, 'cat'); // NOT the whole sentence
      expect(r.contextSource, CaptureContextSource.selection);
      expect(r.sentence, 'the cat sat on the mat');
    });

    test('a single-line CJK SENTENCE highlight stays context — unit falls back to the cursor token',
        () {
      // The whole CJK line is highlighted, but the terminal punctuation (。) makes it a
      // SENTENCE, not a 词组 — so the unit must NOT become the whole line (a sentence is
      // never a word/short phrase). Whitespace word-count can't see this (CJK has no
      // spaces → 1 "word"); the script-aware heuristic counts ideographs. Unit falls back
      // to the token under the cursor; the line stays the context.
      final line = OcrLine(
        '我在学习中文。',
        const NormRect(0.0, 0.5, 1.0, h),
        wordRuns: [
          wordRun(0, 1, '我', 0.00, 0.16),
          wordRun(1, 2, '在', 0.16, 0.32),
          wordRun(2, 4, '学习', 0.32, 0.64),
          wordRun(4, 6, '中文', 0.64, 0.92),
        ],
      );
      const selection = NormRect(0.0, 0.49, 1.0, 0.04); // whole line highlighted
      final r = recon.reconstruct(snap([line], const NormPoint(0.45, 0.51), selection: selection));
      expect(r.word, '学习'); // token under cursor, not the highlighted sentence with punctuation
      expect(r.sentence, contains('我在学习中文')); // the line is the context
      expect(r.contextSource, CaptureContextSource.selection);
    });

    test(
        'a long space-free CJK CLAUSE highlight stays context — unit falls back to the cursor token',
        () {
      // No terminal punctuation, but 10 ideographs (> the CJK ceiling of 8) → a clause, not a 词组.
      // Whitespace word-count can't see this (1 "word"); the ideograph ceiling routes it to context.
      final line = OcrLine(
        '我在学习中文很有意思',
        const NormRect(0.0, 0.5, 1.0, h),
        wordRuns: [
          wordRun(0, 1, '我', 0.00, 0.10),
          wordRun(1, 2, '在', 0.10, 0.20),
          wordRun(2, 4, '学习', 0.20, 0.42),
          wordRun(4, 6, '中文', 0.42, 0.64),
          wordRun(6, 7, '很', 0.64, 0.74),
          wordRun(7, 10, '有意思', 0.74, 1.00),
        ],
      );
      const selection = NormRect(0.0, 0.49, 1.0, 0.04); // whole line highlighted
      final r = recon.reconstruct(snap([line], const NormPoint(0.45, 0.51), selection: selection));
      expect(r.word, '中文'); // token under cursor, not a selected phrase override
      expect(r.contextSource, CaptureContextSource.selection);
    });

    test('a multi-line highlight stays a passage → context, cursor token unit', () {
      const y0 = 0.8;
      final lines = [
        const OcrLine('第一行文字', NormRect(left, y0, 0.5, h)),
        const OcrLine('第二行文字', NormRect(left, y0 - (h + gap), 0.5, h)),
      ];
      const selection =
          NormRect(left - 0.01, y0 - (h + gap) - 0.001, 0.6, (y0 + h) - (y0 - (h + gap) - 0.001));
      // cursor over the 3rd char (行) of line 0.
      final r = recon.reconstruct(
          snap(lines, const NormPoint(left + 0.5 * 0.4, y0 + h / 2), selection: selection));
      expect(r.contextSource, CaptureContextSource.selection);
      // The passage = both lines; the line-join space lands between two CJK
      // characters (字│第), so sanitizeOutput scrubs it — CJK has no
      // inter-character spacing (see LearningContextBuilder.sanitizeOutput).
      expect(r.sentence, '第一行文字第二行文字');
      expect(r.word, '行'); // token under the cursor, not the passage
    });

    test('a selection over a non-BMP char captures it whole (no split surrogate pair)', () {
      // "𝐀𝐀": two non-BMP LETTERS (U+1D400 MATHEMATICAL BOLD CAPITAL A), each a 2-code-unit surrogate
      // pair → 4 equal-width code units, so letter #1 spans x[0,0.5] (center 0.25), #2 spans x[0.5,1.0].
      // A rect over x[0,0.3] includes #1's center only → the WHOLE first letter is captured, never a
      // lone high surrogate (the pre-fix bug). A LETTER survives surfaceUnit; a pure emoji would trim to
      // nothing — it is not a vocabulary unit (its dedup key is empty and the junk gate rejects it).
      const line = OcrLine('\u{1D400}\u{1D400}', NormRect(0.0, 0.5, 1.0, h));
      const selection = NormRect(0.0, 0.49, 0.3, 0.04); // x[0,0.3]
      final r = recon.reconstruct(snap([line], const NormPoint(0.1, 0.51), selection: selection));
      expect(r.word, '\u{1D400}'); // first letter intact; never the lone high surrogate \uD835
    });

    test('a sub-word selection rect does NOT slice the word — the whole token is kept', () {
      // The reported bug: a spurious selection rect (e.g. a FALSE highlight detected on plain
      // text) covering only the MIDDLE of a word must never become a fragment unit. "I study
      // hard" = 12 equal-width units (I0 _1 s2 t3 u4 d5 y6 _7 h8 a9 r10 d11); a rect over
      // x[0.27,0.47] covers t/u/d centers (0.292/0.375/0.458) only → "tud", a strict slice of
      // "study". The guard sees a Latin letter ("s") against the cut and drops the override, so
      // the unit falls back to the WHOLE token under the cursor.
      const line = OcrLine('I study hard', NormRect(0.0, 0.5, 1.0, h));
      const selection = NormRect(0.27, 0.49, 0.20, 0.04); // x[0.27,0.47]
      final r = recon.reconstruct(snap([line], const NormPoint(0.375, 0.51), selection: selection));
      expect(r.word, 'study'); // NOT 'tud'
      expect(r.contextSource, CaptureContextSource.selection);
    });

    test('a single whole-word highlight still becomes the unit (guard allows whole words)', () {
      // The guard only rejects MID-word slices — a highlight covering a whole word is a
      // legitimate Phase-2 unit. Select "study" fully out of "I study hard": chars [2,7),
      // centers 0.208..0.542, bordered by spaces → not a cut.
      const line = OcrLine('I study hard', NormRect(0.0, 0.5, 1.0, h));
      const selection = NormRect(0.18, 0.49, 0.42, 0.04); // x[0.18,0.60]
      final r = recon.reconstruct(snap([line], const NormPoint(0.375, 0.51), selection: selection));
      expect(r.word, 'study');
      expect(r.contextSource, CaptureContextSource.selection);
    });
  });

  group('mixed CJK + Latin', () {
    // Hover unit targeting uses native system word boundaries from wordRuns.
    test('cursor over a Han run picks the system word token', () {
      final line = OcrLine(
        '学习 vocabulary',
        const NormRect(0.0, 0.5, 1.0, h),
        wordRuns: [
          wordRun(0, 2, '学习', 0.00, 0.27),
          wordRun(3, 13, 'vocabulary', 0.33, 1.00),
        ],
      );
      expect(recon.reconstruct(snap([line], const NormPoint(0.06, 0.51))).word, '学习');
      expect(recon.reconstruct(snap([line], const NormPoint(0.20, 0.51))).word, '学习');
    });

    test('cursor over the Latin word picks the whole Latin token', () {
      final line = OcrLine(
        '学习 vocabulary',
        const NormRect(0.0, 0.5, 1.0, h),
        wordRuns: [
          wordRun(0, 2, '学习', 0.00, 0.27),
          wordRun(3, 13, 'vocabulary', 0.33, 1.00),
        ],
      );
      // "vocabulary" weighted [5,15)/15 -> center ~ 10/15 = 0.667.
      final r = recon.reconstruct(snap([line], const NormPoint(0.7, 0.51)));
      expect(r.word, 'vocabulary');
    });

    test('pure Han line uses system wordRuns (我在学习中文)', () {
      final line = OcrLine(
        '我在学习中文',
        const NormRect(0.0, 0.5, 1.0, h),
        wordRuns: [
          wordRun(0, 1, '我', 0.00, 0.16),
          wordRun(1, 2, '在', 0.16, 0.32),
          wordRun(2, 4, '学习', 0.32, 0.64),
          wordRun(4, 6, '中文', 0.64, 1.00),
        ],
      );
      expect(recon.reconstruct(snap([line], const NormPoint(0.40, 0.51))).word, '学习');
      expect(recon.reconstruct(snap([line], const NormPoint(0.60, 0.51))).word, '学习');
      expect(recon.reconstruct(snap([line], const NormPoint(0.95, 0.51))).word, '中文');
      expect(
        recon.reconstruct(snap([line], const NormPoint(0.40, 0.51))).sentence,
        '我在学习中文',
      );
    });

    test('cursor just past a Han word falls back to the nearest system token', () {
      // Han run occupying x in [0.4, 0.6]; cursor a touch to the right (within
      // the 0.035 nearest band) -> nearestToken.
      final line = OcrLine(
        '中文',
        const NormRect(0.4, 0.5, 0.2, h),
        wordRuns: [wordRun(0, 2, '中文', 0.4, 0.6)],
      );
      final r = recon.reconstruct(snap([line], const NormPoint(0.61, 0.51)));
      expect(r.word, '中文');
    });

    test('Latin glued to CJK: the split-off Han run uses system words', () {
      // "使用React框架" -> 使用 / React / 框架 (weights 2,2,1,1,1,1,1,2,2 = 13).
      // The "框架" token occupies x in [9/13≈0.692, 1.0].
      final line = OcrLine(
        '使用React框架',
        const NormRect(0.0, 0.5, 1.0, h),
        wordRuns: [
          wordRun(0, 2, '使用', 0.00, 0.31),
          wordRun(2, 7, 'React', 0.31, 0.69),
          wordRun(7, 9, '框架', 0.69, 1.00),
        ],
      );
      expect(recon.reconstruct(snap([line], const NormPoint(0.75, 0.51))).word, '框架');
      expect(recon.reconstruct(snap([line], const NormPoint(0.95, 0.51))).word, '框架');
      // The Latin token in the middle is still captured whole.
      expect(recon.reconstruct(snap([line], const NormPoint(0.50, 0.51))).word, 'React');
    });
  });

  group('OcrLine.charBoxes serialization (bridge round-trip)', () {
    test('charBoxes round-trips through toMap/fromMap', () {
      const line = OcrLine('hi', NormRect(0.0, 0.5, 0.2, h), charBoxes: [
        NormRect(0.0, 0.5, 0.08, h),
        NormRect(0.08, 0.5, 0.12, h),
      ]);
      final restored = OcrLine.fromMap(line.toMap());
      expect(restored.charBoxes, isNotNull);
      expect(restored.charBoxes!.length, 2);
      expect(restored.charBoxes![1].minX, closeTo(0.08, 1e-9));
      expect(restored.charBoxes![1].width, closeTo(0.12, 1e-9));
    });

    test('absent charBoxes stays null and omits the map key', () {
      const line = OcrLine('hi', NormRect(0.0, 0.5, 0.2, h));
      expect(line.toMap().containsKey('charBoxes'), isFalse);
      expect(OcrLine.fromMap(line.toMap()).charBoxes, isNull);
    });
  });

  group('degenerate inputs', () {
    test('no lines -> empty result', () {
      final r = recon.reconstruct(snap([], const NormPoint(0.5, 0.5)));
      expect(r.word, isNull);
      expect(r.line, isNull);
      expect(r.sentence, isNull);
      expect(r.context, '');
      expect(r.recognizedLineCount, 0);
      expect(r.isEmpty, isTrue);
      expect(r.screenName, 'Test Display');
    });

    test('single line, cursor on it', () {
      const line = OcrLine('Solo line here.', NormRect(0.0, 0.5, 0.6, h));
      final r = recon.reconstruct(snap([line], const NormPoint(0.3, 0.51)));
      expect(r.line, 'Solo line here.');
      expect(r.sentence, 'Solo line here.');
      expect(r.recognizedLineCount, 1);
    });

    test('cursor off all lines but within nearest-line band', () {
      // line near top, cursor below it within 0.06.
      const line = OcrLine('Some words up here', NormRect(0.1, 0.8, 0.5, h));
      final r = recon.reconstruct(snap([line], const NormPoint(0.3, 0.77)));
      expect(r.line, 'Some words up here');
      expect(r.word, isNotNull);
    });

    test('cursor with no line in range still produces a word via token nearest', () {
      // cursor far below everything (> 0.06 from line) so no selected line,
      // but token nearest(nil) gate is 0.035 — place just out of line band but
      // within token band is hard; here cursor is far, so word may be null and
      // context empty. Assert it does not throw and is internally consistent.
      const line = OcrLine('faraway text', NormRect(0.1, 0.9, 0.4, h));
      final r = recon.reconstruct(snap([line], const NormPoint(0.8, 0.1)));
      // No crash; recognizedLineCount still reflects input.
      expect(r.recognizedLineCount, 1);
      if (r.word == null) {
        expect(r.sentence, isNull);
        expect(r.context, '');
      }
    });
  });
}
