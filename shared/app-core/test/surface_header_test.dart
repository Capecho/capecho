import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpHeader(
    WidgetTester tester, {
    String? title,
    Widget? trailing,
    VoidCallback? onBack,
    double width = 800,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              final p = OnboardingPalette.of(context);
              return Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: width,
                  child: SurfaceHeader(p: p, title: title, trailing: trailing, onBack: onBack),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  testWidgets('trailing meta sits flush right even beside a short title', (tester) async {
    const width = 800.0;
    await pumpHeader(tester, title: 'Word Book', trailing: const Text('1 due today'), width: width);

    final right = tester.getTopRight(find.text('1 due today')).dx;
    // Header right padding is 20 — the meta must hug the right edge, not float
    // mid-row (the pre-fix Flexible-title + Spacer left it near centre).
    expect(right, greaterThan(width - 40));
  });

  testWidgets('trailing meta is right-aligned with no title too', (tester) async {
    const width = 800.0;
    await pumpHeader(tester, trailing: const Text('Review'), width: width);
    final right = tester.getTopRight(find.text('Review')).dx;
    expect(right, greaterThan(width - 40));
  });

  testWidgets('drops the row below the macOS traffic-light strip', (tester) async {
    // Measure the title's top on the default platform (no immersive title bar).
    await pumpHeader(tester, title: 'Settings');
    final baseTop = tester.getTopLeft(find.text('Settings')).dy;

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      // On macOS the immersive title bar floats traffic lights over the canvas, so the whole header
      // row drops below them — the title sits markedly lower than on other platforms.
      await pumpHeader(tester, title: 'Settings');
      final macTop = tester.getTopLeft(find.text('Settings')).dy;
      expect(
        macTop,
        greaterThan(baseTop + 15),
        reason: 'header row should clear the floating traffic lights',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
