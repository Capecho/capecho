import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, {bool disableAnimations = false, double size = 28}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Scaffold(
            body: Center(
              child: ObEchoLoader(color: const Color(0xFF644A40), size: size),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('animates without throwing and keeps repainting across frames', (tester) async {
    await pump(tester);
    // The sweep loops forever, so the controller never settles — pumpAndSettle would
    // time out. Step a few frames and assert it stays alive (no exception).
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ObEchoLoader), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('honours its size', (tester) async {
    await pump(tester, size: 44);
    expect(tester.getSize(find.byType(ObEchoLoader)), const Size(44, 44));
  });

  testWidgets('reduced motion falls back to the still mark (no animation)', (tester) async {
    await pump(tester, disableAnimations: true);
    // Reduced motion shows the static ObEchoMark instead of the sweep — so the tree
    // settles (a running AnimationController would make pumpAndSettle hang).
    await tester.pumpAndSettle();
    expect(find.byType(ObEchoMark), findsOneWidget);
  });
}
