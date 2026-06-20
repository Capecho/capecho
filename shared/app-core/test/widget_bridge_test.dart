import 'dart:convert';

import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_api.dart';

/// Tests for [WidgetBridge] — the Dart side of the review widget: publish a snapshot to the App Group
/// and drain the grades the widget enqueued (foreground flush), over a fake [WidgetHost].

/// A fake App Group: records the published snapshot + holds the widget's queue blob.
class _FakeHost implements WidgetHost {
  _FakeHost({this.queueJson});
  String? publishedSnapshot;
  String? queueJson;

  @override
  Future<void> publishSnapshot(String snapshotJson) async => publishedSnapshot = snapshotJson;

  @override
  Future<String?> readQueueJson() async => queueJson;

  @override
  Future<void> writeQueueJson(String json) async => queueJson = json;
}

SyncEvent grade(String id, {String word = 'w', Rating rating = Rating.good}) =>
    SyncEvent(wordId: word, eventId: id, rating: rating, clientReviewTs: 1, source: 'widget');

WidgetBridge bridge(FakeCapechoApi api, WidgetHost host) => WidgetBridge(
  host: host,
  builder: WidgetSnapshotBuilder(api: api, now: () => 1000, newSnapshotId: () => 'snap-x'),
);

void main() {
  group('publish', () {
    test('builds a DUE-only snapshot and writes its JSON to the host', () async {
      final api = FakeCapechoApi()
        ..due = DueReviews(
          due: [fakeDueCard('w1', unit: 'ledger')],
          newCards: const [],
          dueCount: 1,
          newCount: 0,
        )
        ..contextsByWord['w1'] = [
          fakeContext('w1', 'She kept a ledger.', spanStart: 11, spanEnd: 17),
        ]
        ..explainFor = (_) => fakeExplain('账簿');
      final host = _FakeHost();

      await bridge(api, host).publish();

      final decoded = WidgetReviewSnapshot.fromJson(
        jsonDecode(host.publishedSnapshot!) as Map<String, dynamic>,
      );
      expect(decoded.cards.single.surfaceUnit, 'ledger');
      expect(decoded.cards.single.meaning, 'noun  账簿'); // per-POS senses, POS label inline
      expect(decoded.cards.single.targetSpan, const WidgetTargetSpan(11, 17));
    });

    test('includes NEW cards after due cards, each tagged with its own state', () async {
      // The widget reviews new words too: due first, then today's surfaced new cards, each carrying its
      // real `state` so a new card isn't mislabeled `due`.
      final api = FakeCapechoApi()
        ..due = DueReviews(
          due: [fakeDueCard('wD', unit: 'ledger')],
          newCards: [fakeDueCard('wN', unit: 'obscure', isNew: true)],
          dueCount: 1,
          newCount: 1,
        )
        ..explainFor = (_) => fakeExplain('m');
      final host = _FakeHost();

      await bridge(api, host).publish();

      final decoded = WidgetReviewSnapshot.fromJson(
        jsonDecode(host.publishedSnapshot!) as Map<String, dynamic>,
      );
      expect(decoded.cards.map((c) => c.wordId), ['wD', 'wN']); // due first, then new
      expect(decoded.cards.map((c) => c.state), ['due', 'new']);
    });

    test('retries a transient build failure, then publishes (no empty widget on a blip)', () async {
      var attempts = 0;
      final api = FakeCapechoApi()
        ..onDueReviews = () async {
          attempts++;
          if (attempts < 2) throw ApiException(statusCode: 503, error: 'busy');
          return DueReviews(
            due: [fakeDueCard('w1', unit: 'ledger')],
            newCards: const [],
            dueCount: 1,
            newCount: 0,
          );
        }
        ..explainFor = (_) => fakeExplain('m');
      final host = _FakeHost();
      final b = WidgetBridge(
        host: host,
        builder: WidgetSnapshotBuilder(api: api, now: () => 1000, newSnapshotId: () => 'snap-x'),
        publishRetryBackoff: const [Duration.zero, Duration.zero],
      );

      await b.publish();

      expect(attempts, 2); // failed once, succeeded on the retry
      expect(host.publishedSnapshot, isNotNull);
    });

    test(
      'rethrows after exhausting retries (fire-and-forget caller swallows; foreground retries)',
      () async {
        final api = FakeCapechoApi()
          ..onDueReviews = () async => throw ApiException(statusCode: 503, error: 'busy');
        final host = _FakeHost();
        final b = WidgetBridge(
          host: host,
          builder: WidgetSnapshotBuilder(api: api, now: () => 1000, newSnapshotId: () => 'snap-x'),
          publishRetryBackoff: const [Duration.zero],
        );

        await expectLater(b.publish(), throwsA(isA<ApiException>()));
        expect(host.publishedSnapshot, isNull); // never wrote a half-built snapshot
      },
    );
  });

  group('flushWidgetGrades', () {
    test('drains the widget queue, flushes as widget grades, writes back empty', () async {
      final api = FakeCapechoApi(); // default sync acks every event applied
      final host = _FakeHost(
        queueJson: jsonEncode([grade('g1', word: 'wA').toJson(), grade('g2', word: 'wB').toJson()]),
      );

      final outcome = await bridge(api, host).flushWidgetGrades();

      expect(outcome.flush.acked, 2);
      expect(outcome.stillQueuedWordIds, isEmpty);
      expect(host.queueJson, '[]'); // the shared queue is now drained
      expect(api.syncCalls.single.map((e) => e.source), [
        'widget',
        'widget',
      ]); // tagged widget end-to-end
    });

    test('a partial failure keeps the un-acked grade and reports its wordId', () async {
      final api = FakeCapechoApi()
        ..onSync = (events) async => [
          for (final e in events)
            SyncEventResult(
              eventId: e.eventId,
              status: e.eventId == 'g2' ? ReviewStatus.error : ReviewStatus.applied,
              card: null,
            ),
        ];
      final host = _FakeHost(
        queueJson: jsonEncode([grade('g1', word: 'wA').toJson(), grade('g2', word: 'wB').toJson()]),
      );

      final outcome = await bridge(api, host).flushWidgetGrades();

      expect(outcome.flush.acked, 1);
      expect(outcome.stillQueuedWordIds, {'wB'});
      final back = (jsonDecode(host.queueJson!) as List).cast<Map<String, dynamic>>();
      expect(back.map((e) => e['event_id']), ['g2']); // only the un-acked grade written back
    });

    test(
      'a grade the widget appends DURING the flush survives the write-back (cross-process race)',
      () async {
        // The shared queue starts with one grade; while /sync is in flight the widget process appends a
        // SECOND grade to the same App-Group key (the real cross-process race). The write-back must re-read
        // and remove only the acked ids — never blind-overwrite with the pre-flush remainder — so the
        // mid-flush grade isn't silently lost.
        final host = _FakeHost(queueJson: jsonEncode([grade('g1', word: 'wA').toJson()]));
        final api = FakeCapechoApi()
          ..onSync = (events) async {
            // The widget enqueues a new grade onto the shared key mid-network-window.
            final cur = (jsonDecode(host.queueJson!) as List).cast<Map<String, dynamic>>()
              ..add(grade('g2', word: 'wB').toJson());
            host.queueJson = jsonEncode(cur);
            return [
              for (final e in events)
                SyncEventResult(eventId: e.eventId, status: ReviewStatus.applied, card: null),
            ];
          };

        final outcome = await bridge(api, host).flushWidgetGrades();

        expect(outcome.flush.acked, 1); // only g1 was in the flushed batch
        final back = (jsonDecode(host.queueJson!) as List).cast<Map<String, dynamic>>();
        expect(back.map((e) => e['event_id']), ['g2']); // the mid-flush grade was NOT clobbered
        expect(outcome.stillQueuedWordIds, {'wB'}); // and is excluded from the next rebuild (D6)
      },
    );

    test('a 401 keeps every grade queued and surfaces needsReauth', () async {
      final api = FakeCapechoApi()
        ..onSync = (_) async => throw ApiException(statusCode: 401, error: 'unauthorized');
      final host = _FakeHost(
        queueJson: jsonEncode([grade('g1', word: 'wA').toJson(), grade('g2', word: 'wB').toJson()]),
      );

      final outcome = await bridge(api, host).flushWidgetGrades();

      expect(outcome.flush.needsReauth, isTrue);
      expect(outcome.stillQueuedWordIds, {'wA', 'wB'});
      final back = (jsonDecode(host.queueJson!) as List).cast<Map<String, dynamic>>();
      expect(back.map((e) => e['event_id']), ['g1', 'g2']); // nothing dropped on a 401
    });

    test('an empty or corrupt queue blob is a safe no-op', () async {
      final api = FakeCapechoApi();
      expect((await bridge(api, _FakeHost()).flushWidgetGrades()).flush.acked, 0);
      expect(
        (await bridge(api, _FakeHost(queueJson: 'not json')).flushWidgetGrades()).flush.acked,
        0,
      );
    });
  });

  group('onForeground', () {
    test('flushes then re-publishes, excluding a still-queued grade (D6)', () async {
      final api = FakeCapechoApi()
        ..due = DueReviews(
          due: [fakeDueCard('wA'), fakeDueCard('wB')],
          newCards: const [],
          dueCount: 2,
          newCount: 0,
        )
        ..explainFor = ((_) => fakeExplain('m'))
        ..onSync = (events) async => [
          for (final e in events)
            SyncEventResult(
              eventId: e.eventId,
              status: e.eventId == 'g2' ? ReviewStatus.error : ReviewStatus.applied,
              card: null,
            ),
        ];
      final host = _FakeHost(
        queueJson: jsonEncode([grade('g1', word: 'wA').toJson(), grade('g2', word: 'wB').toJson()]),
      );

      final outcome = await bridge(api, host).onForeground();

      expect(outcome.stillQueuedWordIds, {'wB'});
      final decoded = WidgetReviewSnapshot.fromJson(
        jsonDecode(host.publishedSnapshot!) as Map<String, dynamic>,
      );
      // wB's grade is still queued → the rebuilt snapshot must not re-show it.
      expect(decoded.cards.map((c) => c.wordId), ['wA']);
    });
  });
}
