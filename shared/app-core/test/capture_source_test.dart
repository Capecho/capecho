import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shared "where I met this word" caption (capture provenance) — app + window title, shown
/// read-only under the sentence on the Review card back and each Word Book context.
void main() {
  const p = OnboardingPalette.lightForTest;

  Future<void> pump(WidgetTester tester, Widget? child) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: child ?? const SizedBox.shrink())));

  test('returns null when there is no source (so the caller omits it entirely)', () {
    expect(captureSourceCaption(p), isNull);
    expect(captureSourceCaption(p, sourceApp: '', sourceTitle: '   '), isNull);
  });

  testWidgets('renders the app and the title together', (tester) async {
    await pump(
      tester,
      captureSourceCaption(p, sourceApp: 'Google Chrome', sourceTitle: 'Serendipity — Wikipedia'),
    );
    expect(find.textContaining('Google Chrome'), findsOneWidget);
    expect(find.textContaining('Serendipity — Wikipedia'), findsOneWidget);
  });

  testWidgets('renders with only an app (no title) and only a title (no app)', (tester) async {
    await pump(tester, captureSourceCaption(p, sourceApp: 'Books'));
    expect(find.textContaining('Books'), findsOneWidget);

    await pump(tester, captureSourceCaption(p, sourceTitle: 'A private note'));
    expect(find.textContaining('A private note'), findsOneWidget);
  });
}
