import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter_test/flutter_test.dart';

// Pins the FULL pronunciation display table — the Dart mirror of shared/lang's
// TargetGenerationProfile.pronunciationLabels (the TS side is the contract of record; this
// test is what catches silent drift before Phase D flips zh-Hans on). The en row is also
// covered end-to-end elsewhere (overlay controller / word-book widget tests); the zh and
// default rows have no other Dart coverage.
void main() {
  test('en: labeled US/UK, slashed IPA, region-insensitive', () {
    for (final tag in ['en', 'en-US', 'en-GB']) {
      final parts = pronunciationParts(
        targetLanguage: tag,
        primary: 'ˈɑbdʒɛkt',
        secondary: 'ˈɒbdʒɪkt',
      );
      expect(parts.map((p) => p.label), ['US', 'UK']);
      expect(parts.map((p) => p.display), ['/ˈɑbdʒɛkt/', '/ˈɒbdʒɪkt/']);
    }
  });

  test('zh: unlabeled, unslashed pinyin (both slots)', () {
    final parts = pronunciationParts(targetLanguage: 'zh-Hans', primary: 'xíng', secondary: 'háng');
    expect(parts.map((p) => p.label), [null, null]);
    expect(parts.map((p) => p.display), ['xíng', 'háng']); // bare — never /slashed/
  });

  test('unknown target degrades to unlabeled plain text (safe default)', () {
    final parts = pronunciationParts(targetLanguage: 'xx', primary: 'foo', secondary: '');
    expect(parts.single.label, isNull);
    expect(parts.single.display, 'foo');
  });

  test('empty slots are skipped (omit-on-fail pronunciations; zh has no second slot)', () {
    final parts = pronunciationParts(targetLanguage: 'en', primary: '', secondary: 'ˈɒbdʒɪkt');
    expect(parts.single.label, 'UK');
    expect(pronunciationParts(targetLanguage: 'zh-Hans', primary: '', secondary: ''), isEmpty);
  });
}
