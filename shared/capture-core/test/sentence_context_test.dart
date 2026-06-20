import 'package:capecho_capture_core/capecho_capture_core.dart';
import 'package:test/test.dart';

void main() {
  group('sentence segmentation (rule-based stand-in for NLTokenizer)', () {
    test('splits on . ! ? when followed by space', () {
      const text = 'First one. Second two! Third three?';
      // cursor in the middle sentence.
      final r = LearningContextBuilder.build(text, text.indexOf('Second'));
      expect(r.sentence, 'Second two!');
    });

    test('"U.S." does NOT split — period followed by a letter', () {
      const text = 'I live in the U.S. now.';
      final r = LearningContextBuilder.build(text, 0);
      // The only sentence-ending period is the final one (followed by end).
      expect(r.sentence, 'I live in the U.S. now.');
    });

    test('"3.14" does NOT split — period inside a decimal', () {
      const text = 'Pi is 3.14 exactly. Tau is double.';
      final r = LearningContextBuilder.build(text, text.indexOf('Pi'));
      expect(r.sentence, 'Pi is 3.14 exactly.');
    });

    test('CJK terminators 。！？ split sentences', () {
      const text = '今天很好。明天会下雨！后天呢？';
      final r1 = LearningContextBuilder.build(text, 0);
      expect(r1.sentence, '今天很好。');
      final r2 = LearningContextBuilder.build(text, text.indexOf('明天'));
      expect(r2.sentence, '明天会下雨！');
      final r3 = LearningContextBuilder.build(text, text.indexOf('后天'));
      expect(r3.sentence, '后天呢？');
    });

    test('ellipsis … terminates a sentence', () {
      const text = 'Wait for it… here it comes.';
      final r = LearningContextBuilder.build(text, 0);
      expect(r.sentence, 'Wait for it…');
    });

    test('closing quote stays with the sentence it ends', () {
      const text = 'He said "go." Then he left.';
      final r = LearningContextBuilder.build(text, 0);
      expect(r.sentence, 'He said "go."');
    });
  });

  group('sentence nearest the cursor', () {
    test('picks the sentence containing the offset', () {
      const text = 'Alpha sentence. Beta sentence. Gamma sentence.';
      final r = LearningContextBuilder.build(text, text.indexOf('Beta'));
      expect(r.sentence, 'Beta sentence.');
    });

    test('an offset at the start of a sentence belongs to that sentence', () {
      const text = '前一句。守住现状。';
      final r = LearningContextBuilder.build(text, text.indexOf('守'));
      expect(r.sentence, '守住现状。');
    });

    test('offset beyond the end clamps to the last sentence', () {
      const text = 'Alpha. Beta.';
      final r = LearningContextBuilder.build(text, 9999);
      expect(r.sentence, 'Beta.');
    });
  });

  group('context window sizing (target 360 / max 600)', () {
    test('a single short sentence yields itself as context', () {
      const text = 'Just one short sentence here.';
      final r = LearningContextBuilder.build(text, 0);
      expect(r.context, 'Just one short sentence here.');
    });

    test('expands outward toward the target length', () {
      // Many ~30-char sentences; pick a middle one. The selected sentence
      // alone is < 360 so it must pull in neighbours, but stay <= 600.
      final sentences = List.generate(40, (i) => 'This is filler sentence number $i here.');
      final text = sentences.join(' ');
      final middle = text.indexOf('number 20');
      final r = LearningContextBuilder.build(text, middle);

      expect(r.context.runes.length, greaterThanOrEqualTo(360));
      expect(r.context.runes.length, lessThanOrEqualTo(600));
      // The selected sentence is part of the window.
      expect(r.context, contains('number 20'));
      // The single sentence is much shorter than the expanded context.
      expect(r.sentence, 'This is filler sentence number 20 here.');
      expect(r.context.length, greaterThan(r.sentence!.length));
    });

    test('clips an over-long single sentence with an ellipsis', () {
      // One sentence longer than maxContextLength (600 runes).
      final longSentence = '${'word ' * 200}end.';
      final r = LearningContextBuilder.build(longSentence, 0);
      expect(r.sentence, endsWith('…'));
      expect(r.sentence!.runes.length, lessThanOrEqualTo(601));
    });
  });

  // The clip() helper bounds the clipboard + selection capture paths (P1c) — those have no inherent
  // size limit (a multi-MB clipboard / whole-page selection), so without this a huge blob would flow
  // verbatim into the overlay, the fsync'd journal, and the /explain payload. Pin the EXACT bound here
  // (the cascade tests only assert <= 601, which is too loose to catch a broken clip).
  group('clip() — bounds an unbounded capture path (P1c)', () {
    const cap = LearningContextBuilder.maxContextLength; // 600

    test('a string under the cap is returned unchanged (no spurious ellipsis)', () {
      expect(LearningContextBuilder.clip('hello world'), 'hello world');
    });

    test('a string exactly AT the cap is unchanged — no ellipsis appended', () {
      final atCap = 'a' * cap;
      final r = LearningContextBuilder.clip(atCap);
      expect(r, atCap);
      expect(r, isNot(endsWith('…')));
      expect(r.runes.length, cap);
    });

    test('an over-long string clips to exactly cap+1 runes WITH the ellipsis', () {
      final clipped = LearningContextBuilder.clip('a' * 700);
      expect(clipped, endsWith('…'));
      expect(clipped.runes.length, cap + 1); // cap head runes + the single … = 601
    });

    test('clipping never splits a surrogate pair — emoji survive whole', () {
      // 700 emoji: each is ONE rune but TWO UTF-16 code units. A code-unit clip would slice a
      // surrogate pair in half (corrupt char); a rune clip keeps each emoji intact.
      final clipped = LearningContextBuilder.clip('😀' * 700);
      expect(clipped.runes.length, cap + 1);
      expect(clipped.runes.where((r) => r == 0x1F600).length, cap); // 600 whole emoji
      expect(clipped.runes.last, 0x2026); // … (no lone surrogate)
    });

    test('a custom maxLength is honored', () {
      expect(LearningContextBuilder.clip('a' * 50, 10).runes.length, 11); // 10 + …
    });
  });

  group('degenerate input', () {
    test('empty text -> null sentence, empty context', () {
      final r = LearningContextBuilder.build('', 0);
      expect(r.sentence, isNull);
      expect(r.context, '');
    });

    test('whitespace-only text -> null sentence', () {
      final r = LearningContextBuilder.build('     ', 2);
      expect(r.sentence, isNull);
    });
  });

  // Abbreviations were the dominant "captured only half the sentence" cause on real screens:
  // titles / ranks / "etc." carry a trailing period that the bare period-then-space rule mistook for
  // a sentence end, so a capture in the TAIL lost everything before the abbreviation.
  group('abbreviations do not split the sentence (real-screen regressions)', () {
    test('Lt. Gov. keeps the whole sentence (CNN politics)', () {
      const text = 'Trump has backed Lt. Gov. Pamela Evette in a crowded field of GOP hopefuls.';
      final r = LearningContextBuilder.build(text, text.indexOf('Pamela'));
      expect(r.sentence, text); // not just "Pamela Evette in a crowded field of GOP hopefuls."
    });

    test('Sen. / Gov. inside a long sentence stay attached (CNN politics)', () {
      const text = 'Democrats are likely to nominate Marine veteran Graham Platner to take on '
          'Republican Sen. Susan Collins, but his performance against Gov. Janet Mills could be '
          'an indicator.';
      final r = LearningContextBuilder.build(text, text.indexOf('Janet'));
      expect(r.sentence, text);
    });

    test('"etc.)" does not split (GitHub PR copy)', () {
      const text = 'OCR uses Vision auto-detection, decoupled from your languages — a mixed-script '
          'page (中文 + English, etc.) reads accurately instead of garbling the minority script.';
      final r = LearningContextBuilder.build(text, text.indexOf('garbling'));
      expect(r.sentence, text);
    });

    test('Dr./Mr. do not split, but a genuine terminator still ends the sentence', () {
      const text = 'Dr. Smith met Mr. Jones at noon. They talked for an hour.';
      expect(
        LearningContextBuilder.build(text, text.indexOf('Jones')).sentence,
        'Dr. Smith met Mr. Jones at noon.',
      );
      expect(
        LearningContextBuilder.build(text, text.indexOf('talked')).sentence,
        'They talked for an hour.',
      );
    });

    test('an ordinary (non-abbreviation) word before a period still splits', () {
      const text = 'I went to the store. Then I came home.';
      expect(
        LearningContextBuilder.build(text, text.indexOf('went')).sentence,
        'I went to the store.',
      );
    });
  });

  // A headline / label with NO terminal punctuation is one whole "sentence" — the segmenter must
  // return the entire block, not nothing (CNN front-page headline wraps two visual lines).
  group('no-terminator blocks are captured whole', () {
    test('a punctuation-less headline is one sentence', () {
      const text = 'US launches strikes against Iran in response to helicopter downing';
      final r = LearningContextBuilder.build(text, text.indexOf('helicopter'));
      expect(r.sentence, text);
    });
  });

  // OCR can inject invisible / zero-width / control characters, and at a wrapped
  // line join a stray space lands between two CJK characters (CJK has no
  // inter-character spacing). sanitizeOutput scrubs both from the final
  // sentence/context WITHOUT disturbing Latin word spacing or CJK↔Latin
  // boundaries. (Invisible scalars are built via fromCharCode — never written as
  // literal escapes, which would re-inject control bytes into this source.)
  group('sanitizeOutput scrubs OCR noise', () {
    String sani(String s) => LearningContextBuilder.sanitizeOutput(s);
    String ch(int c) => String.fromCharCode(c);

    test('drops invisible / zero-width / control / soft-hyphen / BOM scalars', () {
      final noisy = 'a${ch(0x200B)}b${ch(0xFEFF)}c${ch(0x00)}d${ch(0x200D)}e${ch(0xAD)}f';
      expect(sani(noisy), 'abcdef');
    });

    test('drops a regular space between two Han characters (wrap-join artifact)', () {
      expect(sani('必须拿文 本'), '必须拿文本');
    });

    test('drops an ideographic / NBSP space between CJK', () {
      expect(sani('文${ch(0x3000)}本'), '文本');
      expect(sani('文${ch(0xA0)}本'), '文本');
    });

    test('collapses inter-CJK spaces across a run (overlapping matches)', () {
      expect(sani('我 爱 你'), '我爱你');
    });

    test('keeps Latin word spacing and collapses runs to one space', () {
      expect(sani('hello   world'), 'hello world');
    });

    test('keeps a CJK↔Latin boundary space', () {
      expect(sani('中文 English 中文'), '中文 English 中文');
      expect(sani('我爱 coding 很好'), '我爱 coding 很好');
    });

    test('kana and Hangul inter-character spaces drop too', () {
      expect(sani('こん にちは'), 'こんにちは');
      expect(sani('안녕 하세요'), '안녕하세요');
    });

    test('is idempotent', () {
      expect(sani(sani('必须拿文 本')), '必须拿文本');
    });

    test('empty stays empty', () {
      expect(sani(''), '');
    });
  });
}
