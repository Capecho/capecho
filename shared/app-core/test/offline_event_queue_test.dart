import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for [OfflineEventQueue] — the shared per-event-acked offline
/// review-event queue. The IRON RULE under test: a PARTIAL `/sync` failure must keep the un-acked
/// events (the old batch-clear dropped ratings the server never accepted).

SyncEvent ev(String id, {Rating rating = Rating.good, String source = 'app'}) =>
    SyncEvent(wordId: 'w-$id', eventId: id, rating: rating, clientReviewTs: 1000, source: source);

SyncEventResult res(String id, ReviewStatus status) =>
    SyncEventResult(eventId: id, status: status, card: null);

/// A sync fn returning a fixed status per event id (missing id → no result returned).
SyncEventsFn fixed(Map<String, ReviewStatus> byId) =>
    (events) async => [
      for (final e in events)
        if (byId.containsKey(e.eventId)) res(e.eventId, byId[e.eventId]!),
    ];

void main() {
  group('per-event ack', () {
    test('applied events are removed, a transient `error` is kept (T2)', () async {
      final q = OfflineEventQueue()
        ..enqueue(ev('a'))
        ..enqueue(ev('b'))
        ..enqueue(ev('c'));
      final r = await q.flush(
        fixed({'a': ReviewStatus.applied, 'b': ReviewStatus.error, 'c': ReviewStatus.applied}),
      );
      expect(r.acked, 2);
      expect(r.retained, 1);
      expect(r.quarantined, 0);
      expect(r.fullyDrained, isFalse);
      expect(q.events.map((e) => e.eventId), ['b']); // only the errored event survives
    });

    test('permanent failures are quarantined out (not retried)', () async {
      final q = OfflineEventQueue()
        ..enqueue(ev('nf'))
        ..enqueue(ev('del'))
        ..enqueue(ev('conf'))
        ..enqueue(ev('bad'));
      final r = await q.flush(
        fixed({
          'nf': ReviewStatus.notFound,
          'del': ReviewStatus.unitDeleted,
          'conf': ReviewStatus.idConflict,
          'bad': ReviewStatus.invalid,
        }),
      );
      expect(r.quarantined, 4);
      expect(q.isEmpty, isTrue);
    });

    test('an event the server returned NO result for is kept (defensive)', () async {
      final q = OfflineEventQueue()
        ..enqueue(ev('a'))
        ..enqueue(ev('missing'));
      final r = await q.flush(fixed({'a': ReviewStatus.applied})); // no result for 'missing'
      expect(r.acked, 1);
      expect(q.events.map((e) => e.eventId), ['missing']);
    });
  });

  group('IRON RULE: partial failure must NOT drop events (T3 regression)', () {
    test(
      'a mid-batch error leaves exactly that event queued, and a later flush drains it',
      () async {
        final q = OfflineEventQueue()
          ..enqueue(ev('e1'))
          ..enqueue(ev('e2'))
          ..enqueue(ev('e3'));
        await q.flush(
          fixed({'e1': ReviewStatus.applied, 'e2': ReviewStatus.error, 'e3': ReviewStatus.applied}),
        );
        expect(q.events.map((e) => e.eventId), ['e2']); // NOT a whole-batch clear

        final r2 = await q.flush(fixed({'e2': ReviewStatus.applied}));
        expect(r2.fullyDrained, isTrue);
        expect(q.isEmpty, isTrue);
      },
    );
  });

  group('whole-batch retention', () {
    test('a 401 keeps every event and flags needsReauth', () async {
      final q = OfflineEventQueue()
        ..enqueue(ev('a'))
        ..enqueue(ev('b'));
      final r = await q.flush(
        (_) async => throw ApiException(statusCode: 401, error: 'unauthorized'),
      );
      expect(r.needsReauth, isTrue);
      expect(r.retained, 2);
      expect(q.length, 2); // nothing dropped — retries pause until re-auth
    });

    test('a network throw keeps every event and flags transportFailed', () async {
      final q = OfflineEventQueue()..enqueue(ev('a'));
      final r = await q.flush((_) async => throw Exception('no network'));
      expect(r.transportFailed, isTrue);
      expect(r.needsReauth, isFalse);
      expect(q.length, 1);
    });

    test(
      'a non-401 ApiException is treated as a transient transport failure (batch kept)',
      () async {
        final q = OfflineEventQueue()..enqueue(ev('a'));
        final r = await q.flush(
          (_) async => throw ApiException(statusCode: 503, error: 'unavailable'),
        );
        expect(r.transportFailed, isTrue);
        expect(r.needsReauth, isFalse);
        expect(q.length, 1);
      },
    );

    test('flushing an empty queue is a no-op fully-drained result', () async {
      final r = await OfflineEventQueue().flush(fixed(const {}));
      expect(r.fullyDrained, isTrue);
      expect(r.acked, 0);
    });
  });

  group('round-trip vs a fake sync (T5)', () {
    test('an offline grade survives a failed flush and lands on the retry', () async {
      var online = false;
      final q = OfflineEventQueue()..enqueue(ev('g', source: 'widget'));
      // First flush: offline → kept.
      final r1 = await q.flush((_) async {
        if (!online) throw Exception('offline');
        return [res('g', ReviewStatus.applied)];
      });
      expect(r1.transportFailed, isTrue);
      expect(q.length, 1);
      expect(q.last!.source, 'widget'); // source preserved across the retry

      // Network returns → flush drains it.
      online = true;
      final r2 = await q.flush(
        (events) async => [for (final e in events) res(e.eventId, ReviewStatus.applied)],
      );
      expect(r2.acked, 1);
      expect(q.isEmpty, isTrue);
    });
  });

  group('chunking (no 413 wedge) + clear', () {
    test('a queue larger than batchLimit flushes in bounded chunks and fully drains', () async {
      final q = OfflineEventQueue();
      for (var i = 0; i < 250; i++) {
        q.enqueue(ev('e$i'));
      }
      final chunkSizes = <int>[];
      final r = await q.flush((events) async {
        chunkSizes.add(events.length);
        return [for (final e in events) res(e.eventId, ReviewStatus.applied)];
      }, batchLimit: 100);
      expect(chunkSizes, [
        100,
        100,
        50,
      ]); // 250 → three chunks, each ≤ batchLimit (never one 250-batch → 413)
      expect(r.acked, 250);
      expect(q.isEmpty, isTrue);
    });

    test('a mid-flush failure retains earlier-chunk acks and keeps the un-acked rest', () async {
      final q = OfflineEventQueue();
      for (var i = 0; i < 30; i++) {
        q.enqueue(ev('e$i'));
      }
      var call = 0;
      final r = await q.flush((events) async {
        call++;
        if (call == 2) throw Exception('network drop'); // the SECOND chunk fails
        return [for (final e in events) res(e.eventId, ReviewStatus.applied)];
      }, batchLimit: 10);
      expect(r.transportFailed, isTrue);
      expect(r.acked, 10); // first chunk's acks are kept (removed from the queue)
      expect(q.length, 20); // chunks 2 + 3 retained for the next flush
    });

    test('clear() empties the queue and persists empty', () {
      final store = _RecordingStore();
      final q = OfflineEventQueue(store: store)
        ..enqueue(ev('a'))
        ..enqueue(ev('b'));
      q.clear();
      expect(q.isEmpty, isTrue);
      expect(store.last, isEmpty);
    });
  });

  group('persistence seam', () {
    test('a queue rehydrates from its store on construction (cold-start survival)', () {
      final store = _RecordingStore()..save([ev('x'), ev('y')]);
      final q = OfflineEventQueue(store: store);
      expect(q.events.map((e) => e.eventId), ['x', 'y']);
    });

    test('every mutation persists through the store', () async {
      final store = _RecordingStore();
      final q = OfflineEventQueue(store: store)..enqueue(ev('a'));
      expect(store.last.map((e) => e.eventId), ['a']);
      await q.flush(fixed({'a': ReviewStatus.applied}));
      expect(store.last, isEmpty); // drained → persisted as empty
    });
  });
}

/// A store that records the last saved list (and can be pre-seeded) — proves the queue round-trips
/// through the persistence seam without a real App Group.
class _RecordingStore implements EventQueueStore {
  List<SyncEvent> last = const [];

  @override
  List<SyncEvent> load() => List.of(last);

  @override
  void save(List<SyncEvent> events) => last = List.of(events);
}
