import 'package:capecho/agent_home.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Behavior-level tests for the rebuilt agent front door (AgentHome): the brand + the three clickable
// destinations + the best-effort "words kept · N due" status pulse. Fonts aren't bundled in the test
// harness, so these assert TEXT/CALLBACK behavior, never pixels (see the widget-test font caveat).

Widget _host(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('renders the brand front door: wordmark, tagline, capture hero, destinations', (
    tester,
  ) async {
    await tester.pumpWidget(_host(AgentHome(signedIn: false, onOpenSurface: (_) {})));
    await tester.pumpAndSettle();

    expect(find.textContaining('Capecho'), findsOneWidget); // the "Capecho." wordmark
    expect(find.textContaining('Capture the words you meet'), findsOneWidget); // tagline
    expect(find.text('Capture a word'), findsOneWidget); // capture hero
    expect(find.text('Review'), findsOneWidget);
    expect(find.text('Word Book'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('each destination row opens its surface on tap', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(_host(AgentHome(signedIn: false, onOpenSurface: opened.add)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Review'));
    await tester.tap(find.text('Word Book'));
    await tester.tap(find.text('Settings'));

    expect(opened, ['review', 'wordBook', 'settings']);
  });

  testWidgets('status pulse shows the kept count and the best-effort due figure', (tester) async {
    await tester.pumpWidget(
      _host(
        AgentHome(
          signedIn: true,
          loadWordCount: () async => 128,
          loadDueCount: () async => 3,
          onOpenSurface: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle(); // let the async kept + due fetches resolve

    expect(find.textContaining('128'), findsWidgets); // kept count
    expect(find.textContaining('3'), findsWidgets);
    expect(find.textContaining('due today'), findsOneWidget);
  });

  testWidgets('zero due reads "all caught up", not "0 due"', (tester) async {
    await tester.pumpWidget(
      _host(
        AgentHome(
          signedIn: true,
          loadWordCount: () async => 9,
          loadDueCount: () async => 0,
          onOpenSurface: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('all caught up'), findsOneWidget);
    expect(find.textContaining('due today'), findsNothing);
  });

  testWidgets('signed out: kept count shows, due line is omitted', (tester) async {
    await tester.pumpWidget(
      _host(AgentHome(signedIn: false, loadWordCount: () async => 7, onOpenSurface: (_) {})),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('7'), findsWidgets);
    expect(find.textContaining('due today'), findsNothing);
    expect(find.textContaining('all caught up'), findsNothing);
  });

  testWidgets('no kept words and no due figure: the status pulse is absent (no "0 words")', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(AgentHome(signedIn: false, loadWordCount: () async => 0, onOpenSurface: (_) {})),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('word kept'), findsNothing);
    expect(find.textContaining('words kept'), findsNothing);
  });

  testWidgets('a failed kept-count load omits the figure (best-effort, no stale number)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AgentHome(
          signedIn: true,
          loadWordCount: () async => throw Exception('offline'),
          loadDueCount: () async => 2,
          onOpenSurface: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The kept figure is simply absent; the due figure still renders (the two loads are independent).
    expect(find.textContaining('word kept'), findsNothing);
    expect(find.textContaining('words kept'), findsNothing);
    expect(find.textContaining('due today'), findsOneWidget);
  });

  testWidgets('Esc closes the front door (hides the window), like every other surface', (
    tester,
  ) async {
    var closed = 0;
    await tester.pumpWidget(
      _host(AgentHome(signedIn: false, onOpenSurface: (_) {}, onClose: () => closed++)),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(closed, 1);
  });

  testWidgets('⌘W also closes the front door', (tester) async {
    var closed = 0;
    await tester.pumpWidget(
      _host(AgentHome(signedIn: false, onOpenSurface: (_) {}, onClose: () => closed++)),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    expect(closed, 1);
  });

  testWidgets('destination rows show the live hotkey caps once resolved', (tester) async {
    await tester.pumpWidget(
      _host(
        AgentHome(
          signedIn: false,
          loadShortcutDisplays: () async => {'review': '⌥R', 'wordBook': '⌥B'},
          onOpenSurface: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Each glyph becomes its own key cap (ObKeyCap → Text); R/B are unique to their rows.
    expect(find.text('R'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
  });
}
