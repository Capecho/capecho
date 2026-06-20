import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records writes so a test can assert what was persisted, and seeds an initial mode so [load] has
/// something to hydrate. Pure Dart — no plugin, mirroring how each client's real store is swapped out.
class _FakeAppearanceStore implements AppearanceStore {
  _FakeAppearanceStore([this._stored = ThemeMode.system]);
  ThemeMode _stored;
  final List<ThemeMode> writes = [];

  @override
  Future<ThemeMode> read() async => _stored;

  @override
  Future<void> write(ThemeMode mode) async {
    _stored = mode;
    writes.add(mode);
  }
}

void main() {
  group('themeMode codec', () {
    test('round-trips every value', () {
      for (final m in ThemeMode.values) {
        expect(themeModeFromString(themeModeToString(m)), m);
      }
    });

    test('unknown / null / empty falls back to system', () {
      expect(themeModeFromString(null), ThemeMode.system);
      expect(themeModeFromString(''), ThemeMode.system);
      expect(themeModeFromString('sepia'), ThemeMode.system);
    });
  });

  group('AppearanceController', () {
    test('defaults to system before load', () {
      expect(AppearanceController().mode, ThemeMode.system);
    });

    test('load() hydrates from the store and notifies', () async {
      final c = AppearanceController(store: _FakeAppearanceStore(ThemeMode.dark));
      var notified = 0;
      c.addListener(() => notified++);

      await c.load();

      expect(c.mode, ThemeMode.dark);
      expect(notified, 1);
    });

    test('setMode updates, notifies, and persists', () async {
      final store = _FakeAppearanceStore();
      final c = AppearanceController(store: store);
      var notified = 0;
      c.addListener(() => notified++);

      await c.setMode(ThemeMode.light);

      expect(c.mode, ThemeMode.light);
      expect(notified, 1);
      expect(store.writes, [ThemeMode.light]);
    });

    test('setMode to the current value is a no-op (no notify, no write)', () async {
      final store = _FakeAppearanceStore();
      final c = AppearanceController(store: store);
      var notified = 0;
      c.addListener(() => notified++);

      await c.setMode(ThemeMode.system); // already system

      expect(notified, 0);
      expect(store.writes, isEmpty);
    });

    test('a store read failure leaves the system default rather than throwing', () async {
      final c = AppearanceController(store: _ThrowingStore());
      await c.load(); // must not throw
      expect(c.mode, ThemeMode.system);
    });
  });

  group('AppearanceControl', () {
    Future<void> pump(WidgetTester tester, ThemeMode mode, ValueChanged<ThemeMode> onChanged) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AppearanceControl(
                p: OnboardingPalette.lightForTest,
                mode: mode,
                onChanged: onChanged,
              ),
            ),
          ),
        );

    testWidgets('renders the three segments', (tester) async {
      await pump(tester, ThemeMode.system, (_) {});
      expect(find.text('System'), findsOneWidget);
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
    });

    testWidgets('tapping an inactive segment reports the new mode', (tester) async {
      ThemeMode? picked;
      await pump(tester, ThemeMode.system, (m) => picked = m);

      await tester.tap(find.text('Dark'));
      expect(picked, ThemeMode.dark);
    });

    testWidgets('tapping the already-selected segment does nothing', (tester) async {
      var calls = 0;
      await pump(tester, ThemeMode.light, (_) => calls++);

      await tester.tap(find.text('Light'));
      expect(calls, 0);
    });
  });
}

/// A store whose read always fails — proves [AppearanceController.load] swallows it.
class _ThrowingStore implements AppearanceStore {
  @override
  Future<ThemeMode> read() async => throw StateError('boom');
  @override
  Future<void> write(ThemeMode mode) async {}
}
