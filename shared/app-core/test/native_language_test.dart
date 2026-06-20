import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the allowlist mirrors shared/lang EXPLANATION_LANGUAGES', () {
    expect(explanationLanguages, ['en', 'es', 'de', 'it', 'fr', 'pt', 'zh-Hans', 'ja', 'ko']);
  });

  group('resolveNativeLanguage', () {
    test('maps a direct primary subtag, ignoring region', () {
      expect(resolveNativeLanguage('en-US'), 'en');
      expect(resolveNativeLanguage('pt-BR'), 'pt');
      expect(resolveNativeLanguage('ja-JP'), 'ja');
      expect(resolveNativeLanguage('fr'), 'fr');
    });

    test('maps every Chinese variant to Simplified (the only allowlisted zh)', () {
      expect(resolveNativeLanguage('zh-Hans-CN'), 'zh-Hans');
      expect(resolveNativeLanguage('zh_CN'), 'zh-Hans'); // underscore form
      expect(resolveNativeLanguage('zh-Hant-TW'), 'zh-Hans'); // Traditional → closest allowlisted
      expect(resolveNativeLanguage('zh'), 'zh-Hans');
    });

    test('falls back to English for anything off the allowlist or empty', () {
      expect(resolveNativeLanguage('ru-RU'), 'en');
      expect(resolveNativeLanguage('ar'), 'en');
      expect(resolveNativeLanguage(''), 'en');
      expect(resolveNativeLanguage('-'), 'en');
    });

    test('every resolved value is itself on the allowlist', () {
      for (final tag in ['en-US', 'zh-Hant-HK', 'ko-KR', 'xx-YY', 'de-AT', 'it']) {
        expect(explanationLanguages, contains(resolveNativeLanguage(tag)));
      }
    });
  });
}
