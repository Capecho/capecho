import 'package:capecho_capture_core/capecho_capture_core.dart';
import 'package:test/test.dart';

// A line box spanning most of the width near the top of the screen.
NormRect lineBox({double x = 0.1, double y = 0.8, double w = 0.6, double h = 0.03}) =>
    NormRect(x, y, w, h);

const tk = Tokenizer();

OcrWordRun wordRun(
  int start,
  int end,
  String text,
  double minX,
  double maxX, {
  int line = 0,
  double y = 0.5,
  double h = 0.03,
}) =>
    OcrWordRun(
      lineIndex: line,
      utf16Start: start,
      utf16End: end,
      text: text,
      box: NormRect(minX, y, maxX - minX, h),
    );

List<OcrWordRun> wordRunsFor(String text, List<String> segments, {NormRect? box}) {
  final line = box ?? lineBox();
  final runs = <OcrWordRun>[];
  var from = 0;
  for (final segment in segments) {
    final start = text.indexOf(segment, from);
    if (start < 0) {
      throw ArgumentError('segment "$segment" not found after $from in "$text"');
    }
    final end = start + segment.length;
    final tokenBox = tk.tokenBoundingBox(text, start, end - start, line);
    runs.add(
        wordRun(start, end, segment, tokenBox.minX, tokenBox.maxX, y: line.minY, h: line.height));
    from = end;
  }
  return runs;
}

List<String> tokenTexts(String text, List<String> segments) => tk
    .tokensForLine(text, 0, lineBox(), wordRuns: wordRunsFor(text, segments))
    .map((t) => t.text)
    .toList();

