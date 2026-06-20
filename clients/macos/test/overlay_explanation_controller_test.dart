import 'dart:convert';

import 'package:capecho/overlay_explanation_controller.dart';
import 'package:capecho_api/capecho_api.dart';
import 'package:capture_native/capture_native.dart';
import 'package:flutter_test/flutter_test.dart';

/// A `CaptureNative` that records the explanation pushes instead of crossing the method channel.
/// `calls` keeps the phase for the control-flow assertions; the readings payload is captured separately
/// (`lastReadings`) so the senses/display-part forwarding has its own focused assertions.
class _FakeCapture extends CaptureNative {
  final List<Map<String, Object?>> calls = [];
  List<Map<String, Object?>>? lastReadings;
  @override
  Future<void> updateOverlayExplanation({
    required String phase,
    List<Map<String, Object?>>? readings,
  }) async {
    calls.add({'phase': phase});
    if (readings != null) lastReadings = readings;
  }
}

class _Net implements Exception {
  const _Net();
}

class _FakeTransport implements HttpTransport {
  _FakeTransport({
    this.throws = false,
    this.body = const <String, Object?>{},
    this.delayMs = 0,
    this.byUnit = false,
    this.statusCode = 200,
  });
  final bool throws;
  final Object body;
  final int delayMs; // delay the response so a later fetch can supersede an earlier one
  final bool byUnit; // echo the request's `unit` into the sense (`"<unit>-meaning"`)
  final int statusCode; // non-200 → the real CapechoApi throws ApiException (e.g. a 422 not_a_word)
  int sends =
      0; // how many times /explain was actually hit (a junk-gate / cache hit must leave this 0)
  @override
  Future<TransportResponse> send(TransportRequest r) async {
    sends++;
    if (delayMs > 0) await Future<void>.delayed(Duration(milliseconds: delayMs));
    if (throws) throw const _Net();
    if (byUnit) {
      final unit = Uri.parse(r.url).queryParameters['unit'] ?? '';
      return TransportResponse(statusCode: 200, body: jsonEncode(_explainHit('$unit-meaning')));
    }
    return TransportResponse(
      statusCode: statusCode,
      body: body is String ? body as String : jsonEncode(body),
    );
  }
}

/// An in-memory stand-in for the device-local explanation cache (the `readCache`/`writeCache` port).
/// Holds the per-POS senses readings, like the real store.
class _FakeCache {
  final Map<String, CachedExplanation> store = {};
  final List<Map<String, Object?>> writes = [];
  String _k(String u, String t, String l) => '$t|$l|${u.toLowerCase()}';

  /// Pre-populate a hit (no write recorded) — simulates a prior capture's cached blob.
  void seed(String unit, String target, String lang, {required List<CachedReading> readings}) =>
      store[_k(unit, target, lang)] = (readings: readings);

  CachedExplanation? read({
    required String surfaceUnit,
    required String targetLanguage,
    required String explanationLanguage,
  }) => store[_k(surfaceUnit, targetLanguage, explanationLanguage)];

  void write({
    required String surfaceUnit,
    required String targetLanguage,
    required String explanationLanguage,
    required List<CachedReading> readings,
  }) {
    writes.add({
      'unit': surfaceUnit,
      'lang': explanationLanguage,
      'readings': [
        for (final r in readings)
          {
            'pronunciationPrimary': r.pronunciationPrimary,
            'pronunciationSecondary': r.pronunciationSecondary,
            'pos': [
              for (final p in r.pos) {'partOfSpeech': p.partOfSpeech, 'senses': p.senses},
            ],
          },
      ],
    });
    store[_k(surfaceUnit, targetLanguage, explanationLanguage)] = (readings: readings);
  }
}

OverlayExplanationController _controller(_FakeCapture cap, _FakeTransport t, {_FakeCache? cache}) =>
    OverlayExplanationController(
      api: CapechoApi(baseUrl: 'https://api.test', transport: t),
      capture: cap,
      readCache: cache?.read,
      writeCache: cache?.write,
    );

