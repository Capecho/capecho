import 'package:capecho_capture_core/capecho_capture_core.dart';
import 'package:test/test.dart';

void main() {
  group('dominantScript', () {
    test('classifies single-script units', () {
      expect(dominantScript('hello'), UnitScript.latin);
      expect(dominantScript('café'), UnitScript.latin); // accented Latin
      expect(dominantScript('中文'), UnitScript.han);
      expect(dominantScript('한국어'), UnitScript.hangul);
      expect(dominantScript('Привет'), UnitScript.cyrillic);
    });

    test('kana presence wins over Han (Japanese) ', () {
      expect(dominantScript('勉強する'), UnitScript.kana); // kanji + kana → ja
      expect(dominantScript('がくしゅう'), UnitScript.kana);
      expect(dominantScript('勉強'), UnitScript.han); // pure kanji → Han (zh default)
    });

    test('Han wins over Latin in a mixed token; symbols/empty are other', () {
      expect(dominantScript('中A'), UnitScript.han);
      expect(dominantScript(''), UnitScript.other);
      expect(dominantScript('123 …'), UnitScript.other);
    });
  });

  group('scriptsOfLanguage', () {
    test('maps learning tags to their writing systems', () {
      expect(scriptsOfLanguage('en'), {UnitScript.latin});
      expect(scriptsOfLanguage('es'), {UnitScript.latin});
      expect(scriptsOfLanguage('zh-Hans'), {UnitScript.han});
      expect(scriptsOfLanguage('ja'), {UnitScript.han, UnitScript.kana});
      expect(scriptsOfLanguage('ko'), {UnitScript.hangul});
      expect(scriptsOfLanguage('ru'), {UnitScript.cyrillic});
      expect(scriptsOfLanguage('xx'), {UnitScript.latin}); // unknown → Latin
    });
  });

  group('effectiveTargetLanguage — auto-switch on script-disjoint certainty', () {
    test('learning English, a 中文 unit auto-switches to Chinese (the core case)', () {
      expect(effectiveTargetLanguage(unit: '中文', learningLanguage: 'en'), 'zh-Hans');
      expect(effectiveTargetLanguage(unit: '猫', learningLanguage: 'en'), 'zh-Hans');
    });

    test('learning English, a Korean / Japanese-kana unit switches to ko / ja', () {
      expect(effectiveTargetLanguage(unit: '한국어', learningLanguage: 'en'), 'ko');
      expect(effectiveTargetLanguage(unit: 'がくしゅう', learningLanguage: 'en'), 'ja');
      expect(effectiveTargetLanguage(unit: '勉強する', learningLanguage: 'en'), 'ja'); // kana → ja
    });
  });

  group('effectiveTargetLanguage — no switch (compatible or deferred)', () {
    test('same-script units keep the configured target', () {
      expect(effectiveTargetLanguage(unit: 'hello', learningLanguage: 'en'), 'en');
      expect(
          effectiveTargetLanguage(unit: 'casa', learningLanguage: 'en'), 'en'); // en-vs-es deferred
      expect(effectiveTargetLanguage(unit: '中文', learningLanguage: 'zh-Hans'), 'zh-Hans');
      expect(effectiveTargetLanguage(unit: '勉強', learningLanguage: 'ja'), 'ja'); // Han ∈ ja
      expect(effectiveTargetLanguage(unit: 'がく', learningLanguage: 'ja'), 'ja');
    });

    test('a Latin unit while learning a CJK target is NOT guessed (deferred)', () {
      // Which Latin language ("hello" → en? something else?) needs real detection,
      // so Phase 1 leaves the configured target rather than hard-code English.
      expect(effectiveTargetLanguage(unit: 'hello', learningLanguage: 'zh-Hans'), 'zh-Hans');
    });

    test('an empty unit keeps the configured target', () {
      expect(effectiveTargetLanguage(unit: '', learningLanguage: 'en'), 'en');
      expect(effectiveTargetLanguage(unit: '   ', learningLanguage: 'en'), 'en');
    });

    test('a Chinese learner capturing a kana word switches to Japanese', () {
      expect(effectiveTargetLanguage(unit: 'がく', learningLanguage: 'zh-Hans'), 'ja');
    });
  });

  group('suggestedTargetLanguage — the same-script / which-Latin confirm', () {
    String? suggest(String unit, String target, String? lang, double conf) =>
        suggestedTargetLanguage(
          unit: unit,
          effectiveTarget: target,
          spanLanguage: lang,
          spanLanguageConfidence: conf,
        );

    test('reading a Spanish passage while learning English suggests Spanish', () {
      expect(suggest('casa', 'en', 'es', 0.95), 'es');
    });

    test('a Latin word while learning Chinese suggests the detected Latin language', () {
      // effectiveTargetLanguage left this on zh-Hans (Latin → which? deferred); the
      // span detection picks it up.
      expect(suggest('hello', 'zh-Hans', 'en', 0.97), 'en');
    });

    test('NEVER second-guesses a script-disjoint unit the auto-switch already set', () {
      // A 中文 unit captured while reading English → effectiveTargetLanguage set
      // zh-Hans. The span is English, but the unit is Han, so the English span must
      // NOT drag the target back to English.
      expect(suggest('中文', 'zh-Hans', 'en', 0.99), isNull);
    });

    test('no suggestion when the span language equals the target', () {
      expect(suggest('hello', 'en', 'en', 0.99), isNull);
    });

    test('no suggestion below the confidence gate', () {
      expect(suggest('casa', 'en', 'es', 0.40), isNull);
    });

    test('no suggestion for an unsupported / undetected language', () {
      expect(suggest('hallo', 'en', 'nl', 0.95), isNull); // Dutch: not a supported target
      expect(suggest('casa', 'en', null, 0.0), isNull);
    });
  });

  group('CursorVisualSpan detected-language round-trip', () {
    test('detectedLanguage + confidence survive fromMap/toMap', () {
      const span = CursorVisualSpan(
        text: 'Hola mundo',
        lineIndices: [0],
        anchor: CursorVisualSpanAnchor(
          lineIndex: 0,
          runIndex: 0,
          position: 'inside',
          fontSizePx: 20,
          fontSizePt: 10,
          lineHeightPx: 24,
          lineHeightPt: 12,
        ),
        segments: [],
        detectedLanguage: 'es',
        detectedLanguageConfidence: 0.93,
      );
      final round = CursorVisualSpan.fromMap(span.toMap());
      expect(round.detectedLanguage, 'es');
      expect(round.detectedLanguageConfidence, closeTo(0.93, 1e-9));
    });

    test('a span with no detected language round-trips to null + zero confidence', () {
      const span = CursorVisualSpan(
        text: 'hi',
        lineIndices: [0],
        anchor: CursorVisualSpanAnchor(
          lineIndex: 0,
          runIndex: 0,
          position: 'inside',
          fontSizePx: 20,
          fontSizePt: 10,
          lineHeightPx: 24,
          lineHeightPt: 12,
        ),
        segments: [],
      );
      final round = CursorVisualSpan.fromMap(span.toMap());
      expect(round.detectedLanguage, isNull);
      expect(round.detectedLanguageConfidence, 0);
    });
  });

  group('CR-flagged cases', () {
    test('a pure-kanji unit in a Japanese span suggests ja (the only Han Phase-2 case)', () {
      // effectiveTargetLanguage left 勉強 on zh-Hans (Han default); a confidently-Japanese span
      // (ja's scripts include Han) is the one case Phase 2 fires on a Han unit → "switch to Japanese?".
      expect(
        suggestedTargetLanguage(
          unit: '勉強',
          effectiveTarget: 'zh-Hans',
          spanLanguage: 'ja',
          spanLanguageConfidence: 0.97,
        ),
        'ja',
      );
    });

    test('the confidence gate is inclusive at exactly 0.65', () {
      expect(
        suggestedTargetLanguage(
          unit: 'casa',
          effectiveTarget: 'en',
          spanLanguage: 'es',
          spanLanguageConfidence: 0.65,
        ),
        'es',
      );
      expect(
        suggestedTargetLanguage(
          unit: 'casa',
          effectiveTarget: 'en',
          spanLanguage: 'es',
          spanLanguageConfidence: 0.649,
        ),
        isNull,
      );
    });

    test('a Cyrillic unit is neither auto-switched nor suggested (no supported target)', () {
      expect(effectiveTargetLanguage(unit: 'Привет', learningLanguage: 'en'), 'en');
      expect(
        suggestedTargetLanguage(
          unit: 'Привет',
          effectiveTarget: 'en',
          spanLanguage: 'ru',
          spanLanguageConfidence: 0.98,
        ),
        isNull,
      );
    });
  });

  // The context-language axis: a sentence's language is named ONLY when its script alone
  // pins one (the same accepted Han→zh-Hans / kana→ja defaults as the unit auto-switch).
  // Mirrored natively in UnitLanguageTests (Swift) — keep the cases in parity.
  group('scriptCertainLanguage', () {
    test('mono-script CJK sentences pin their language', () {
      expect(scriptCertainLanguage('我们今天学习新词。'), 'zh-Hans');
      expect(scriptCertainLanguage('第3章：序言'), 'zh-Hans'); // digits/symbols don't break certainty
      expect(scriptCertainLanguage('勉強が好きです。'), 'ja'); // kana (+kanji) pins Japanese
      expect(scriptCertainLanguage('한국어를 공부해요.'), 'ko');
    });

    test('any Latin or Cyrillic letter kills certainty — including the normal mixed capture', () {
      expect(
          scriptCertainLanguage('The word 学习 means to study.'), isNull); // zh unit in an en article
      expect(scriptCertainLanguage('我们学习 English'), isNull);
      expect(scriptCertainLanguage('Hello world.'), isNull); // which Latin language? never certain
      expect(scriptCertainLanguage('café au lait'), isNull); // accented Latin too
      expect(scriptCertainLanguage('Привет мир'), isNull); // Cyrillic never pins a language here
    });

    test('degenerate inputs are unknown, and a kana+hangul mix is nonsense (null)', () {
      expect(scriptCertainLanguage(''), isNull);
      expect(scriptCertainLanguage('123 …'), isNull); // no letters at all
      expect(scriptCertainLanguage('한국어です'), isNull); // hangul+kana — no single language
    });

    test('a letter of ANY non-pinning script kills certainty (not just Latin/Cyrillic)', () {
      expect(scriptCertainLanguage('كتاب 书'), isNull); // Arabic-dominant + one Han char
      expect(scriptCertainLanguage('ＨＥＬＬＯ 学习'), isNull); // full-width Latin (FF21–FF5A)
      expect(scriptCertainLanguage('𝐀𝐁 学习'), isNull); // astral math alphanumerics
      expect(scriptCertainLanguage('สวัสดี 中文'), isNull); // Thai
    });

    test('々 (the CJK iteration mark) counts as Han, not as a certainty-killing letter', () {
      expect(scriptCertainLanguage('人々の暮らし'), 'ja'); // everyday ja with 々 + kana
      expect(scriptCertainLanguage('山々相连。'), 'zh-Hans'); // pure Han + 々
    });
  });
}