void main() {
  group('native system wordRuns', () {
    test('uses native word boundaries for Latin text', () {
      expect(tokenTexts('the quick brown fox', ['the', 'quick', 'brown', 'fox']),
          ['the', 'quick', 'brown', 'fox']);
      expect(tokenTexts("don't can't won't", ["don't", "can't", "won't"]),
          ["don't", "can't", "won't"]);
      expect(tokenTexts('it’s fine', ['it’s', 'fine']), ['it’s', 'fine']);
      expect(tokenTexts('pi is 3.14 and 1,000', ['pi', 'is', '3.14', 'and', '1,000']),
          ['pi', 'is', '3.14', 'and', '1,000']);
    });

    test('uses native word boundaries for Chinese and mixed-script text', () {
      expect(tokenTexts('我在学习中文', ['我', '在', '学习', '中文']), ['我', '在', '学习', '中文']);
      expect(tokenTexts('React框架', ['React', '框架']), ['React', '框架']);
      expect(tokenTexts('使用React框架', ['使用', 'React', '框架']), ['使用', 'React', '框架']);
      expect(tokenTexts('图灵奖得主 Meta', ['图灵奖', '得主', 'Meta']), ['图灵奖', '得主', 'Meta']);
    });

    test('uses native word boundaries for non-Latin alphabetic scripts', () {
      expect(tokenTexts('café naïve mañana', ['café', 'naïve', 'mañana']),
          ['café', 'naïve', 'mañana']);
      expect(tokenTexts('Привет λόγος', ['Привет', 'λόγος']), ['Привет', 'λόγος']);
    });

    test('accepts NLTokenizer-style hyphen and underscore splits as authoritative', () {
      expect(tokenTexts('non-governmental', ['non', 'governmental']), ['non', 'governmental']);
      expect(
          tokenTexts('state-of-the-art mother-in-law',
              ['state', 'of', 'the', 'art', 'mother', 'in', 'law']),
          [
            'state',
            'of',
            'the',
            'art',
            'mother',
            'in',
            'law',
          ]);
      expect(tokenTexts("co-op's well-being", ['co', "op's", 'well', 'being']),
          ['co', "op's", 'well', 'being']);
      expect(tokenTexts('flutter_tts', ['flutter', 'tts']), ['flutter', 'tts']);
      expect(tokenTexts('COVID-19', ['COVID', '19']), ['COVID', '19']);
    });

    test('does not fall back to regex when native wordRuns are absent', () {
      final tokens = tk.tokensForLine('the quick brown fox', 0, lineBox());
      expect(tokens, isEmpty);
    });

    test('keeps native boxes and UTF-16 offsets', () {
      final tokens = tk.tokensForLine(
        'alpha beta',
        0,
        lineBox(),
        wordRuns: const [
          OcrWordRun(
            lineIndex: 0,
            utf16Start: 6,
            utf16End: 10,
            text: 'beta',
            box: NormRect(0.60, 0.5, 0.25, 0.03),
          ),
        ],
      );

      expect(tokens.single.text, 'beta');
      expect(tokens.single.utf16Start, 6);
      expect(tokens.single.utf16Length, 4);
      expect(tokens.single.box.minX, 0.60);
      expect(tokens.single.box.maxX, 0.85);
    });

    test('drops invalid native ranges and punctuation-only runs', () {
      final tokens = tk.tokensForLine(
        'hello.',
        0,
        lineBox(),
        wordRuns: const [
          OcrWordRun(
            lineIndex: 0,
            utf16Start: 0,
            utf16End: 5,
            text: 'hello',
            box: NormRect(0.1, 0.5, 0.3, 0.03),
          ),
          OcrWordRun(
            lineIndex: 0,
            utf16Start: 5,
            utf16End: 6,
            text: '.',
            box: NormRect(0.4, 0.5, 0.03, 0.03),
          ),
          OcrWordRun(
            lineIndex: 0,
            utf16Start: 7,
            utf16End: 8,
            text: 'bad',
            box: NormRect(0.5, 0.5, 0.1, 0.03),
          ),
        ],
      );

      expect(tokens.map((t) => t.text), ['hello']);
    });
  });

  group('proportional bounding box (port of proportionalBoundingBox + CJK 2x)', () {
    test('Latin ranges partition the line width by character count', () {
      // "ab cd": 5 units. token "ab" at [0,2) -> startRatio 0, width 2/5.
      final box = lineBox(x: 0, y: 0.5, w: 1.0, h: 0.02);
      final ab = tk.tokenBoundingBox('ab cd', 0, 2, box);
      final cd = tk.tokenBoundingBox('ab cd', 3, 2, box);
      expect(ab.minX, closeTo(0.0, 1e-9));
      expect(ab.width, closeTo(2 / 5, 1e-9));
      // "cd" at [3,5): startRatio 3/5, width 2/5.
      expect(cd.minX, closeTo(3 / 5, 1e-9));
      expect(cd.width, closeTo(2 / 5, 1e-9));
    });

    test('token box inherits the line y and height', () {
      final box = lineBox(x: 0.2, y: 0.4, w: 0.5, h: 0.03);
      final alpha = tk.tokenBoundingBox('alpha', 0, 5, box);
      expect(alpha.minY, 0.4);
      expect(alpha.height, 0.03);
    });

    test('CJK characters count double-width vs Latin', () {
      // "中A": Han counts 2, "A" counts 1 -> total weight 3.
      final box = lineBox(x: 0, y: 0.5, w: 1.0, h: 0.02);
      final han = tk.tokenBoundingBox('中A', 0, 1, box);
      final latin = tk.tokenBoundingBox('中A', 1, 1, box);
      expect(han.minX, closeTo(0.0, 1e-9));
      expect(han.width, closeTo(2 / 3, 1e-9));
      expect(latin.minX, closeTo(2 / 3, 1e-9));
      expect(latin.width, closeTo(1 / 3, 1e-9));
    });
  });

  group('accurate per-character boxes (Vision glyph geometry)', () {
    test(
        'token box is the horizontal union of real glyph boxes, not the '
        'proportional estimate', () {
      final box = lineBox(x: 0, y: 0.5, w: 1.0, h: 0.02);
      final charBoxes = <NormRect>[
        const NormRect(0.00, 0.40, 0.05, 0.05), // a
        const NormRect(0.05, 0.40, 0.05, 0.05), // b  -> "ab" x[0.00, 0.10]
        const NormRect(0.10, 0.40, 0.02, 0.05), // space
        const NormRect(0.55, 0.40, 0.15, 0.05), // c
        const NormRect(0.70, 0.40, 0.20, 0.05), // d  -> "cd" x[0.55, 0.90]
      ];
      final ab = tk.tokenBoundingBox('ab cd', 0, 2, box, charBoxes: charBoxes);
      final cd = tk.tokenBoundingBox('ab cd', 3, 2, box, charBoxes: charBoxes);
      expect(ab.minX, closeTo(0.00, 1e-9));
      expect(ab.width, closeTo(0.10, 1e-9)); // union, not 2/5 = 0.4
      expect(cd.minX, closeTo(0.55, 1e-9));
      expect(cd.width, closeTo(0.35, 1e-9));
      expect(ab.minY, closeTo(0.5, 1e-9));
      expect(ab.height, closeTo(0.02, 1e-9));
    });

    test(
        'a zero-size glyph gap falls back to the proportional estimate for '
        'that token only', () {
      final box = lineBox(x: 0, y: 0.5, w: 1.0, h: 0.02);
      final charBoxes = <NormRect>[
        const NormRect(0.00, 0.5, 0.05, 0.02), // a
        const NormRect(0.05, 0.5, 0.05, 0.02), // b  -> "ab" accurate x[0, 0.10]
        const NormRect(0.10, 0.5, 0.02, 0.02), // space
        const NormRect(0.0, 0.0, 0.0, 0.0), //    c: GAP (zero size)
        const NormRect(0.75, 0.5, 0.20, 0.02), // d
      ];
      final ab = tk.tokenBoundingBox('ab cd', 0, 2, box, charBoxes: charBoxes);
      final cd = tk.tokenBoundingBox('ab cd', 3, 2, box, charBoxes: charBoxes);
      expect(ab.width, closeTo(0.10, 1e-9)); // "ab" still accurate
      expect(cd.minX, closeTo(3 / 5, 1e-9));
      expect(cd.width, closeTo(2 / 5, 1e-9));
    });

    test('charBoxes shorter than the token range falls back to proportional', () {
      final box = lineBox(x: 0, y: 0.5, w: 1.0, h: 0.02);
      final charBoxes = <NormRect>[
        const NormRect(0.00, 0.5, 0.05, 0.02),
        const NormRect(0.05, 0.5, 0.05, 0.02),
      ];
      final cd = tk.tokenBoundingBox('ab cd', 3, 2, box, charBoxes: charBoxes);
      expect(cd.minX, closeTo(3 / 5, 1e-9));
      expect(cd.width, closeTo(2 / 5, 1e-9));
    });
  });

  group('refineCharBoxes (Vision returns one box per WORD, not per char)', () {
    test('subdivides a shared word box proportionally across its characters', () {
      const wordAb = NormRect(0.10, 0.5, 0.20, 0.02); // x[0.10, 0.30]
      const wordCd = NormRect(0.60, 0.5, 0.30, 0.02); // x[0.60, 0.90]
      final raw = <NormRect>[
        wordAb, wordAb, //              a, b
        const NormRect(0, 0, 0, 0), //        space (zero box)
        wordCd, wordCd, //              c, d
      ];
      final refined = tk.refineCharBoxes('ab cd', raw)!;
      expect(refined[0].minX, closeTo(0.10, 1e-9));
      expect(refined[0].maxX, closeTo(0.20, 1e-9));
      expect(refined[1].minX, closeTo(0.20, 1e-9));
      expect(refined[1].maxX, closeTo(0.30, 1e-9));
      expect(refined[2].isEmpty, isTrue);
      expect(refined[3].minX, closeTo(0.60, 1e-9));
      expect(refined[3].maxX, closeTo(0.75, 1e-9));
      expect(refined[4].minX, closeTo(0.75, 1e-9));
      expect(refined[4].maxX, closeTo(0.90, 1e-9));
    });

    test('CJK characters in a shared box subdivide 2x wider than Latin', () {
      const word = NormRect(0.0, 0.5, 0.30, 0.02); // x[0, 0.30]
      final refined = tk.refineCharBoxes('中A', <NormRect>[word, word])!;
      expect(refined[0].minX, closeTo(0.0, 1e-9));
      expect(refined[0].maxX, closeTo(0.20, 1e-9));
      expect(refined[1].minX, closeTo(0.20, 1e-9));
      expect(refined[1].maxX, closeTo(0.30, 1e-9));
    });

    test('leaves already-distinct boxes unchanged and is idempotent', () {
      final distinct = <NormRect>[
        const NormRect(0.00, 0.5, 0.05, 0.02),
        const NormRect(0.05, 0.5, 0.05, 0.02),
      ];
      final once = tk.refineCharBoxes('ab', distinct)!;
      final twice = tk.refineCharBoxes('ab', once)!;
      for (final r in [once, twice]) {
        expect(r[0].minX, closeTo(0.00, 1e-9));
        expect(r[0].maxX, closeTo(0.05, 1e-9));
        expect(r[1].minX, closeTo(0.05, 1e-9));
        expect(r[1].maxX, closeTo(0.10, 1e-9));
      }
    });

    test('null/misaligned charBoxes pass through untouched', () {
      expect(tk.refineCharBoxes('abc', null), isNull);
      final wrong = <NormRect>[const NormRect(0, 0.5, 0.1, 0.02)]; // 1 box, 3 chars
      expect(tk.refineCharBoxes('abc', wrong), same(wrong));
    });
  });

  group('isHanRun', () {
    test('true for a pure CJK-ideograph run', () {
      expect(Tokenizer.isHanRun('学习'), isTrue);
      expect(Tokenizer.isHanRun('我在学习中文'), isTrue);
      expect(Tokenizer.isHanRun('中'), isTrue);
    });

    test('false for empty, Latin, digits, and mixed', () {
      expect(Tokenizer.isHanRun(''), isFalse);
      expect(Tokenizer.isHanRun('vocabulary'), isFalse);
      expect(Tokenizer.isHanRun('123'), isFalse);
      expect(Tokenizer.isHanRun('学A'), isFalse);
    });

    test('false for kana / Hangul', () {
      expect(Tokenizer.isHanRun('ひらがな'), isFalse);
      expect(Tokenizer.isHanRun('한글'), isFalse);
    });
  });

  group('hanCharCount (drives the script-aware sentence heuristic)', () {
    test('counts CJK ideographs only', () {
      expect(Tokenizer.hanCharCount('我在学习中文'), 6);
      expect(Tokenizer.hanCharCount('我在学习中文。'), 6);
      expect(Tokenizer.hanCharCount('React框架'), 2);
      expect(Tokenizer.hanCharCount('中'), 1);
    });

    test('zero for non-CJK and empty', () {
      expect(Tokenizer.hanCharCount(''), 0);
      expect(Tokenizer.hanCharCount('serendipity'), 0);
      expect(Tokenizer.hanCharCount('ひらがな 한글'), 0);
    });
  });
}
