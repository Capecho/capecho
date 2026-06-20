import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, {bool dark = false, double width = 200}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
        home: Scaffold(
          body: Center(child: WordBookEmptyArt(width: width)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders without error in light + dark and honours its width', (tester) async {
    await pump(tester, width: 184);
    expect(tester.getSize(find.byType(WordBookEmptyArt)), const Size(184, 184 * 168 / 200));
    expect(tester.takeException(), isNull);

    await pump(tester, dark: true);
    expect(tester.takeException(), isNull);
  });
}
