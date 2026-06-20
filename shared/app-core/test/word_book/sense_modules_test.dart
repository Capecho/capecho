import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

WordExplanation _exp(List<PosGroup> pos) => WordExplanation(
  readings: [
    Reading(pronunciationPrimary: 'ˈmeɪkɪŋ', pronunciationSecondary: '', kind: null, pos: pos),
  ],
);

Future<void> _pump(WidgetTester tester, WordExplanation exp, {bool showPosLabels = true}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SenseModules(
            p: OnboardingPalette.lightForTest,
            explanation: exp,
            targetLanguage: 'en',
            showPosLabels: showPosLabels,
            showPronunciation: false,
          ),
        ),
      ),
    );

void main() {
  testWidgets('each POS renders on ONE line, senses joined with "; " (the overlay format)', (
    tester,
  ) async {
    await _pump(
      tester,
      _exp([
        const PosGroup(partOfSpeech: 'noun', senses: ['阅读', '读物', '读数', '解读']),
        const PosGroup(partOfSpeech: 'adj', senses: ['阅读的']),
      ]),
    );
    expect(find.text('阅读; 读物; 读数; 解读'), findsOneWidget); // one joined line, not a numbered column
    expect(find.text('阅读的'), findsOneWidget);
  });

  testWidgets('a shared form note shows once at the front, in parentheses', (tester) async {
    await _pump(
      tester,
      _exp([
        const PosGroup(
          partOfSpeech: 'verb',
          senses: ['制造 (make 的现在分词)', '做 (make 的现在分词)', '使得 (make 的现在分词)'],
        ),
      ]),
    );
    expect(find.text('(make 的现在分词) 制造; 做; 使得'), findsOneWidget);
  });

  testWidgets('shows every stored sense (uncapped) joined on one line', (tester) async {
    await _pump(
      tester,
      _exp([
        const PosGroup(partOfSpeech: 'noun', senses: ['a', 'b', 'c', 'd', 'e']),
      ]),
    );
    expect(find.text('a; b; c; d; e'), findsOneWidget);
  });
}
