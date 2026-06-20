import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_api.dart';

/// Tests for [WidgetSnapshotBuilder] + the cursor-reconcile helpers. The builder
/// resolves each card's front+back with the SAME shared helpers the in-app review uses, carries DUE
/// cards then today's surfaced NEW cards (the widget reviews new words too), tolerates partial failure,
/// and the reconcile/resume helpers protect the grade-while-rebuild race (D6).

WidgetSnapshotBuilder builder(FakeCapechoApi api, {int maxCards = 12}) => WidgetSnapshotBuilder(
  api: api,
  maxCards: maxCards,
  now: () => 1000,
  newSnapshotId: () => 'snap-test',
);

void main() {
  group('widgetMeaningText (the iOS widget meaning string)', () {
    test('one line per POS, label inline, senses joined "; " (mirrors the Review card)', () {
      const exp = WordExplanation(
        readings: [
          Reading(
            pronunciationPrimary: 'ˈridɪŋ',
            pronunciationSecondary: '',
            pos: [
              PosGroup(partOfSpeech: 'noun', senses: ['阅读', '读物', '读数', '解读']),
              PosGroup(partOfSpeech: 'adjective', senses: ['阅读的']),
            ],
          ),
        ],
      );
      expect(widgetMeaningText(exp), 'noun  阅读; 读物; 读数; 解读\nadj.  阅读的');
    });

    test('a form note repeated on every sense is pulled to the front once', () {
      const exp = WordExplanation(
        readings: [
          Reading(
            pronunciationPrimary: '',
            pronunciationSecondary: '',
            pos: [
              PosGroup(partOfSpeech: 'verb', senses: ['制造 (make 的现在分词)', '做 (make 的现在分词)']),
            ],
          ),
        ],
      );
      expect(widgetMeaningText(exp), 'verb  (make 的现在分词) 制造; 做');
    });

    test(
      'a blob with no usable sense → empty string (caller degrades to a null, still-reviewable card)',
      () {
        const exp = WordExplanation(
          readings: [
            Reading(
              pronunciationPrimary: 'x',
              pronunciationSecondary: '',
              pos: [
                PosGroup(partOfSpeech: 'noun', senses: ['   ']),
              ],
            ),
          ],
        );
        expect(widgetMeaningText(exp), '');
      },
    );
  });

  group('build', () {
    test('resolves the LATEST context + a ready meaning, with the target span', () async {
      final api = FakeCapechoApi()
        ..due = DueReviews(
          due: [fakeDueCard('w1', unit: 'ledger')],
          newCards: const [],
          dueCount: 1,
          newCount: 0,
        )
        ..contextsByWord['w1'] = [
          fakeContext('w1', 'old sentence', createdAt: 1),
          fakeContext(
            'w1',
            'She kept a ledger.',
            createdAt: 2,
            spanStart: 11,
            spanEnd: 17,
            meaning: 'here it means an account book',
          ),
        ]
        ..explainFor = (_) => fakeExplain('账簿', pronunciation: 'ˈlɛdʒər');

      final snap = await builder(api).build();
      expect(snap.cards, hasLength(1));
      final c = snap.cards.single;
      expect(c.contextText, 'She kept a ledger.'); // the NEWEST, not the oldest
      expect(c.targetSpan, const WidgetTargetSpan(11, 17));
      expect(c.meaningStatus, WidgetMeaningStatus.ready);
      expect(c.meaning, 'noun  账簿'); // per-POS senses, POS label inline (matches the Review card)
      expect(c.ipa, 'ˈlɛdʒər'); // the primary reading's IPA flows onto the card
      // The stored in-sentence gloss rides along free from the SAME /contexts fetch (newest context).
      expect(c.contextMeaning, 'here it means an account book');
      expect(c.state, 'due');
    });

    test('tolerates a missing context + an unavailable meaning (still reviewable)', () async {
      final api = FakeCapechoApi()
        ..due = DueReviews(due: [fakeDueCard('w1')], newCards: const [], dueCount: 1, newCount: 0)
        ..explainFor = (_) =>
            const ExplainResult(status: ExplainStatus.generated, explanation: null);
      // no contexts seeded, explain returns no blob
      final c = (await builder(api).build()).cards.single;
      expect(c.contextText, isEmpty);
      expect(c.targetSpan, isNull);
      expect(c.meaning, isNull);
      expect(c.meaningStatus, WidgetMeaningStatus.unavailable);
    });

    test('maps an unsupported target language', () async {
      final api = FakeCapechoApi()
        ..due = DueReviews(
          due: [fakeDueCard('w1', lang: 'de')],
          newCards: const [],
          dueCount: 1,
          newCount: 0,
        )
        ..explainFor = (_) => fakeUnsupported;
      final c = (await builder(api).build()).cards.single;
      expect(c.meaningStatus, WidgetMeaningStatus.unsupported);
      expect(c.meaning, isNull);
    });

    test(
      'carries DUE cards then today\'s surfaced NEW cards, each tagged with its state',
      () async {
        final api = FakeCapechoApi()
          ..due = DueReviews(
            due: [fakeDueCard('d1'), fakeDueCard('d2')],
            newCards: [fakeDueCard('n1', isNew: true)],
            dueCount: 2,
            newCount: 1,
          )
          ..explainFor = (_) => fakeExplain('m');
        final snap = await builder(api).build();
        expect(snap.cards.map((c) => c.wordId), ['d1', 'd2', 'n1']); // due first, then new
        expect(snap.cards.map((c) => c.state), ['due', 'due', 'new']); // new card isn't mislabeled
      },
    );

    test('caps across the combined due+new queue (due cards keep priority)', () async {
      final api = FakeCapechoApi()
        ..due = DueReviews(
          due: [fakeDueCard('d1'), fakeDueCard('d2')],
          newCards: [fakeDueCard('n1', isNew: true), fakeDueCard('n2', isNew: true)],
          dueCount: 2,
          newCount: 2,
        )
        ..explainFor = (_) => fakeExplain('m');
      final snap = await builder(api, maxCards: 3).build();
      expect(snap.cards.map((c) => c.wordId), ['d1', 'd2', 'n1']); // n2 trimmed by the cap
    });

    test('caps at maxCards', () async {
      final api = FakeCapechoApi()
        ..due = DueReviews(
          due: [for (var i = 0; i < 5; i++) fakeDueCard('d$i')],
          newCards: const [],
          dueCount: 5,
          newCount: 0,
        )
        ..explainFor = (_) => fakeExplain('m');
      final snap = await builder(api, maxCards: 3).build();
      expect(snap.cards, hasLength(3));
    });

    test(
      'excludeWordIds drops cards whose grade is already queued (rebuild-reconcile, D6)',
      () async {
        final api = FakeCapechoApi()
          ..due = DueReviews(
            due: [fakeDueCard('w1'), fakeDueCard('w2')],
            newCards: const [],
            dueCount: 2,
            newCount: 0,
          )
          ..explainFor = (_) => fakeExplain('m');
        final snap = await builder(api).build(excludeWordIds: {'w1'});
        expect(snap.cards.map((c) => c.wordId), ['w2']);
      },
    );

    test('the default snapshot id is a unique uuid (so widget grade ids cannot collide)', () async {
      // The widget derives each grade's event id as `snapshotId#cursor`, and that id is the backend's
      // GLOBAL idempotency PK — so the default snapshot id must be collision-free across devices/rebuilds
      // (a uuid), else two devices building a snapshot in the same microsecond mint identical grade ids
      // and one device's rating is quarantined (id_conflict).
      final api = FakeCapechoApi()
        ..due = DueReviews(due: [fakeDueCard('w1')], newCards: const [], dueCount: 1, newCount: 0)
        ..explainFor = (_) => fakeExplain('m');
      final b = WidgetSnapshotBuilder(
        api: api,
        now: () => 1000,
      ); // default (production) id generator
      final id1 = (await b.build()).snapshotId;
      final id2 = (await b.build()).snapshotId;
      expect(id1, isNot(id2)); // fresh per build → cursor stays scoped to its snapshot
      expect(
        id1,
        matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
      );
    });
  });

  group('cursor scoping + reconcile (D6)', () {
    WidgetReviewSnapshot snap(String id, List<String> wordIds, {int cursor = 0}) =>
        WidgetReviewSnapshot(
          snapshotId: id,
          builtAt: 0,
          staleAfterMs: 1,
          cursor: cursor,
          cards: [
            for (final w in wordIds)
              WidgetReviewCard(
                wordId: w,
                surfaceUnit: w,
                targetLang: 'en',
                dueAt: 0,
                state: 'due',
                contextText: '',
                targetSpan: null,
                meaning: null,
                meaningStatus: WidgetMeaningStatus.unavailable,
              ),
          ],
        );

    test('resumeCursor keeps a stored cursor only for the SAME snapshotId', () {
      final s = snap('snap-B', ['w1', 'w2', 'w3'], cursor: 0);
      // Same id → the widget's advanced cursor is honored.
      expect(resumeCursor(storedSnapshotId: 'snap-B', storedCursor: 2, snapshot: s), 2);
      // Different id (a rebuild) → fall back to the new snapshot's own cursor.
      expect(resumeCursor(storedSnapshotId: 'snap-A', storedCursor: 2, snapshot: s), 0);
      // Null (never stored) → the new snapshot's cursor.
      expect(resumeCursor(storedSnapshotId: null, storedCursor: 9, snapshot: s), 0);
    });

    test('resumeCursor clamps a stale over-long cursor into range', () {
      final s = snap('snap-B', ['w1', 'w2'], cursor: 0);
      expect(resumeCursor(storedSnapshotId: 'snap-B', storedCursor: 99, snapshot: s), 2);
    });

    test('reconcileCursor skips leading already-graded cards', () {
      final s = snap('snap-B', ['w1', 'w2', 'w3']);
      expect(reconcileCursor(s, {'w1', 'w2'}), 2);
      expect(reconcileCursor(s, const {}), 0);
      expect(reconcileCursor(s, {'w1', 'w2', 'w3'}), 3); // all graded → past the end (depleted)
    });
  });
}
