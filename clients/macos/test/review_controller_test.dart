import 'dart:convert';

import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter_test/flutter_test.dart';

class _Net implements Exception {
  const _Net();
}

/// URL-aware fake so prefetch concurrency (context/explain firing across cards) doesn't make the
/// tests order-fragile — each endpoint returns its configured body.
class FakeTransport implements HttpTransport {
  final List<TransportRequest> reqs = [];
  Object dueBody = {
    'due': [],
    'new': [],
    'counts': {'due': 0, 'new': 0},
  };
  Object contextsBody = {'contexts': []};
  Object explainBody = {'status': 'language_unsupported'};
  Object wordsBody = {'words': []};
  Object reviewBody = {'status': 'applied', 'replay': false, 'card': null};
  bool dueThrows = false;
  bool reviewThrows = false;
  int wordsStatus = 200;
  int dueStatus = 200; // set to 401 to exercise the signed-out "sign in to review" branch

  @override
  Future<TransportResponse> send(TransportRequest r) async {
    reqs.add(r);
    final path = Uri.parse(r.url).path;
    if (path.endsWith('/review/due')) {
      if (dueThrows) throw const _Net();
      return _resp(dueStatus, dueBody);
    }
    if (path.endsWith('/review')) {
      if (reviewThrows) throw const _Net();
      return _resp(200, reviewBody);
    }
    if (path.endsWith('/sync')) return _resp(200, _syncResults(r.body));
    if (path.endsWith('/contexts')) return _resp(200, contextsBody);
    if (path.endsWith('/explain')) return _resp(200, explainBody);
    if (path.endsWith('/words')) return _resp(wordsStatus, wordsBody);
    return const TransportResponse(statusCode: 200, body: '{}');
  }

  /// Mirror the real backend's per-event `/sync` response: one `applied` result per posted event
  /// (camelCase `eventId`), so the per-event-acked [OfflineEventQueue] can recognize the acks and drain.
  /// (The old fake returned an empty `results` list, which a per-event ack correctly keeps as un-acked.)
  Object _syncResults(String? body) {
    final parsed = jsonDecode(body ?? '{}') as Map<String, dynamic>;
    final events = (parsed['events'] as List? ?? const []).cast<Map<String, dynamic>>();
    return {
      'results': [
        for (final e in events) {'eventId': e['event_id'], 'status': 'applied'},
      ],
    };
  }

  TransportResponse _resp(int s, Object b) =>
      TransportResponse(statusCode: s, body: b is String ? b : jsonEncode(b));

  int countOf(String suffix) => reqs.where((r) => Uri.parse(r.url).path.endsWith(suffix)).length;
  TransportRequest? lastOf(String suffix) {
    for (final r in reqs.reversed) {
      if (Uri.parse(r.url).path.endsWith(suffix)) return r;
    }
    return null;
  }
}

Map<String, dynamic> dueCard(
  String id,
  String unit, {
  String lang = 'en',
  String state = 'new',
  bool isNew = true,
}) => {
  'wordId': id,
  'surfaceUnit': unit,
  'targetLanguage': lang,
  'state': state,
  'dueAt': 0,
  'isNew': isNew,
};

Map<String, dynamic> ctx(String text, {int? start, int? end, String word = 'w1'}) => {
  'id': 'c1',
  'wordId': word,
  'contextLanguage': 'en',
  'contextText': text,
  'spanStart': start,
  'spanEnd': end,
  'meaning': null,
  'createdAt': 1,
};

Map<String, dynamic> explainHit(String summary, {String pos = 'noun'}) => {
  'status': 'hit',
  'explanation': {
    'readings': [
      {
        'pronunciationPrimary': '',
        'pronunciationSecondary': '',
        'pos': [
          {
            'partOfSpeech': pos,
            'senses': [summary], // the primary sense
          },
        ],
      },
    ],
  },
};

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

ReviewController make(FakeTransport t, {String lang = 'en', bool signedIn = true}) {
  final api = CapechoApi(baseUrl: 'https://api.test', transport: t);
  // Most tests exercise the SIGNED-IN review flow; a held token gets `start()` past the signed-out
  // gate to the real `/review/due` fetch.
  if (signedIn) api.restoreToken('test-session');
  return ReviewController(
    api: api,
    explanationLanguage: lang,
    now: () => 7,
    newEventId: () => 'ev-fixed',
  );
}

