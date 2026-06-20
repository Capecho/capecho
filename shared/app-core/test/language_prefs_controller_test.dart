import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records writes so a test can assert what was persisted, and seeds an initial value so [load] has
/// something to hydrate. Pure Dart — no plugin, mirroring how each client's real store is swapped out.
class _FakeStore implements LanguagePrefsStore {
  _FakeStore([this._stored = LanguagePrefs.fallback]);
  LanguagePrefs _stored;
  final List<LanguagePrefs> writes = [];

  @override
  Future<LanguagePrefs> read() async => _stored;

  @override
  Future<void> write(LanguagePrefs prefs) async {
    _stored = prefs;
    writes.add(prefs);
  }
}

/// A store whose read always fails — proves [LanguagePrefsController.load] swallows it.
class _ThrowingStore implements LanguagePrefsStore {
  @override
  Future<LanguagePrefs> read() async => throw StateError('boom');
  @override
  Future<void> write(LanguagePrefs prefs) async {}
}

/// Lets the fire-and-forget persist (an unawaited microtask) settle before asserting writes.
Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  group('LanguagePrefs', () {
    test('fallback is explicit English (Lane C: native is a direct pick, no follow)', () {
      expect(LanguagePrefs.fallback.learningLanguage, 'en');
      expect(LanguagePrefs.fallback.explanationLanguage, 'en');
      expect(LanguagePrefs.fallback.explanationFollowsLearning, isFalse);
      expect(LanguagePrefs.fallback.effectiveExplanationLanguage, 'en');
    });

    test('effective gloss follows the learning language while follow is on', () {
      const p = LanguagePrefs(
        learningLanguage: 'de',
        explanationLanguage: 'fr', // ignored while following
        explanationFollowsLearning: true,
      );
      expect(p.effectiveExplanationLanguage, 'de');
    });

    test('effective gloss is the explicit pick once follow is off', () {
      const p = LanguagePrefs(
        learningLanguage: 'de',
        explanationLanguage: 'fr',
        explanationFollowsLearning: false,
      );
      expect(p.effectiveExplanationLanguage, 'fr');
    });

    test('value equality (so a no-op write is skipped)', () {
      expect(
        const LanguagePrefs(
          learningLanguage: 'es',
          explanationLanguage: 'en',
          explanationFollowsLearning: true,
        ),
        const LanguagePrefs(
          learningLanguage: 'es',
          explanationLanguage: 'en',
          explanationFollowsLearning: true,
        ),
      );
    });
  });

  group('LanguagePrefsController', () {
    test('defaults to the English fallback before load', () {
      final c = LanguagePrefsController();
      expect(c.learningLanguage, 'en');
      expect(c.explanationFollowsLearning, isFalse);
      expect(c.effectiveExplanationLanguage, 'en');
    });

    test('load() hydrates from the store and notifies', () async {
      final c = LanguagePrefsController(
        store: _FakeStore(
          const LanguagePrefs(
            learningLanguage: 'de',
            explanationLanguage: 'en',
            explanationFollowsLearning: false,
          ),
        ),
      );
      var notified = 0;
      c.addListener(() => notified++);

      await c.load();

      expect(c.learningLanguage, 'de');
      expect(c.explanationFollowsLearning, isFalse);
      expect(notified, 1);
    });

    test(
      'setLearningLanguage updates, notifies, and persists; native gloss is independent',
      () async {
        final store = _FakeStore();
        final c = LanguagePrefsController(store: store);
        var notified = 0;
        c.addListener(() => notified++);

        c.setLearningLanguage('es');

        expect(c.learningLanguage, 'es');
        expect(c.effectiveExplanationLanguage, 'en'); // native does NOT follow learning
        expect(notified, 1);
        await tick();
        expect(store.writes.single.learningLanguage, 'es');
      },
    );

    test('setExplanationLanguage turns OFF follow (an explicit pick)', () async {
      final store = _FakeStore();
      final c = LanguagePrefsController(store: store);

      c.setExplanationLanguage('fr');

      expect(c.explanationFollowsLearning, isFalse);
      expect(c.explanationLanguage, 'fr');
      expect(c.effectiveExplanationLanguage, 'fr');
      await tick();
      expect(store.writes.single.explanationFollowsLearning, isFalse);
    });

    test('setAll applies the whole onboarding choice at once', () async {
      final store = _FakeStore();
      final c = LanguagePrefsController(store: store);

      c.setAll(
        learningLanguage: 'pt',
        explanationLanguage: 'en',
        explanationFollowsLearning: false,
      );

      expect(c.learningLanguage, 'pt');
      expect(c.explanationFollowsLearning, isFalse);
      await tick();
      expect(store.writes.single.learningLanguage, 'pt');
    });

    test('setting the current value is a no-op (no notify, no write)', () async {
      final store = _FakeStore();
      final c = LanguagePrefsController(store: store);
      var notified = 0;
      c.addListener(() => notified++);

      c.setLearningLanguage('en'); // already the English default

      expect(notified, 0);
      await tick();
      expect(store.writes, isEmpty);
    });

    test('a store read failure leaves the English fallback rather than throwing', () async {
      final c = LanguagePrefsController(store: _ThrowingStore());
      await c.load(); // must not throw
      expect(c.learningLanguage, 'en');
      expect(c.explanationFollowsLearning, isFalse);
    });
  });
}
