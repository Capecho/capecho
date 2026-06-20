import 'dart:convert';

import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter_test/flutter_test.dart';

class _Net implements Exception {
  const _Net();
}

class FakeTransport implements HttpTransport {
  final List<TransportRequest> reqs = [];
  Object wordsBody = {'words': []};
  Object contextsBody = {'contexts': []};
  Object explainBody = {'status': 'language_unsupported'};
  Object exportBody = 'word,context\n';
  Object dueBody = {
    'due': [],
    'new': [],
    'counts': {'due': 0, 'new': 0},
  };
  Object explainContextBody = {
    'status': 'ready',
    'meaning': 'here the word means sentence meaning; the whole sentence here',
    'charged': true,
  };
  int explainContextStatus = 200; // 429 → quota_exhausted
  int contextOpStatus = 200; // PATCH/DELETE /contexts/{id}
  Object contextOpBody = const {'status': 'ok'};
  bool wordsThrows = false;
  bool contextsThrows = false;
  bool explainContextThrows = false; // a transport failure on /explain/context (offline)
  int wordOpStatus =
      200; // DELETE /words/{id} + POST /words/{id}/restore (500 → optimistic rollback)

  @override
  Future<TransportResponse> send(TransportRequest r) async {
    reqs.add(r);
    final path = Uri.parse(r.url).path;
    if (path.endsWith('/words')) {
      if (wordsThrows) throw const _Net();
      return _ok(wordsBody);
    }
    if (path.contains('/words/')) {
      // DELETE /words/{id} (soft-delete) or POST /words/{id}/restore.
      return TransportResponse(statusCode: wordOpStatus, body: '{}');
    }
    if (path.endsWith('/review/due')) return _ok(dueBody);
    if (path.endsWith('/explain/context')) {
      if (explainContextThrows) throw const _Net();
      return TransportResponse(
        statusCode: explainContextStatus,
        body: jsonEncode(explainContextBody),
      );
    }
    if (path.contains('/contexts/')) {
      // PATCH (edit) or DELETE (remove) a single context.
      return TransportResponse(statusCode: contextOpStatus, body: jsonEncode(contextOpBody));
    }
    if (path.endsWith('/contexts')) {
      if (contextsThrows) throw const _Net();
      return _ok(contextsBody);
    }
    if (path.endsWith('/explain')) return _ok(explainBody);
    if (path.endsWith('/export')) return _ok(exportBody);
    return const TransportResponse(statusCode: 200, body: '{}');
  }

  TransportResponse _ok(Object b) =>
      TransportResponse(statusCode: 200, body: b is String ? b : jsonEncode(b));
}

Map<String, dynamic> word(
  String id,
  String unit, {
  String? pos,
  String lang = 'en',
  int createdAt = 0,
  int? deletedAt,
  bool isPhrase = false,
}) => {
  'id': id,
  'user_id': 'u',
  'target_language': lang,
  'surface_unit': unit,
  'normalized_unit': unit.toLowerCase(),
  'target_normalization_version': 'v1',
  'is_phrase': isPhrase,
  'pos': pos,
  'explanation_state': 'ready',
  'explanation_cache_key': null,
  'fsrs_epoch': 0,
  'created_at': createdAt,
  'updated_at': createdAt,
  'deleted_at': deletedAt,
};

