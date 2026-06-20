import 'package:capecho/capture_shortcut_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CaptureShortcutScope.modifierGlyphs', () {
    String mods(String display) =>
        CaptureShortcutScope(display: display, child: const SizedBox()).modifierGlyphs;

    test('peels off the trailing key for single-modifier displays', () {
      expect(mods('⌥E'), '⌥');
      expect(mods('⌘A'), '⌘');
      expect(mods('⌃,'), '⌃');
    });

    test('preserves multiple stacked modifier glyphs', () {
      expect(mods('⌘⇧F'), '⌘⇧');
      expect(mods('⌃⌥⇧Q'), '⌃⌥⇧');
    });

    test('returns the whole string when the display has no key suffix', () {
      // The recorder rejects modifier-only shortcuts, so this is paranoid, but
      // the helper must still degrade gracefully.
      expect(mods('⌥'), '⌥');
      expect(mods('⌘⇧'), '⌘⇧');
    });

    test('returns the whole string for an empty display', () {
      expect(mods(''), '');
    });
  });

  group('CaptureShortcutScope.displayOf / modifiersOf', () {
    testWidgets('returns the nearest scope value through pushed routes', (tester) async {
      // Mirrors the production tree shape: scope ABOVE MaterialApp so widgets
      // built into routes the Navigator pushes (Settings / onboarding replay /
      // Word Book / Review) still inherit the live display. Wrapping the scope
      // inside MaterialApp.home would leave every pushed route on the '⌥E' fallback.
      late BuildContext pushedContext;
      await tester.pumpWidget(
        CaptureShortcutScope(
          display: '⌘⇧F',
          child: MaterialApp(
            home: Builder(
              builder: (rootContext) => ElevatedButton(
                onPressed: () => Navigator.of(rootContext).push(
                  MaterialPageRoute<void>(
                    builder: (routeContext) {
                      pushedContext = routeContext;
                      return const SizedBox.shrink();
                    },
                  ),
                ),
                child: const Text('Push'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Push'));
      await tester.pumpAndSettle();

      expect(CaptureShortcutScope.displayOf(pushedContext), '⌘⇧F');
      expect(CaptureShortcutScope.modifiersOf(pushedContext), '⌘⇧');
    });

    testWidgets('falls back to ⌥E when no scope is mounted', (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (innerContext) {
              context = innerContext;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(CaptureShortcutScope.displayOf(context), '⌥E');
      expect(CaptureShortcutScope.modifiersOf(context), '⌥');
    });
  });
}