/// A single-reading hit whose one [sense] (under [pos]) is the word's meaning.
Map<String, dynamic> _explainHit(String sense, {String pos = 'noun'}) => {
  'status': 'hit',
  'explanation': {
    'readings': [
      {
        'pronunciationPrimary': '',
        'pronunciationSecondary': '',
        'pos': [
          {
            'partOfSpeech': pos,
            'senses': [sense],
          },
        ],
      },
    ],
  },
};

/// A heteronym hit — two readings, each with both pronunciation slots + one POS carrying one sense.
Map<String, dynamic> _explainHitEnriched() => {
  'status': 'hit',
  'explanation': {
    'readings': [
      {
        'pronunciationPrimary': 'ˈɑbdʒɛkt',
        'pronunciationSecondary': 'ˈɒbdʒɪkt',
        'pos': [
          {
            'partOfSpeech': 'noun',
            'senses': ['a thing you can see or touch'],
          },
        ],
      },
      {
        'pronunciationPrimary': 'əbˈdʒɛkt',
        'pronunciationSecondary': 'əbˈdʒɛkt',
        'pos': [
          {
            'partOfSpeech': 'verb',
            'senses': ['to disagree'],
          },
        ],
      },
    ],
  },
};

void main() {
  test('English unit → loading then ready', () async {
    final cap = _FakeCapture();
    final c = _controller(cap, _FakeTransport(body: _explainHit('good fortune')));
    await c.explainFor(unit: 'serendipity', targetLanguage: 'en');
    expect(cap.calls, [
      {'phase': 'loading'},
      {'phase': 'ready'},
    ]);
    // One reading, one POS, one (unnumbered) sense; no pronunciation parts (empty transcriptions).
    expect(cap.lastReadings, [
      {
        'pronunciations': <Map<String, Object?>>[],
        'isIdiom': false,
        'pos': [
          {
            'partOfSpeech': 'noun',
            'senses': ['good fortune'],
            'note': '',
          },
        ],
      },
    ]);
  });

  test('ready forwards DISPLAY-READY readings (en profile: US/UK labels) + per-POS senses', () async {
    final cap = _FakeCapture();
    final c = _controller(cap, _FakeTransport(body: _explainHitEnriched()));
    await c.explainFor(unit: 'object', targetLanguage: 'en');
    expect(cap.calls, [
      {'phase': 'loading'},
      {'phase': 'ready'},
    ]);
    // Each reading is its own block: display-ready pronunciation parts (decorated from the en TARGET
    // profile here in Dart) + its per-POS senses.
    expect(cap.lastReadings, [
      {
        'pronunciations': [
          {'label': 'US', 'display': '/ˈɑbdʒɛkt/'},
          {'label': 'UK', 'display': '/ˈɒbdʒɪkt/'},
        ],
        'isIdiom': false,
        'pos': [
          {
            'partOfSpeech': 'noun',
            'senses': ['a thing you can see or touch'],
            'note': '',
          },
        ],
      },
      {
        'pronunciations': [
          {'label': 'US', 'display': '/əbˈdʒɛkt/'},
          {'label': 'UK', 'display': '/əbˈdʒɛkt/'},
        ],
        'isIdiom': false,
        'pos': [
          {
            'partOfSpeech': 'verb',
            'senses': ['to disagree'],
            'note': '',
          },
        ],
      },
    ]);
  });

  test('every stored sense is forwarded on one line (no cap, no "more" hint)', () async {
    // The overlay shows ALL of a POS's senses — no display cap, no "more senses" hint anywhere.
    final cap = _FakeCapture();
    final body = {
      'status': 'hit',
      'explanation': {
        'readings': [
          {
            'pronunciationPrimary': 'rʌn',
            'pronunciationSecondary': 'rʌn',
            'pos': [
              {
                'partOfSpeech': 'verb',
                'senses': ['to move fast', 'to operate', 'to manage', 'to flow', 'to compete'],
              },
            ],
          },
        ],
      },
    };
    final c = _controller(cap, _FakeTransport(body: body));
    await c.explainFor(unit: 'run', targetLanguage: 'en');
    expect(cap.calls.last, {'phase': 'ready'});
    final pos = (cap.lastReadings!.single['pos'] as List).single as Map;
    expect(pos['senses'], [
      'to move fast',
      'to operate',
      'to manage',
      'to flow',
      'to compete',
    ]); // ALL shown
  });

  test('a regional English target is allowlisted; renders the sense', () async {
    final cap = _FakeCapture();
    final c = _controller(cap, _FakeTransport(body: _explainHit('good fortune')));
    await c.explainFor(unit: 'serendipity', targetLanguage: 'en-US');
    expect(cap.calls.last, {'phase': 'ready'});
  });

  test(
    'a server language_unsupported drives the native lang_unsupported note (D3: no client allowlist)',
    () async {
      final cap = _FakeCapture();
      final c = _controller(cap, _FakeTransport(body: {'status': 'language_unsupported'}));
      await c.explainFor(unit: 'Sehnsucht', targetLanguage: 'de');
      expect(cap.calls, [
        {'phase': 'loading'},
        {'phase': 'lang_unsupported'},
      ]);
    },
  );

  test('an empty unit skips the fetch', () async {
    final cap = _FakeCapture();
    final c = _controller(cap, _FakeTransport());
    await c.explainFor(unit: '   ', targetLanguage: 'en');
    expect(cap.calls, isEmpty);
  });

  test('a transport failure → loading then failed', () async {
    final cap = _FakeCapture();
    final c = _controller(cap, _FakeTransport(throws: true));
    await c.explainFor(unit: 'serendipity', targetLanguage: 'en');
    expect(cap.calls, [
      {'phase': 'loading'},
      {'phase': 'failed'},
    ]);
  });

  test('an explanation-less result (anonymous cache miss) → loading then failed', () async {
    final cap = _FakeCapture();
    final c = _controller(cap, _FakeTransport(body: const {'status': 'miss', 'explanation': null}));
    await c.explainFor(unit: 'serendipity', targetLanguage: 'en');
    expect(cap.calls, [
      {'phase': 'loading'},
      {'phase': 'failed'},
    ]);
  });

  test('a sense-less blob → failed (the primary sense is the must-pass core; no fallback)', () async {
    final cap = _FakeCapture();
    // Defensive: the server never serves this (its own must-pass gate), but a degraded/foreign body
    // must not paint a partial card from pronunciation metadata alone.
    final body = {
      'status': 'hit',
      'explanation': {
        'readings': [
          {
            'pronunciationPrimary': 'rʌn',
            'pronunciationSecondary': '',
            'pos': [
              {'partOfSpeech': 'verb', 'senses': <String>[]},
            ],
          },
        ],
      },
    };
    final c = _controller(cap, _FakeTransport(body: body));
    await c.explainFor(unit: 'run', targetLanguage: 'en');
    expect(cap.calls, [
      {'phase': 'loading'},
      {'phase': 'failed'},
    ]);
  });

  test('a superseded fetch drops its result (no cross-capture contamination)', () async {
    final cap = _FakeCapture();
    // One controller, one (delayed) transport: capture B starts before A's fetch resolves, so B wins.
    final c = _controller(cap, _FakeTransport(byUnit: true, delayMs: 40));
    final a = c.explainFor(unit: 'alpha', targetLanguage: 'en');
    final b = c.explainFor(unit: 'bravo', targetLanguage: 'en'); // supersedes A
    await Future.wait([a, b]);
    final readys = cap.calls.where((m) => m['phase'] == 'ready').toList();
    expect(readys, hasLength(1)); // A's resolved-but-superseded result was dropped
    final pos = (cap.lastReadings!.single['pos'] as List).single as Map;
    expect((pos['senses'] as List).single, 'bravo-meaning'); // B's result, not A's
  });

  test('a degenerate-junk unit → not_a_word, no fetch (RFC §B junk gate)', () async {
    final cap = _FakeCapture();
    final t = _FakeTransport(body: _explainHit('x'));
    final c = _controller(cap, t);
    await c.explainFor(unit: '→', targetLanguage: 'en'); // pure symbol — no letter in any script
    expect(cap.calls, [
      {'phase': 'not_a_word'},
    ]); // calm "not a word" slot, never loading
    expect(t.sends, 0); // and never spends an /explain call
  });

  test('a keyboard-mash unit → not_a_word, no fetch (L1 gibberish gate)', () async {
    final cap = _FakeCapture();
    final t = _FakeTransport(body: _explainHit('x'));
    final c = _controller(cap, t);
    await c.explainFor(unit: 'asdfgh', targetLanguage: 'en'); // single-token keyboard walk
    expect(cap.calls, [
      {'phase': 'not_a_word'},
    ]);
    expect(t.sends, 0); // never spends an /explain call on mash
  });

  test('a word-shaped non-word → loading then not_a_word from the model verdict (L3, 422)', () async {
    final cap = _FakeCapture();
    // "blorp" passes the local junk + gibberish gates (it's pronounceable), so it DOES reach /explain;
    // the backend's model gate returns 422 not_a_word, which the api maps to ExplainStatus.notAWord.
    final t = _FakeTransport(statusCode: 422, body: const {'error': 'not_a_word'});
    final c = _controller(cap, t);
    await c.explainFor(unit: 'blorp', targetLanguage: 'en');
    expect(cap.calls.map((m) => m['phase']).toList(), ['loading', 'not_a_word']);
    expect(t.sends, 1); // local gates can't catch word-shaped gibberish — only the model can
  });

  test(
    'a junk capture supersedes a prior in-flight fetch (no stale paint into the new slot)',
    () async {
      final cap = _FakeCapture();
      // A is a real word with a DELAYED fetch; B is junk and arrives before A resolves. B paints the
      // calm not_a_word slot, and it must still claim the generation so A's late result is dropped.
      final c = _controller(cap, _FakeTransport(byUnit: true, delayMs: 40));
      final a = c.explainFor(unit: 'alpha', targetLanguage: 'en'); // in-flight (shows loading)
      final b = c.explainFor(
        unit: '→',
        targetLanguage: 'en',
      ); // junk — supersedes A, paints nothing
      await Future.wait([a, b]);
      expect(cap.calls.where((m) => m['phase'] == 'ready'), isEmpty); // A's stale result dropped
      expect(cap.calls.map((m) => m['phase']).toList(), ['loading', 'not_a_word']);
    },
  );

  test('a cached unit → ready straight from cache, no loading, no fetch (RFC §B.3.1)', () async {
    final cap = _FakeCapture();
    final cache = _FakeCache()
      ..seed(
        'serendipity',
        'en',
        'en',
        readings: [
          (
            pronunciationPrimary: '',
            pronunciationSecondary: '',
            kind: null,
            pos: [
              (partOfSpeech: 'noun', senses: ['good fortune']),
            ],
          ),
        ],
      );
    final t = _FakeTransport(); // would 500-equivalent if hit; the point is it must NOT be hit
    final c = _controller(cap, t, cache: cache);
    await c.explainFor(unit: 'serendipity', targetLanguage: 'en');
    expect(cap.calls, [
      {'phase': 'ready'}, // no 'loading' — offline-instant
    ]);
    expect(t.sends, 0);
    final pos = (cap.lastReadings!.single['pos'] as List).single as Map;
    expect(pos['senses'], ['good fortune']);
  });

  test('a cache HIT restores the full content — every reading survives a re-capture', () async {
    final cap = _FakeCapture();
    final cache = _FakeCache()
      ..seed(
        'object',
        'en',
        'en',
        readings: [
          (
            pronunciationPrimary: 'ˈɑbdʒɛkt',
            pronunciationSecondary: 'ˈɒbdʒɪkt',
            kind: null,
            pos: [
              (partOfSpeech: 'noun', senses: ['a thing you can see or touch']),
            ],
          ),
          (
            pronunciationPrimary: 'əbˈdʒɛkt',
            pronunciationSecondary: 'əbˈdʒɛkt',
            kind: null,
            pos: [
              (partOfSpeech: 'verb', senses: ['to disagree']),
            ],
          ),
        ],
      );
    final t = _FakeTransport(); // must NOT be hit — the content comes from the cache, offline
    final c = _controller(cap, t, cache: cache);
    await c.explainFor(unit: 'object', targetLanguage: 'en');
    expect(t.sends, 0);
    expect(cap.calls, [
      {'phase': 'ready'},
    ]);
    expect(cap.lastReadings, [
      {
        'pronunciations': [
          {'label': 'US', 'display': '/ˈɑbdʒɛkt/'},
          {'label': 'UK', 'display': '/ˈɒbdʒɪkt/'},
        ],
        'isIdiom': false,
        'pos': [
          {
            'partOfSpeech': 'noun',
            'senses': ['a thing you can see or touch'],
            'note': '',
          },
        ],
      },
      {
        'pronunciations': [
          {'label': 'US', 'display': '/əbˈdʒɛkt/'},
          {'label': 'UK', 'display': '/əbˈdʒɛkt/'},
        ],
        'isIdiom': false,
        'pos': [
          {
            'partOfSpeech': 'verb',
            'senses': ['to disagree'],
            'note': '',
          },
        ],
      },
    ]);
  });

  test('a cache miss fetches, then caches the result for next time', () async {
    final cap = _FakeCapture();
    final cache = _FakeCache();
    final c = _controller(cap, _FakeTransport(body: _explainHit('good fortune')), cache: cache);
    await c.explainFor(unit: 'serendipity', targetLanguage: 'en');
    expect(cap.calls, [
      {'phase': 'loading'},
      {'phase': 'ready'},
    ]);
    expect(cache.writes, [
      {
        'unit': 'serendipity',
        'lang': 'en',
        'readings': [
          {
            'pronunciationPrimary': '',
            'pronunciationSecondary': '',
            'pos': [
              {
                'partOfSpeech': 'noun',
                'senses': ['good fortune'],
              },
            ],
          },
        ],
      },
    ]);
  });

  test('an enriched miss caches ALL readings (not just the primary)', () async {
    final cap = _FakeCapture();
    final cache = _FakeCache();
    final c = _controller(cap, _FakeTransport(body: _explainHitEnriched()), cache: cache);
    await c.explainFor(unit: 'object', targetLanguage: 'en');
    expect(cache.writes.single['readings'], [
      {
        'pronunciationPrimary': 'ˈɑbdʒɛkt',
        'pronunciationSecondary': 'ˈɒbdʒɪkt',
        'pos': [
          {
            'partOfSpeech': 'noun',
            'senses': ['a thing you can see or touch'],
          },
        ],
      },
      {
        'pronunciationPrimary': 'əbˈdʒɛkt',
        'pronunciationSecondary': 'əbˈdʒɛkt',
        'pos': [
          {
            'partOfSpeech': 'verb',
            'senses': ['to disagree'],
          },
        ],
      },
    ]);
  });

  test('a miss/failure result is never cached', () async {
    final cap = _FakeCapture();
    final cache = _FakeCache();
    final c = _controller(
      cap,
      _FakeTransport(body: const {'status': 'miss', 'explanation': null}),
      cache: cache,
    );
    await c.explainFor(unit: 'serendipity', targetLanguage: 'en');
    expect(cap.calls.last, {'phase': 'failed'});
    expect(cache.writes, isEmpty); // nothing useful to show offline next time
  });
}
