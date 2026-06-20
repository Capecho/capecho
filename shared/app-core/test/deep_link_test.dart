import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the capecho:// deep-link router — the widget/notification open Review at a
/// word through these links.
void main() {
  group('parseDeepLink', () {
    test('review with word + src', () {
      expect(
        parseDeepLink(Uri.parse('capecho://review?word=w1&src=widget')),
        const ReviewDeepLink(wordId: 'w1', source: 'widget'),
      );
    });

    test('review without a word opens Review with no jump; src defaults to widget', () {
      expect(parseDeepLink(Uri.parse('capecho://review')), const ReviewDeepLink(source: 'widget'));
      // A blank word is treated as absent.
      expect(
        parseDeepLink(Uri.parse('capecho://review?word=')),
        const ReviewDeepLink(source: 'widget'),
      );
    });

    test('review carries a notification source (Phase 2)', () {
      expect(
        parseDeepLink(Uri.parse('capecho://review?word=w2&src=notification')),
        const ReviewDeepLink(wordId: 'w2', source: 'notification'),
      );
    });

    test('capture is no longer routed', () {
      expect(parseDeepLink(Uri.parse('capecho://capture')), isNull);
    });

    test('a wrong scheme or unknown host is not routed', () {
      expect(parseDeepLink(Uri.parse('https://review?word=w1')), isNull);
      expect(parseDeepLink(Uri.parse('capecho://settings')), isNull);
      expect(parseDeepLink(Uri.parse('capecho://')), isNull);
    });
  });
}
