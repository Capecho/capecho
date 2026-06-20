import 'dart:convert';
import 'dart:io';

import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Snapshot wire-contract tests. The committed golden JSON is the SOURCE OF TRUTH the
/// SwiftUI widget will decode; these tests pin the Dart encoder + decoder to it so the two
/// sides can't drift. Map-deep-equality (not string equality) is the contract — JSON key order is
/// irrelevant to a Swift `Codable` decode.

/// The Dart-built equivalent of the golden fixture (same values), to prove the ENCODER pins the wire.
WidgetReviewSnapshot goldenSnapshot() => const WidgetReviewSnapshot(
  snapshotId: 'snap-fixture-1',
  builtAt: 1733616000000,
  staleAfterMs: 86400000,
  cursor: 0,
  cards: [
    WidgetReviewCard(
      wordId: 'w-ledger',
      surfaceUnit: 'ledger',
      targetLang: 'en',
      dueAt: 1733620000000,
      state: 'due',
      contextText: 'She kept a ledger of debts.',
      targetSpan: WidgetTargetSpan(11, 17),
      ipa: 'ˈlɛdʒər',
      meaning: '账簿;分类账',
      meaningStatus: WidgetMeaningStatus.ready,
      contextMeaning: '这里 ledger 指记账的账本;这句话说她把欠的债都记在账本里。',
    ),
    WidgetReviewCard(
      wordId: 'w-framework',
      surfaceUnit: 'framework',
      targetLang: 'de',
      dueAt: 1733620000001,
      state: 'due',
      contextText: '学习 framework 的用法',
      targetSpan: WidgetTargetSpan(3, 12),
      meaning: null,
      meaningStatus: WidgetMeaningStatus.unsupported,
    ),
    WidgetReviewCard(
      wordId: 'w-bare',
      surfaceUnit: 'obscure',
      targetLang: 'en',
      dueAt: 1733620000002,
      state: 'due',
      contextText: '',
      targetSpan: null,
      meaning: null,
      meaningStatus: WidgetMeaningStatus.unavailable,
    ),
  ],
);

Map<String, dynamic> loadGolden() {
  final file = File('test/fixtures/widget_review_snapshot.golden.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  group('golden-fixture contract (Dart ⇄ committed JSON ⇄ Swift)', () {
    test('the Dart encoder produces exactly the committed golden JSON', () {
      expect(goldenSnapshot().toJson(), equals(loadGolden()));
    });

    test('decoding the golden then re-encoding is byte-stable (round-trip)', () {
      final golden = loadGolden();
      final decoded = WidgetReviewSnapshot.fromJson(golden);
      expect(decoded.toJson(), equals(golden));
    });

    test('decode recovers every field (including the unsupported / bare cards)', () {
      final s = WidgetReviewSnapshot.fromJson(loadGolden());
      expect(s.schemaVersion, 1);
      expect(s.snapshotId, 'snap-fixture-1');
      expect(s.cards, hasLength(3));

      final ready = s.cards[0];
      expect(ready.meaningStatus, WidgetMeaningStatus.ready);
      expect(ready.meaning, '账簿;分类账');
      expect(ready.ipa, 'ˈlɛdʒər');
      expect(ready.targetSpan, const WidgetTargetSpan(11, 17));
      expect(ready.contextMeaning, '这里 ledger 指记账的账本;这句话说她把欠的债都记在账本里。');

      final unsupported = s.cards[1];
      expect(unsupported.meaningStatus, WidgetMeaningStatus.unsupported);
      expect(unsupported.meaning, isNull);
      expect(unsupported.ipa, isNull);
      expect(unsupported.contextMeaning, isNull);

      final bare = s.cards[2];
      expect(bare.meaningStatus, WidgetMeaningStatus.unavailable);
      expect(bare.contextText, isEmpty);
      expect(bare.targetSpan, isNull);
    });
  });

  group('UTF-16 targetSpan (Swift String/NSRange ↔ Dart UTF-16)', () {
    test('a CJK-prefixed context highlights the word at its UTF-16 offset', () {
      // "学习 framework 的用法": 学(0) 习(1) space(2) f(3)… → "framework" is [3, 12) in UTF-16 units.
      const text = '学习 framework 的用法';
      const span = WidgetTargetSpan(3, 12);
      expect(text.substring(span.start, span.end), 'framework');
    });

    test('a span past a surrogate pair (emoji) uses UTF-16 units, not runes', () {
      // "🎯 target" — the emoji is a surrogate PAIR = 2 UTF-16 units, so "target" starts at index 3.
      const text = '🎯 target';
      const span = WidgetTargetSpan(3, 9);
      expect(text.substring(span.start, span.end), 'target');
      // Decoding the wire array preserves the exact units.
      expect(WidgetTargetSpan.fromJson(const [3, 9]), span);
    });
  });

  group('defensive decode', () {
    test('a malformed / inverted / one-sided targetSpan decodes to null (render plain text)', () {
      expect(WidgetTargetSpan.fromJson(const [5, 2]), isNull); // inverted
      expect(WidgetTargetSpan.fromJson(const [3]), isNull); // one-sided
      expect(WidgetTargetSpan.fromJson(const [-1, 4]), isNull); // negative
      expect(WidgetTargetSpan.fromJson(null), isNull);
      expect(WidgetTargetSpan.fromJson('nope'), isNull);
    });

    test('fromBounds validates the builder path (not just the wire decode)', () {
      expect(WidgetTargetSpan.fromBounds(11, 17), const WidgetTargetSpan(11, 17));
      expect(WidgetTargetSpan.fromBounds(5, 2), isNull); // inverted
      expect(WidgetTargetSpan.fromBounds(-1, 4), isNull); // negative
      expect(WidgetTargetSpan.fromBounds(3, null), isNull); // one-sided
      expect(WidgetTargetSpan.fromBounds(null, null), isNull);
    });

    test('an unknown meaningStatus degrades to unavailable (forward-safe)', () {
      expect(WidgetMeaningStatus.fromWire('some-future-status'), WidgetMeaningStatus.unavailable);
      expect(WidgetMeaningStatus.fromWire(null), WidgetMeaningStatus.unavailable);
    });

    test('isStaleAt respects the freshness window', () {
      final s = goldenSnapshot();
      expect(s.isStaleAt(s.builtAt + s.staleAfterMs - 1), isFalse);
      expect(s.isStaleAt(s.builtAt + s.staleAfterMs), isTrue);
    });
  });
}