void main() {
  test('loads the due queue + presents the first card (context + meaning)', () async {
    final t = FakeTransport()
      ..dueBody = {
        'due': [dueCard('w1', 'serendipity')],
        'new': [],
        'counts': {'due': 1, 'new': 0},
      }
      ..contextsBody = {
        'contexts': [ctx('a moment of serendipity', start: 11, end: 22)],
      }
      ..explainBody = explainHit('good fortune', pos: 'noun');
    final c = make(t);
    await c.start();
    expect(c.phase, ReviewPhase.card);
    expect(c.total, 1);
    expect(c.index, 0);
    expect(c.current!.unit, 'serendipity');
    expect(c.current!.hasContext, isTrue);
    expect(c.current!.meaningStatus, MeaningStatus.ready);
    expect(c.current!.explanation!.primarySense, 'good fortune');
  });

  test('flip → rate(Good) submits the snake_case event + reaches done', () async {
    final t = FakeTransport()
      ..dueBody = {
        'due': [dueCard('w1', 'serendipity')],
        'new': [],
        'counts': {'due': 1, 'new': 0},
      }
      ..contextsBody = {
        'contexts': [ctx('x')],
      }
      ..explainBody = explainHit('luck');
    final c = make(t);
    await c.start();
    expect(c.showBack, isFalse);
    c.flip();
    expect(c.showBack, isTrue);
    await c.rate(Rating.good);
    await settle();
    expect(c.phase, ReviewPhase.done);
    expect(c.reviewedCount, 1);
    final body = jsonDecode(t.lastOf('/review')!.body!) as Map<String, dynamic>;
    expect(body['rating'], 3); // Good = 3
    expect(body['word_id'], 'w1');
  });

  test('a rating before flipping is ignored (no submit, stays on the card)', () async {
    final t = FakeTransport()
      ..dueBody = {
        'due': [dueCard('w1', 'x')],
        'new': [],
        'counts': {'due': 1, 'new': 0},
      }
      ..contextsBody = {
        'contexts': [ctx('x')],
      }
      ..explainBody = explainHit('y');
    final c = make(t);
    await c.start();
    await c.rate(Rating.good); // not flipped
    expect(c.phase, ReviewPhase.card);
    expect(c.reviewedCount, 0);
    expect(t.countOf('/review'), 0);
  });

  test('empty due, word-count unknown → all caught up (never the cold empty state)', () async {
    final t = FakeTransport()..wordsStatus = 500; // can't confirm the Word Book is empty
    final c = make(t);
    await c.start();
    expect(c.phase, ReviewPhase.allCaughtUp);
  });

  test('empty due + confirmed-empty Word Book → nothing captured', () async {
    final t = FakeTransport()..wordsBody = {'words': []};
    final c = make(t);
    await c.start();
    expect(c.phase, ReviewPhase.nothingCaptured);
  });

  test('a non-English (unsupported) target uses the unavailable meaning treatment', () async {
    final t = FakeTransport()
      ..dueBody = {
        'due': [dueCard('w1', 'Sehnsucht', lang: 'de')],
        'new': [],
        'counts': {'due': 1, 'new': 0},
      }
      ..contextsBody = {
        'contexts': [ctx('Eine Sehnsucht', start: 5, end: 14)],
      }
      ..explainBody = {'status': 'language_unsupported'};
    final c = make(t);
    await c.start();
    expect(c.current!.meaningStatus, MeaningStatus.unsupported);
    expect(c.current!.hasContext, isTrue); // still fully reviewable
  });

  test('a context-less word falls back to a bare card', () async {
    final t = FakeTransport()
      ..dueBody =
          {
            'due': [dueCard('w1', 'madrugar', lang: 'es')],
            'new': [],
            'counts': {'due': 1, 'new': 0},
          } // contextsBody default = empty
      ..explainBody = explainHit('to wake early');
    final c = make(t);
    await c.start();
    expect(c.current!.hasContext, isFalse);
    expect(c.phase, ReviewPhase.card);
  });

  test('dueReviews failure → error phase with a message', () async {
    final t = FakeTransport()..dueThrows = true;
    final c = make(t);
    await c.start();
    expect(c.phase, ReviewPhase.error);
    expect(c.error, isNotNull);
  });

  test('a 401 on the due fetch (expired/invalid session) → the calm sign-in steer', () async {
    // A session the server has since rejected: surface the calm sign-in steer (not a connection error).
    final t = FakeTransport()..dueStatus = 401;
    final c = make(t);
    await c.start();
    expect(c.phase, ReviewPhase.error);
    expect(c.error, 'Sign in to review your words.');
  });

  test('no session → the signed-out gate, with NO due fetch attempted', () async {
    // Review is server-authoritative, so signed-out it shows the gate (with inline sign-in) without
    // ever hitting /review/due.
    final t = FakeTransport();
    final c = make(t, signedIn: false);
    await c.start();
    expect(c.phase, ReviewPhase.signedOut);
    expect(c.error, isNull);
    expect(t.countOf('/review/due'), 0);
  });

  test('a failed submit queues, and queued ratings flush on session end', () async {
    final t = FakeTransport()
      ..dueBody = {
        'due': [dueCard('w1', 'a'), dueCard('w2', 'b')],
        'new': [],
        'counts': {'due': 2, 'new': 0},
      }
      ..contextsBody = {
        'contexts': [ctx('s')],
      }
      ..explainBody = explainHit('m')
      ..reviewThrows = true; // every /review submit fails
    final c = make(t);
    await c.start();
    c.flip();
    await c.rate(Rating.good); // card 0 → advance to card 1
    await settle();
    expect(c.phase, ReviewPhase.card);
    expect(c.index, 1);
    expect(c.pendingSyncCount, 1); // queued, not lost

    c.flip();
    await c.rate(Rating.again); // card 1 → done → flush
    await settle();
    expect(c.phase, ReviewPhase.done);
    expect(t.countOf('/sync'), 1); // queued ratings flushed in one batch
    expect(c.pendingSyncCount, 0);
  });
}
