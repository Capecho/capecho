import 'package:capecho_capture_core/capecho_capture_core.dart';
import 'package:test/test.dart';

// Helpers to build lines in Vision space (bottom-left origin, y UP, so the
// TOP line on screen has the HIGHEST y). Lines are laid out top -> bottom by
// decreasing y.

const double h = 0.02; // line height
const double gap = 0.008; // ~0.4 * h: a prose wrap gap
const double left = 0.1;
const double rightMargin = 0.85; // shared right edge for full-width lines

/// Build a stacked column of lines from top (index 0) downward.
/// [widths] gives each line's width; full-width lines reach ~rightMargin.
List<OcrLine> column(List<String> texts, List<double> widths,
    {double topY = 0.8, double stepGap = gap}) {
  final lines = <OcrLine>[];
  var y = topY;
  for (var i = 0; i < texts.length; i++) {
    lines.add(OcrLine(texts[i], NormRect(left, y, widths[i], h)));
    y -= h + stepGap;
  }
  return lines;
}

void main() {
  const para = ParagraphReconstructor();

  group('reading order (port of comesBeforeInReadingOrder)', () {
    test('higher-y line reads before lower-y line', () {
      const top = NormRect(0.1, 0.8, 0.5, h);
      const bottom = NormRect(0.1, 0.5, 0.5, h);
      expect(ParagraphReconstructor.comesBeforeInReadingOrder(top, bottom), isTrue);
      expect(ParagraphReconstructor.comesBeforeInReadingOrder(bottom, top), isFalse);
    });

    test('same row (within 0.015) falls back to left-to-right', () {
      const leftBox = NormRect(0.1, 0.80, 0.2, h);
      const rightBox = NormRect(0.5, 0.805, 0.2, h);
      expect(ParagraphReconstructor.comesBeforeInReadingOrder(leftBox, rightBox), isTrue);
    });

    test('readingOrder sorts a shuffled list top->bottom', () {
      final lines = [
        const OcrLine('c', NormRect(0.1, 0.4, 0.5, h)),
        const OcrLine('a', NormRect(0.1, 0.8, 0.5, h)),
        const OcrLine('b', NormRect(0.1, 0.6, 0.5, h)),
      ];
      final order = ParagraphReconstructor.readingOrder(lines);
      expect(order.map((i) => lines[i].text).toList(), ['a', 'b', 'c']);
    });
  });

  group('paragraphLineIndices across ragged wraps', () {
    test('three full-width wrapped lines join into one paragraph', () {
      // last line shorter (end of paragraph) — that is fine, only the UPPER
      // line of each adjacent pair must be full width.
      final lines = column(
        ['The first wrapped line goes', 'all the way across and then', 'ends.'],
        [rightMargin - left, rightMargin - left, 0.1],
      );
      final members = para.paragraphLineIndices(0, lines);
      expect(members, [0, 1, 2]);
    });

    test('a large vertical gap (list spacing) ends the paragraph', () {
      // Big gap between line0 and line1 -> block break.
      final lines = column(
        ['List item one across the line', 'List item two across the line'],
        [rightMargin - left, rightMargin - left],
        stepGap: h * 2.0, // 2.0 * h > paragraphBreakGapFactor (1.2)
      );
      final members = para.paragraphLineIndices(0, lines);
      expect(members, [0]);
    });

    test('a short (ragged-right) upper line does NOT break the paragraph', () {
      // Established algorithm: line "fullness" is not a paragraph signal. Most
      // prose is left-aligned / ragged-right, so a short line of the SAME size
      // with normal spacing stays in the paragraph. Previously the "not
      // full-width" upper line wrongly split here.
      final lines = column(
        ['A short opening line', 'continues across toward the right margin here'],
        [0.18, rightMargin - left], // upper short, lower wide — same height/gap
      );
      final members = para.paragraphLineIndices(0, lines);
      expect(members, [0, 1]); // joined, not [0]
    });

    test('ragged-right body lines reconstruct as ONE paragraph (BBC repro)', () {
      // The reported failure: cursor on the middle line ("...intimate") got only
      // the current + next line, dropping the first ("The auction has already
      // brought in") because it ended short of the margin. All same size, normal
      // wrap spacing → one paragraph regardless of where each line ends.
      final lines = column(
        [
          'The auction has already brought in',
          'thousands in bids and includes intimate',
          'items from her life.',
        ],
        [0.42, 0.55, 0.22], // every line ragged (well short of the right margin)
      );
      expect(para.paragraphLineIndices(1, lines), [0, 1, 2]); // seed = middle
    });

    test('real BBC geometry: a headline above the body is excluded', () {
      // REAL Vision boxes from a capture of "increase" in the BBC "One in four
      // births" article (capture-debug.jsonl, 2026-06-05). The headline→body
      // boundary is caught primarily by the LINE-SPACING jump — that gap (~0.0089)
      // is ~4x the intra-line leading (~0.0021), well clear of it, whereas the box
      // HEIGHTS only differ ~1.28x (and same-size body lines vary ~1.16x), so
      // height alone is marginal. A headline has NO terminating punctuation, so a
      // geometric break is the only thing that can stop it flowing into the body
      // sentence. Heights + gaps are the load-bearing values.
      OcrLine ln(String t, double y, double w, double height) =>
          OcrLine(t, NormRect(0.692, y, w, height));
      final lines = [
        ln('One in four births in England is', 0.4362, 0.176, 0.02013),
        ln('now emergency caesarean, BBC', 0.4160, 0.177, 0.01802),
        ln('analysis shows', 0.3915, 0.089, 0.02013),
        ln('The shift marks a significant rise over the', 0.3669, 0.186, 0.01566),
        ln('last five years, but experts say there is no', 0.3488, 0.185, 0.01588),
        ln('single, clear explanation for the increase.', 0.3310, 0.186, 0.01580),
      ];
      // seed = the body line containing "increase" (index 5). Body only — the
      // three headline lines (0,1,2) must be excluded.
      expect(para.paragraphLineIndices(5, lines), [3, 4, 5]);
    });

    test('a line-spacing jump alone (no font-size change) ends the block', () {
      // Same font size throughout — so the font-size vote CANNOT fire; only the
      // line-spacing jump (judged against the block's own tight leading) can
      // separate the blocks. This is the primary, more-robust signal.
      const lh = 0.02;
      final lines = <OcrLine>[];
      var y = 0.8;
      for (var i = 0; i < 5; i++) {
        lines.add(OcrLine('line $i', NormRect(left, y, 0.5, lh)));
        final g = i == 2 ? lh * 0.7 : lh * 0.15; // a 0.7-line gap after line2
        y -= lh + g;
      }
      // seed=0: lines 0,1,2 join (tight 0.15h leading), then the 0.7h gap — well
      // beyond leading + 0.25h — breaks before line3. Under the 1.0h huge-gap
      // backstop, so it is the LOCAL-leading adaptive test that catches it.
      expect(para.paragraphLineIndices(0, lines), [0, 1, 2]);
    });

    test('a font-size jump (differentTextSize) ends the paragraph', () {
      // line0 height 0.02, line1 height 0.04 -> ratio 2.0 > 1.5 threshold.
      final lines = [
        const OcrLine(
            'Small full width line across here', NormRect(left, 0.8, rightMargin - left, 0.02)),
        const OcrLine(
            'BIG TITLE TEXT WIDE', NormRect(left, 0.8 - (0.04 + gap), rightMargin - left, 0.04)),
      ];
      final members = para.paragraphLineIndices(0, lines);
      expect(members, [0]);
    });

    test('different column (no left-align, no overlap) is excluded', () {
      final lines = [
        const OcrLine('left column line one wide', NormRect(left, 0.8, 0.3, h)),
        // far-right column, no horizontal overlap, different left edge
        const OcrLine('right column line', NormRect(0.6, 0.8 - (h + gap), 0.3, h)),
      ];
      final members = para.paragraphLineIndices(0, lines);
      expect(members, [0]);
    });
  });

  group('native paragraph hint (macOS 26+ RecognizeDocumentsRequest)', () {
    // Lines that the GEOMETRY would merge — uniform size, tight uniform gaps — so
    // only the native paragraphId can separate the heading from the body. Heading
    // = paragraph 0, body = paragraph 1.
    List<OcrLine> tagged() => [
          for (final (i, l) in column(
            ['Heading line one', 'Heading line two', 'Body line one', 'Body line two'],
            [0.4, 0.3, 0.5, 0.5],
          ).indexed)
            OcrLine(l.text, l.box, paragraphId: i < 2 ? 0 : 1),
        ];

    test('groups by paragraphId, ignoring the geometric signals', () {
      // seed = "Body line one" (index 2) → ONLY the body, even though geometry
      // (same size + gap) would have joined all four lines.
      expect(para.paragraphLineIndices(2, tagged()), [2, 3]);
    });

    test('a heading word returns only the heading', () {
      expect(para.paragraphLineIndices(0, tagged()), [0, 1]);
    });

    test('no paragraphId → falls back to geometry (all four join here)', () {
      // The SAME geometry without the hint: uniform size + tight gaps = one block.
      final untagged = column(
        ['Heading line one', 'Heading line two', 'Body line one', 'Body line two'],
        [0.4, 0.3, 0.5, 0.5],
      );
      expect(para.paragraphLineIndices(2, untagged), [0, 1, 2, 3]);
    });
  });

  group('flowText (port of flowText)', () {
    test('joins wrapped lines with spaces and records spans', () {
      final lines = column(
        ['hello there', 'world wide web'],
        [rightMargin - left, rightMargin - left],
      );
      final flow = para.flowText([0, 1], lines);
      expect(flow.text, 'hello there world wide web');
      expect(flow.spans[0]!.start, 0);
      expect(flow.spans[1]!.start, 'hello there '.length);
    });

    test('end-of-line hyphen joins without a space', () {
      final lines = column(
        ['inter-', 'national'],
        [rightMargin - left, 0.2],
      );
      final flow = para.flowText([0, 1], lines);
      expect(flow.text, 'inter-national');
    });

    test('collapses internal whitespace runs in each line', () {
      final lines = [
        const OcrLine('  spaced   out   text  ', NormRect(left, 0.8, 0.5, h)),
      ];
      final flow = para.flowText([0], lines);
      expect(flow.text, 'spaced out text');
      // leadingWhitespace records the stripped raw leading spaces.
      expect(flow.spans[0]!.leadingWhitespace, 2);
    });
  });

  group('cursorOffset (raw->cleaned mapping — Codex review fix)', () {
    test('maps a token after an internal whitespace run, not into a later word', () {
      // The raw line has a long internal whitespace run that cleaned() collapses.
      // The old leading-only math returned the raw offset (landing inside the
      // following sentence "Third"); the fix maps through the collapse.
      const raw = 'First.          Second. Third.';
      final lines = [const OcrLine(raw, NormRect(left, 0.8, 0.6, h))];
      final flow = para.flowText([0], lines);
      expect(flow.text, 'First. Second. Third.');
      final token = OcrToken(
        text: 'Second',
        lineIndex: 0,
        utf16Start: raw.indexOf('Second'),
        utf16Length: 6,
        box: const NormRect(0, 0, 0, 0),
      );
      expect(para.cursorOffset(flow.spans[0]!, 0, token, lines), flow.text.indexOf('Second'));
    });

    test('leading whitespace maps to the first cleaned character', () {
      const raw = '   hello world';
      final lines = [const OcrLine(raw, NormRect(left, 0.8, 0.6, h))];
      final flow = para.flowText([0], lines);
      final token = OcrToken(
        text: 'hello',
        lineIndex: 0,
        utf16Start: raw.indexOf('hello'),
        utf16Length: 5,
        box: const NormRect(0, 0, 0, 0),
      );
      expect(para.cursorOffset(flow.spans[0]!, 0, token, lines), 0);
    });
  });
}