Map<String, dynamic> ctx(String text, {int? start, int? end, String wordId = 'w1'}) => {
  'id': 'c1',
  'wordId': wordId,
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

WordBookController make(FakeTransport t, {String lang = 'en'}) => WordBookController(
  api: CapechoApi(baseUrl: 'https://api.test', transport: t),
  explanationLanguage: lang,
);

void main() {
  test('load sorts newest-first; opening a word loads its detail', () async {
    final t = FakeTransport()
      ..wordsBody = {
        'words': [word('w1', 'old', createdAt: 100), word('w2', 'new', createdAt: 200, pos: 'adj')],
      }
      ..contextsBody = {
        'contexts': [ctx('a new sentence here', start: 2, end: 5, wordId: 'w2')],
      }
      ..explainBody = explainHit('fresh, recent', pos: 'adj');
    final c = make(t);
    await c.load();
    await settle();
    expect(c.phase, WordBookPhase.loaded);
    expect(c.totalCount, 2);
    expect(c.visible.first.unit, 'new'); // newest-first (WB-2)
    expect(c.selectedId, isNull); // single-column catalog: nothing auto-selected
    // Opening a word (the detail route) loads its meaning + contexts.
    c.select(c.visible.first.id);
    await settle();
    expect(c.selected!.meaningStatus, DetailMeaningStatus.ready);
    expect(c.selected!.meaning!.primarySense, 'fresh, recent');
    expect(c.selected!.contexts.length, 1);
  });

  test('ensureCatalogContext loads the row snippet (contexts only, no meaning fetch)', () async {
    final t = FakeTransport()
      ..wordsBody = {
        'words': [word('w1', 'x', createdAt: 200)],
      }
      ..contextsBody = {
        'contexts': [ctx('a snippet here', start: 2, end: 9)],
      }
      ..explainBody = explainHit('should NOT be fetched by the catalog');
    final c = make(t);
    await c.load();
    await settle();
    final e = c.visible.first;
    await c.ensureCatalogContext(e);
    expect(e.latestContext?.contextText, 'a snippet here');
    expect(e.meaningStatus, DetailMeaningStatus.idle); // catalog never calls /explain
    expect(t.reqs.any((r) => Uri.parse(r.url).path.endsWith('/explain')), isFalse);
  });

  test('dueToday is populated from /review/due (best-effort, never blocks the list)', () async {
    final t = FakeTransport()
      ..wordsBody = {
        'words': [word('w1', 'x', createdAt: 1)],
      }
      ..dueBody = {
        'due': [],
        'new': [],
        'counts': {'due': 7, 'new': 0},
      };
    final c = make(t);
    await c.load();
    await settle();
    expect(c.phase, WordBookPhase.loaded);
    expect(c.dueToday, 7);
  });

  test('search filters by unit (WB-3); clearing restores all', () async {
    final t = FakeTransport()
      ..wordsBody = {
        'words': [word('w1', 'serendipity'), word('w2', 'perfunctory')],
      }
      ..explainBody = explainHit('m');
    final c = make(t);
    await c.load();
    await settle();
    c.search('seren');
    expect(c.visible.length, 1);
    expect(c.visible.first.unit, 'serendipity');
    c.search('');
    expect(c.visible.length, 2);
  });

  test('selecting a different word loads that word’s detail', () async {
    final t = FakeTransport()
      ..wordsBody = {
        'words': [word('w1', 'a', createdAt: 200), word('w2', 'b', createdAt: 100)],
      }
      ..explainBody = explainHit('m');
    final c = make(t);
    await c.load();
    await settle(); // auto-selected w1 (newest)
    final b = c.visible.firstWhere((e) => e.unit == 'b');
    c.select(b.id);
    await settle();
    expect(c.selectedId, b.id);
    expect(c.selected!.detailLoaded, isTrue);
  });

  test('a context-less word shows empty contexts but still loads a meaning', () async {
    final t = FakeTransport()
      ..wordsBody =
          {
            'words': [word('w1', 'x')],
          } // contextsBody default = empty
      ..explainBody = explainHit('to do');
    final c = make(t);
    await c.load();
    c.select(c.visible.first.id);
    await settle();
    expect(c.selected!.contexts, isEmpty);
    expect(c.selected!.meaningStatus, DetailMeaningStatus.ready);
  });

  test('a non-English (unsupported) target shows the unavailable meaning treatment', () async {
    final t = FakeTransport()
      ..wordsBody = {
        'words': [word('w1', 'Sehnsucht', lang: 'de')],
      }
      ..explainBody = {'status': 'language_unsupported'};
    final c = make(t);
    await c.load();
    c.select(c.visible.first.id);
    await settle();
    expect(c.selected!.meaningStatus, DetailMeaningStatus.unsupported);
  });

  test('an empty Word Book → empty phase', () async {
    final c = make(FakeTransport()..wordsBody = {'words': []});
    await c.load();
    expect(c.phase, WordBookPhase.empty);
    expect(c.totalCount, 0);
  });

  test('a soft-deleted word is excluded from the catalog', () async {
    final t = FakeTransport()
      ..wordsBody = {
        'words': [
          word('w1', 'alive', createdAt: 200),
          word('w2', 'gone', createdAt: 100, deletedAt: 150),
        ],
      }
      ..explainBody = explainHit('m');
    final c = make(t);
    await c.load();
    await settle();
    expect(c.totalCount, 1);
    expect(c.visible.single.unit, 'alive');
  });

  test('listWords failure → error phase', () async {
    final c = make(FakeTransport()..wordsThrows = true);
    await c.load();
    expect(c.phase, WordBookPhase.error);
    expect(c.error, isNotNull);
  });

  test(
    'a contexts fetch failure is distinguished from a context-less word, and Retry recovers',
    () async {
      final t = FakeTransport()
        ..wordsBody = {
          'words': [word('w1', 'x')],
        }
        ..explainBody = explainHit('m')
        ..contextsThrows = true;
      final c = make(t);
      await c.load();
      c.select(c.visible.first.id);
      await settle();
      expect(c.selected!.contextsFailed, isTrue); // a failure, not "context-less"
      expect(c.selected!.contexts, isEmpty);
      // Recover: contexts now succeed; Retry re-fetches the detail.
      t.contextsThrows = false;
      t.contextsBody = {
        'contexts': [ctx('a real sentence here', start: 2, end: 6)],
      };
      c.retryDetail(c.selectedId!);
      await settle();
      expect(c.selected!.contextsFailed, isFalse);
      expect(c.selected!.contexts.length, 1);
    },
  );

  test('exportCsv returns the CSV text', () async {
    final t = FakeTransport()
      ..wordsBody = {
        'words': [word('w1', 'x')],
      }
      ..explainBody = explainHit('m')
      ..exportBody = 'word,context\nx,\n';
    final c = make(t);
    await c.load();
    await settle();
    final csv = await c.exportCsv();
    expect(csv, contains('word,context'));
  });

  test('exportCsv(attribution: true) carries the attribution flag; default omits it', () async {
    final t = FakeTransport()
      ..wordsBody = {
        'words': [word('w1', 'x')],
      }
      ..exportBody = 'word,context\n';
    final c = make(t);
    await c.load();
    await settle();
    await c.exportCsv(attribution: true);
    expect(t.reqs.last.url, contains('attribution=true'));
    await c.exportCsv(); // default OFF (the r/Anki community punishes spam)
    expect(t.reqs.last.url, isNot(contains('attribution')));
  });

  test('preLogin/signedIn reflect the api session (mock state 5 gate)', () async {
    final signedOut = make(FakeTransport()..wordsBody = {'words': []});
    expect(signedOut.preLogin, isTrue);
    expect(signedOut.signedIn, isFalse);
    final api = CapechoApi(baseUrl: 'https://api.test', transport: FakeTransport())
      ..restoreToken('t');
    final signedIn = WordBookController(api: api);
    expect(signedIn.preLogin, isFalse);
    expect(signedIn.signedIn, isTrue);
  });

  test(
    'deleteEntry → recentlyDeleted (excluded from catalog); restoreEntry brings it back',
    () async {
      final t = FakeTransport()
        ..wordsBody = {
          'words': [word('w1', 'keep', createdAt: 200), word('w2', 'drop', createdAt: 100)],
        };
      final c = make(t);
      await c.load();
      await settle();
      expect(c.totalCount, 2);

      c.deleteEntry('w2');
      expect(c.totalCount, 1);
      expect(c.visible.single.unit, 'keep');
      expect(c.recentlyDeleted.single.unit, 'drop');
      expect(c.recentlyDeleted.single.locallyDeletedAt, isNotNull);

      c.restoreEntry('w2');
      expect(c.recentlyDeleted, isEmpty);
      expect(c.totalCount, 2);
      // Restored newest-first by created_at (w1 200 > w2 100).
      expect(c.visible.map((e) => e.unit).toList(), ['keep', 'drop']);
      expect(c.visible.firstWhere((e) => e.id == 'w2').locallyDeletedAt, isNull);
    },
  );

  test('deleteEntry rolls back into the catalog when the soft-delete is rejected', () async {
    final t = FakeTransport()
      ..wordsBody = {
        'words': [word('w1', 'keep', createdAt: 200), word('w2', 'drop', createdAt: 100)],
      };
    final c = make(t);
    await c.load();
    await settle();

    t.wordOpStatus = 500; // the server rejects the soft-delete
    c.deleteEntry('w2');
    expect(c.recentlyDeleted.single.unit, 'drop'); // optimistic: removed from the catalog at once
    await settle(); // let the unawaited persist + rollback run
    expect(c.recentlyDeleted, isEmpty); // ...then rolled back when the server said no
    expect(c.visible.map((e) => e.unit).toList(), ['keep', 'drop']); // back in the catalog, sorted
  });

  test('deleting the only word → empty phase; restoring → loaded', () async {
    final t = FakeTransport()
      ..wordsBody = {
        'words': [word('w1', 'solo', createdAt: 1)],
      };
    final c = make(t);
    await c.load();
    await settle();
    c.deleteEntry('w1');
    expect(c.phase, WordBookPhase.empty);
    expect(c.recentlyDeleted.single.unit, 'solo');
    c.restoreEntry('w1');
    expect(c.phase, WordBookPhase.loaded);
    expect(c.totalCount, 1);
  });

  // ---- context layer (real routes) ----------------------------------------

  Future<(WordBookController, WordBookEntry)> loadedWithContext(
    FakeTransport t, {
    Map<String, dynamic>? context,
  }) async {
    t
      ..wordsBody = {
        'words': [word('w1', 'x', createdAt: 1)],
      }
      ..contextsBody = {
        'contexts': [context ?? ctx('a moment here', start: 2, end: 6)],
      }
      ..explainBody = explainHit('m');
    final c = make(t);
    await c.load();
    c.select('w1');
    await settle();
    return (c, c.visible.single);
  }

  test(
    'explainContext stores the returned combined gloss and returns ready (states 12→13)',
    () async {
      final (c, e) = await loadedWithContext(FakeTransport());
      expect(e.contexts.single.hasGloss, isFalse);
      final outcome = await c.explainContext(e, 'c1');
      expect(outcome, ContextExplainOutcome.ready);
      expect(
        e.contexts.single.meaning,
        'here the word means sentence meaning; the whole sentence here',
      );
    },
  );

  test('explainContext maps 429 to quota (state 14)', () async {
    final t = FakeTransport()
      ..explainContextStatus = 429
      ..explainContextBody = {'error': 'quota_exhausted', 'detail': 'limit'};
    final (c, e) = await loadedWithContext(t);
    expect(await c.explainContext(e, 'c1'), ContextExplainOutcome.quota);
  });

  test('explainContext maps a transport failure to offline (state 15)', () async {
    final t = FakeTransport()..explainContextThrows = true;
    final (c, e) = await loadedWithContext(t);
    expect(await c.explainContext(e, 'c1'), ContextExplainOutcome.offline);
    expect(e.contexts.single.hasGloss, isFalse); // nothing stored
  });

  test('explainContext maps a 502 to failed (state 16)', () async {
    final t = FakeTransport()
      ..explainContextStatus = 502
      ..explainContextBody = {'error': 'generation_failed', 'detail': 'oops'};
    final (c, e) = await loadedWithContext(t);
    expect(await c.explainContext(e, 'c1'), ContextExplainOutcome.failed);
  });

  test('editContext updates the sentence + clears the stale gloss', () async {
    final (c, e) = await loadedWithContext(
      FakeTransport(),
      context: ctx('old sentence', start: 0, end: 3)..['meaning'] = 'old combined gloss',
    );
    expect(e.contexts.single.meaning, 'old combined gloss');
    final err = await c.editContext(e, 'c1', 'a new sentence');
    expect(err, isNull);
    expect(e.contexts.single.contextText, 'a new sentence');
    expect(e.contexts.single.hasGloss, isFalse); // server clears the gloss on edit
  });

  test('editContext surfaces an error message on failure (422)', () async {
    final t = FakeTransport()
      ..contextOpStatus = 422
      ..contextOpBody = {'error': 'empty_context'};
    final (c, e) = await loadedWithContext(t);
    final err = await c.editContext(e, 'c1', '');
    expect(err, 'A sentence can’t be empty.');
    expect(e.contexts.single.contextText, 'a moment here'); // unchanged
  });

  test('removeContext drops the context', () async {
    final (c, e) = await loadedWithContext(FakeTransport());
    expect(e.contexts, hasLength(1));
    final err = await c.removeContext(e, 'c1');
    expect(err, isNull);
    expect(e.contexts, isEmpty);
  });

  test('removeContext surfaces an error + keeps the context on failure', () async {
    final t = FakeTransport()..contextOpStatus = 500;
    final (c, e) = await loadedWithContext(t);
    final err = await c.removeContext(e, 'c1');
    expect(err, isNotNull);
    expect(e.contexts, hasLength(1)); // not dropped
  });
}
