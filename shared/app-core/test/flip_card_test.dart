import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shared review-card flip (front↔back), adopted by both clients. FlipCard shows ONE face at a time
/// (the front until past the edge-on midpoint, then the back), so the hidden face is absent from the tree.
void main() {
  Future<void> pump(WidgetTester tester, {required bool showBack, required Object cardId}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FlipCard(
              showBack: showBack,
              cardId: cardId,
              front: const Text('FRONT'),
              back: const Text('BACK'),
            ),
          ),
        ),
      );

  testWidgets('shows the front while not flipped', (tester) async {
    await pump(tester, showBack: false, cardId: 'c1');
    await tester.pumpAndSettle();
    expect(find.text('FRONT'), findsOneWidget);
    expect(find.text('BACK'), findsNothing);
  });

  testWidgets('animates to the back when showBack turns true (same card)', (tester) async {
    await pump(tester, showBack: false, cardId: 'c1');
    await tester.pumpAndSettle();
    // Same cardId, showBack flips → the turn animates; settle to the end of the 360ms flip.
    await pump(tester, showBack: true, cardId: 'c1');
    await tester.pumpAndSettle();
    expect(find.text('BACK'), findsOneWidget);
    expect(find.text('FRONT'), findsNothing);
  });

  testWidgets('a new card jumps straight to its front (no turn across the swap)', (tester) async {
    await pump(tester, showBack: true, cardId: 'c1');
    await tester.pumpAndSettle();
    expect(find.text('BACK'), findsOneWidget);
    // Advancing to a different card while the controller resets showBack → front, with no flip.
    await pump(tester, showBack: false, cardId: 'c2');
    await tester.pump();
    expect(find.text('FRONT'), findsOneWidget);
    expect(find.text('BACK'), findsNothing);
  });
}
