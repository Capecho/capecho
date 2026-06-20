import 'dart:async';

import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_api.dart';

/// Tests for [ReviewController]'s widget-plumbing changes (the offline-queue rewire):
///  - the front shows the MOST-RECENT context (the latent `.first`/oldest bug), and
///  - an in-app rating is tagged `source: 'app'` and flows through the shared [OfflineEventQueue]
///    (so a failed optimistic submit is retried at session end, per-event acked).

ReviewController controller(FakeCapechoApi api) =>
    ReviewController(api: api, now: () => 1000, newEventId: () => 'evt-1');

void main() {
  test('T7: the card front shows the MOST-RECENT context, not the oldest', () async {
    // The backend returns contexts oldest-first; the controller must pick the LAST (newest).
    final api = FakeCapechoApi()
      ..due = DueReviews(
        due: [fakeDueCard('w1', unit: 'set')],
        newCards: const [],
        dueCount: 1,
        newCount: 0,
      )
      ..contextsByWord['w1'] = [
        fakeContext('w1', 'the oldest sentence', createdAt: 1),
        fakeContext('w1', 'the newest sentence', createdAt: 2),
      ]
      ..explainFor = (_) => fakeExplain('a group');

    final c = controller(api);
    await c.start();
    expect(c.phase, ReviewPhase.card);
    expect(c.current!.context!.contextText, 'the newest sentence');
  });

  test('an in-app rating is tagged source "app" and submitted optimistically', () async {
    final api = FakeCapechoApi()
      ..due = DueReviews(due: [fakeDueCard('w1')], newCards: const [], dueCount: 1, newCount: 0)
      ..explainFor = (_) => fakeExplain('m');
    final c = controller(api);
    await c.start();
    c.flip();
    await c.rate(Rating.good);
    await pumpEventQueue();

    expect(api.submitted, hasLength(1));
    expect(api.submitted.single.source, 'app');
    expect(api.submitted.single.rating, Rating.good);
  });

  test(
    'a failed optimistic submit is queued (source "app") and a later flush drains it per-event',
    () async {
      var online = false;
      final queue = OfflineEventQueue(); // injected so we can inspect + drive the drain directly
      final api = FakeCapechoApi()
        ..due = DueReviews(due: [fakeDueCard('w1')], newCards: const [], dueCount: 1, newCount: 0)
        ..explainFor = ((_) => fakeExplain('m'))
        ..onSubmit = (_) async {
          if (!online) throw Exception('offline');
          return const ReviewOutcome(replay: false, card: null);
        }
        ..onSync = (events) async {
          if (!online) throw Exception('offline'); // the session-end flush is offline too
          return [
            for (final e in events)
              SyncEventResult(eventId: e.eventId, status: ReviewStatus.applied, card: null),
          ];
        };
      final c = ReviewController(
        api: api,
        queue: queue,
        now: () => 1000,
        newEventId: () => 'evt-1',
      );
      await c.start();
      c.flip();

      // Optimistic submit fails AND the session-end flush fails → the event stays in the shared queue.
      await c.rate(Rating.good);
      await pumpEventQueue();
      expect(queue.length, 1);
      expect(queue.last!.source, 'app');
      expect(c.pendingSyncCount, 1);
      expect(c.offlineRatingLabel, 'Good');

      // Network returns → a later flush (the widget foreground flush / next session) drains it.
      online = true;
      final r = await queue.flush(api.sync);
      expect(r.acked, 1);
      expect(c.pendingSyncCount, 0);
    },
  );

  test('signing out clears the offline queue so a different account cannot inherit it', () async {
    // A leftover un-synced rating from account A.
    final queue = OfflineEventQueue()
      ..enqueue(
        const SyncEvent(wordId: 'wA', eventId: 'leftover', rating: Rating.good, clientReviewTs: 1),
      );
    final api = FakeCapechoApi()..sessionActive = false; // signed out (token cleared)
    final c = ReviewController(api: api, queue: queue, now: () => 1000, newEventId: () => 'evt-1');
    expect(queue.length, 1);

    await c.start();
    expect(c.phase, ReviewPhase.signedOut);
    expect(
      queue.isEmpty,
      isTrue,
    ); // A's un-synced ratings dropped — B won't flush them under its session
  });

  test('the default event id is a unique RFC-4122 uuid (no injected generator)', () async {
    // With no newEventId injected the controller uses its PRODUCTION default. The backend keys
    // idempotency on the event id GLOBALLY, so a clash across devices is quarantined as id_conflict and
    // the rating silently dropped — the default must therefore be a real uuid, not a timestamp+counter.
    final api = FakeCapechoApi()
      ..due = DueReviews(
        due: [fakeDueCard('w1'), fakeDueCard('w2')],
        newCards: const [],
        dueCount: 2,
        newCount: 0,
      )
      ..explainFor = (_) => fakeExplain('m');
    final c = ReviewController(
      api: api,
      now: () => 1000,
    ); // default (production) event-id generator
    await c.start();
    c.flip();
    await c.rate(Rating.good);
    c.flip();
    await c.rate(Rating.good);
    await pumpEventQueue();

    expect(api.submitted, hasLength(2));
    expect(api.submitted[0].eventId, isNot(api.submitted[1].eventId)); // collision-free
    final uuidV4Re = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );
    expect(api.submitted[0].eventId, matches(uuidV4Re));
    expect(api.submitted[1].eventId, matches(uuidV4Re));
  });

  group('focusWord (widget deep-link opens at the same word)', () {
    FakeCapechoApi threeDue() => FakeCapechoApi()
      ..due = DueReviews(
        due: [fakeDueCard('w1'), fakeDueCard('w2'), fakeDueCard('w3')],
        newCards: const [],
        dueCount: 3,
        newCount: 0,
      )
      ..explainFor = (_) => fakeExplain('m');

    test('jumps the loaded session to the word; an absent word is a no-op', () async {
      final c = controller(threeDue());
      await c.start();
      expect(c.index, 0);

      c.focusWord('w2');
      expect(c.index, 1);
      expect(c.showBack, isFalse);
      expect(c.current!.wordId, 'w2');

      c.focusWord('not-in-queue'); // already reviewed / unknown → stay put
      expect(c.index, 1);
    });

    test('a focus set before the queue loads is applied once it does (cold start)', () async {
      final c = controller(threeDue());
      c.focusWord('w3'); // the deep link arrived before start() finished
      await c.start();
      expect(c.index, 2); // opened at w3, not the queue head
      expect(c.current!.wordId, 'w3');
    });
  });

  group('refresh (app-foreground re-sync after the widget / another device reviews)', () {
    DueReviews dueOf(List<String> ids) => DueReviews(
      due: [for (final id in ids) fakeDueCard(id)],
      newCards: const [],
      dueCount: ids.length,
      newCount: 0,
    );

    FakeCapechoApi threeDue() => FakeCapechoApi()
      ..due = dueOf(['w1', 'w2', 'w3'])
      ..explainFor = (_) => fakeExplain('m');

    test('a card reviewed away drops out; the user keeps their current card (by id)', () async {
      final api = threeDue();
      final c = controller(api);
      await c.start();
      c.focusWord('w2'); // the user is on w2
      expect(c.current!.wordId, 'w2');

      api.due = dueOf(['w2', 'w3']); // w1 got reviewed in the widget → no longer due
      await c.refresh();

      expect(c.total, 2);
      expect(c.current!.wordId, 'w2'); // same card kept, though w1 (before it) was removed
      expect(c.index, 0);
    });

    test('the current card itself reviewed away → lands on the next card, front shown', () async {
      final api = threeDue();
      final c = controller(api);
      await c.start();
      c.flip();
      expect(c.current!.wordId, 'w1');
      expect(c.showBack, isTrue);

      api.due = dueOf(['w2', 'w3']); // w1 (the one being shown) got reviewed away
      await c.refresh();

      expect(c.current!.wordId, 'w2'); // the card that shifted into w1's slot
      expect(c.showBack, isFalse); // a different card → reset to its front
    });

    test('staying on the same card preserves its flip state', () async {
      final c = controller(threeDue());
      await c.start();
      c.flip(); // looking at w1's back
      expect(c.showBack, isTrue);

      await c.refresh(); // nothing changed on the server
      expect(c.current!.wordId, 'w1');
      expect(c.showBack, isTrue); // resume didn't yank the answer away
    });

    test('newly-due cards appear; the current card stays put', () async {
      final api = FakeCapechoApi()
        ..due = dueOf(['w1'])
        ..explainFor = (_) => fakeExplain('m');
      final c = controller(api);
      await c.start();
      expect(c.total, 1);

      api.due = dueOf(['w1', 'w2']); // w2 became due while away
      await c.refresh();
      expect(c.total, 2);
      expect(c.current!.wordId, 'w1');
    });

    test('everything reviewed away → all caught up (the book still has words)', () async {
      final api = FakeCapechoApi()
        ..due = dueOf(['w1'])
        ..words = [fakeWord('w1')]
        ..explainFor = (_) => fakeExplain('m');
      final c = controller(api);
      await c.start();
      expect(c.phase, ReviewPhase.card);

      api.due = dueOf(const []);
      await c.refresh();
      expect(c.phase, ReviewPhase.allCaughtUp);
      expect(c.current, isNull);
    });

    test('a failed re-fetch keeps the live session intact (no blanking)', () async {
      final api = threeDue();
      final c = controller(api);
      await c.start();
      expect(c.current!.wordId, 'w1');

      api.onDueReviews = () async => throw Exception('offline');
      await c.refresh();

      expect(c.phase, ReviewPhase.card); // not blanked on a transient error
      expect(c.current!.wordId, 'w1');
      expect(c.total, 3);
    });

    test('a card rated offline in-app is not re-shown by a refresh', () async {
      final api = FakeCapechoApi()
        ..due = dueOf(['w1', 'w2'])
        ..explainFor = ((_) => fakeExplain('m'))
        ..onSubmit = (_) async =>
            throw Exception('offline'); // the in-app grade can't reach the server
      final c = controller(api);
      await c.start();
      c.flip();
      await c.rate(Rating.good); // w1 graded offline → queued, advance to w2
      await pumpEventQueue();
      expect(c.pendingSyncCount, 1);
      expect(c.current!.wordId, 'w2');

      // The server still lists w1 as due (the grade hasn't synced) — refresh must NOT bring it back.
      await c.refresh();
      expect(c.total, 1);
      expect(c.current!.wordId, 'w2');
    });

    test('a card whose in-app grade is still IN FLIGHT is not re-shown by a refresh', () async {
      final gate = Completer<ReviewOutcome>(); // the submit stays in flight until we complete this
      final api = FakeCapechoApi()
        ..due = dueOf(['w1', 'w2'])
        ..explainFor = ((_) => fakeExplain('m'))
        ..onSubmit = (_) => gate.future;
      final c = controller(api);
      await c.start();
      c.flip();
      await c.rate(Rating.good); // w1 graded; submit dispatched but NOT yet acked; advance to w2
      expect(c.pendingSyncCount, 0); // not failed → not in the offline queue…
      expect(c.current!.wordId, 'w2');

      // …yet the server's due fetch still lists w1 (its grade hasn't landed). Refresh must exclude it.
      await c.refresh();
      expect(c.total, 1);
      expect(c.current!.wordId, 'w2');

      gate.complete(
        const ReviewOutcome(replay: false, card: null),
      ); // let the in-flight submit settle
      await pumpEventQueue();
    });

    test('refresh is a no-op when signed out', () async {
      final api = FakeCapechoApi()..sessionActive = false;
      final c = controller(api);
      await c.start();
      expect(c.phase, ReviewPhase.signedOut);

      await c.refresh(); // must not fetch / change phase
      expect(c.phase, ReviewPhase.signedOut);
      expect(api.syncCalls, isEmpty);
    });
  });
}
