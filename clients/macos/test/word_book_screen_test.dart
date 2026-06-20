import 'dart:convert';

import 'package:capecho/word_book/word_book_screen.dart';
import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:capecho_local_store/capecho_local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake [LocalWordBook] (the signed-out data source) for the screen tests. Returns only the rows it
/// was given (the real adapter returns anonymous-only rows; isolation is unit-tested in local-store).
class _FakeLocalWordBook implements LocalWordBook {
  _FakeLocalWordBook(this._words);
  final List<WordRow> _words;

  /// Tests that open a detail can populate this; the catalog tests leave it empty.
  Map<String, List<ContextRow>> contextsById = const {};
  final List<String> deleted = [];
  final List<String> restored = [];

  @override
  List<WordRow> words() => _words.where((w) => !deleted.contains(w.clientRowId)).toList();
  @override
  List<ContextRow> contexts(String wordClientRowId) => contextsById[wordClientRowId] ?? const [];
  @override
  void softDelete(String id) => deleted.add(id);
  @override
  void restore(String id) => restored.add(id);
}

WordRow _localRow(String id, String unit, {int createdAt = 0}) => WordRow(
  clientRowId: id,
  installId: 'i',
  targetLanguage: 'en',
  surfaceUnit: unit,
  normalizedUnit: unit.toLowerCase(),
  targetNormalizationVersion: 'v1',
  isPhrase: false,
  source: 'ocr',
  createdAt: createdAt,
  updatedAt: createdAt,
  deletedAt: null,
  serverWordId: null,
  syncDirty: true,
  claimed: false,
  contextCount: 0,
);

/// Records every request path and 401s everything — mimics a real signed-out server, so a test can
/// assert the signed-out Word Book never hit the account-scoped `/words`.
class _Recording implements HttpTransport {
  final List<String> paths = [];
  @override
  Future<TransportResponse> send(TransportRequest r) async {
    paths.add(Uri.parse(r.url).path);
    return const TransportResponse(statusCode: 401, body: '{"error":"unauthorized"}');
  }
}

/// Serves `/auth/me` (so `AuthController.restore` signs in) + an empty `/words` + `/review/due`.
/// When [claimFails] is true, `POST /words/claim` returns 500 (drives the sync-failure path).
class _MeTransport implements HttpTransport {
  _MeTransport({this.claimFails = false});
  final bool claimFails;

  @override
  Future<TransportResponse> send(TransportRequest r) async {
    final path = Uri.parse(r.url).path;
    if (path.endsWith('/auth/me')) {
      return TransportResponse(
        statusCode: 200,
        body: jsonEncode({
          'user': {
            'id': 'acc',
            'iana_timezone': 'UTC',
            'explanation_language': 'en',
            'explanation_follows_learning': false,
            'learning_language': null,
            'reminder_enabled': false,
            'pro': false,
          },
        }),
      );
    }
    if (path.endsWith('/words/claim')) {
      return claimFails
          ? TransportResponse(statusCode: 500, body: jsonEncode({'error': 'internal_error'}))
          : TransportResponse(statusCode: 200, body: jsonEncode({'results': <Object>[]}));
    }
    if (path.endsWith('/words')) {
      return TransportResponse(statusCode: 200, body: jsonEncode({'words': <Object>[]}));
    }
    if (path.endsWith('/review/due')) {
      return TransportResponse(
        statusCode: 200,
        body: jsonEncode({
          'due': [],
          'new': [],
          'counts': {'due': 0, 'new': 0},
        }),
      );
    }
    return const TransportResponse(statusCode: 200, body: '{}');
  }
}

class _TokenStore implements SessionStore {
  _TokenStore(this._token);
  final String? _token;
  @override
  Future<String?> loadToken() async => _token;
  @override
  Future<void> saveToken(String t) async {}
  @override
  Future<void> clear() async {}
}

Map<String, dynamic> _word(
  String id,
  String unit, {
  String? pos,
  int createdAt = 0,
  Map<String, dynamic>? fsrs,
}) => {
  'id': id,
  'user_id': 'u',
  'target_language': 'en',
  'surface_unit': unit,
  'normalized_unit': unit.toLowerCase(),
  'target_normalization_version': 'v1',
  'is_phrase': false,
  'pos': pos,
  'explanation_state': 'ready',
  'explanation_cache_key': null,
  'fsrs_epoch': 0,
  'created_at': createdAt,
  'updated_at': createdAt,
  'deleted_at': null,
  'fsrs': ?fsrs,
};

class _Fake implements HttpTransport {
  _Fake({
    this.empty = false,
    this.badSpan = false,
    this.wordsDelayMs = 0,
    this.withGloss = false,
    this.explainQuota = false,
    this.explainDelayMs = 0,
    this.explainThrows = false,
    this.explainFailCount = 0,
    this.fsrsW1,
  });
  final bool empty;
  final bool badSpan;
  final int wordsDelayMs;
  final bool withGloss; // a persisted per-context gloss
  final bool explainQuota; // POST /explain/context → 429 quota_exhausted
  final int explainDelayMs; // delays /explain/context so the generating state is observable
  final bool explainThrows; // /explain/context transport failure → offline
  final int explainFailCount; // first N /explain/context calls return 502 → failed, then succeed
  final Map<String, dynamic>? fsrsW1; // optional per-unit FSRS projection on w1 (the memory meter)
  int _explainCalls = 0;

  @override
  Future<TransportResponse> send(TransportRequest r) async {
    final path = Uri.parse(r.url).path;
    Object body = const {};
    if (path.endsWith('/words')) {
      if (wordsDelayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: wordsDelayMs));
      }
      body = empty
          ? {'words': <Object>[]}
          : {
              'words': [
                _word('w1', 'serendipity', pos: 'noun', createdAt: 200, fsrs: fsrsW1),
                _word('w2', 'perfunctory', pos: 'adjective', createdAt: 100),
              ],
            };
    } else if (path.endsWith('/review/due')) {
      body = {
        'due': [],
        'new': [],
        'counts': {'due': 0, 'new': 0},
      };
    } else if (path.endsWith('/explain/context')) {
      // The paid sentence-layer (POST /explain/context).
      if (explainDelayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: explainDelayMs));
      }
      if (explainThrows) {
        throw Exception('offline'); // transport failure → offline
      }
      _explainCalls++;
      if (_explainCalls <= explainFailCount) {
        return TransportResponse(statusCode: 502, body: jsonEncode({'error': 'generation_failed'}));
      }
      if (explainQuota) {
        return TransportResponse(
          statusCode: 429,
          body: jsonEncode({'error': 'quota_exhausted', 'detail': 'daily limit'}),
        );
      }
      body = {
        'status': 'ready',
        'meaning': 'here the word means a sentence-specific meaning; the whole sentence rendered',
        'charged': true,
      };
    } else if (path.contains('/contexts/')) {
      // PATCH (edit) or DELETE (remove) a single context — both 2xx in the happy path.
      body = {'status': 'ok', 'id': path.split('/').last};
    } else if (path.endsWith('/contexts')) {
      body = {
        'contexts': [
          {
            'id': 'c1',
            'wordId': 'w1',
            'contextLanguage': 'en',
            'contextText': 'a moment of serendipity',
            'spanStart': badSpan ? 100 : 11,
            'spanEnd': badSpan ? 200 : 22,
            'meaning': withGloss
                ? 'here it means a sentence-specific meaning; the whole sentence rendered'
                : null,
            'createdAt': 1,
          },
        ],
      };
    } else if (path.endsWith('/export')) {
      // format=json → the structured rows the .apkg deck builder consumes; otherwise CSV text.
      if (Uri.parse(r.url).queryParameters['format'] == 'json') {
        return TransportResponse(
          statusCode: 200,
          body: jsonEncode([
            {
              'word': 'serendipity',
              'context': 'a moment of serendipity',
              'contextLanguage': '',
              'definition': '(n) good fortune',
              'targetLanguage': 'en',
            },
            {
              'word': 'perfunctory',
              'context': '',
              'contextLanguage': '',
              'definition': '',
              'targetLanguage': 'en',
            },
          ]),
        );
      }
      return const TransportResponse(statusCode: 200, body: 'word,context,explanation,language\n');
    } else if (path.endsWith('/explain')) {
      body = {
        'status': 'hit',
        'explanation': {
          'readings': [
            {
              'pronunciationPrimary': '',
              'pronunciationSecondary': '',
              'pos': [
                {
                  'partOfSpeech': 'noun',
                  'senses': ['good fortune'], // the detail meaning (the primary sense)
                },
              ],
            },
          ],
        },
      };
    }
    return TransportResponse(statusCode: 200, body: jsonEncode(body));
  }
}

/// A signed-in client (holds a bearer token) — the default catalog path shows the memory meter, not the
/// pre-login "not yet scheduled" treatment (the signed-out path is exercised separately, below).
CapechoApi _signedIn(HttpTransport t) =>
    CapechoApi(baseUrl: 'https://api.test', transport: t)..restoreToken('test-session');

void main() {
  testWidgets(
    'single-column catalog: masthead + rows + lazy context snippet; no detail until tapped',
    (tester) async {
      final api = _signedIn(_Fake());
      await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
      await tester.pumpAndSettle();

      expect(find.text('Word Book'), findsOneWidget); // toolbar title
      // Both words are catalog rows; nothing is auto-opened, so each appears exactly once.
      expect(find.text('serendipity'), findsOneWidget);
      expect(find.text('perfunctory'), findsOneWidget);
      // The per-row context snippet loads lazily from /contexts.
      expect(find.textContaining('a moment of serendipity'), findsWidgets);
      // The detail meaning is NOT shown on the catalog (detail is a pushed route).
      expect(find.textContaining('good fortune'), findsNothing);
    },
  );

  testWidgets('the row meter reads real FSRS — a due card shows "Due now" (US-1.2)', (
    tester,
  ) async {
    // w1 is due in the past (due_at=1) → the meter renders the full level + "Due now", not the
    // never-reviewed placeholder. Proves Word.fsrs is wired through to the meter.
    final api = _signedIn(
      _Fake(
        fsrsW1: const {
          'stability': 2.0,
          'difficulty': 5.0,
          'due_at': 1,
          'state': 'review',
          'reps': 1,
          'lapses': 0,
          'last_review_at': 1,
        },
      ),
    );
    await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('Due now'), findsOneWidget);
  });

  testWidgets('tapping a row pushes the detail (header + meaning + context)', (tester) async {
    final api = _signedIn(_Fake());
    await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('serendipity'));
    await tester.pumpAndSettle();

    // The pushed detail covers the catalog (which goes offstage), so serendipity is the detail header.
    expect(find.text('serendipity'), findsOneWidget);
    expect(find.textContaining('good fortune'), findsOneWidget); // detail meaning
    expect(find.textContaining('a moment of serendipity'), findsWidgets); // detail context

    // Esc pops back to the catalog.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('serendipity'), findsOneWidget); // back to catalog-only
    expect(find.textContaining('good fortune'), findsNothing);
  });

  testWidgets('tapping the row CONTEXT SNIPPET (not just the headword) also opens the detail', (
    tester,
  ) async {
    final api = _signedIn(_Fake());
    await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
    await tester.pumpAndSettle();

    // The whole card is the tap target — tapping the sentence snippet must navigate too.
    await tester.tap(find.textContaining('a moment of serendipity').first);
    await tester.pumpAndSettle();

    expect(find.textContaining('good fortune'), findsOneWidget); // we're on the detail
  });

  testWidgets('search with no matches shows the calm no-results line + Clear search', (
    tester,
  ) async {
    final api = _signedIn(_Fake());
    await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pumpAndSettle();
    expect(find.textContaining('No words or phrases match'), findsOneWidget);
    expect(find.text('Clear search'), findsOneWidget);
  });

  testWidgets('an out-of-range highlight span falls back to plain text (no crash)', (tester) async {
    final api = _signedIn(_Fake(badSpan: true));
    await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('a moment of serendipity'), findsWidgets);
  });

  testWidgets('loading shows the row skeleton (masthead/toolbar immediate, no crash) then the list', (
    tester,
  ) async {
    final api = _signedIn(_Fake(wordsDelayMs: 80));
    await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
    await tester
        .pump(); // loading phase — skeleton rows shimmer; masthead + toolbar render immediately
    expect(find.text('Word Book'), findsOneWidget); // toolbar renders before the list resolves
    expect(find.text('serendipity'), findsNothing); // rows not loaded yet
    expect(tester.takeException(), isNull); // the animating skeleton renders cleanly
    // Resolve the load (the skeleton's AnimationController is gone once we leave the loading phase).
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pumpAndSettle();
    expect(find.text('serendipity'), findsOneWidget);
  });

  testWidgets('empty Word Book shows the first-run invite (IL-02)', (tester) async {
    final api = _signedIn(_Fake(empty: true));
    await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
    await tester.pumpAndSettle();
    expect(find.textContaining('ready for its first word'), findsOneWidget);
    // The Export button is present but DISABLED — an empty Word Book has nothing to export.
    final exportBtn = tester.widget<TextButton>(find.widgetWithText(TextButton, 'Export'));
    expect(exportBtn.onPressed, isNull);
  });

  testWidgets('detail shows the memory meter + Explain CTA + Delete word (no word-edit)', (
    tester,
  ) async {
    final api = _signedIn(_Fake());
    await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('serendipity'));
    await tester.pumpAndSettle();

    expect(find.text('MEMORY'), findsOneWidget); // memory meter label
    expect(find.text('Explain here'), findsOneWidget); // paid CTA (no persisted gloss)
    // The "Free, with a daily limit" caption was removed — the lock glyph alone signals it's metered.
    expect(find.text('Free, with a daily limit'), findsNothing);
    expect(
      find.text('Edit word'),
      findsNothing,
    ); // the unit is immutable — no word-text edit affordance
    expect(find.text('Delete word'), findsOneWidget);
  });

  testWidgets('Explain here → generating → the real sentence gloss (state 13)', (tester) async {
    final api = _signedIn(_Fake(explainDelayMs: 60)); // so the generating state is observable
    await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('serendipity'));
    await tester.pumpAndSettle();

    final cta = find.text('Explain here');
    await tester.ensureVisible(cta);
    await tester.tap(cta);
    await tester.pump(); // generating — the /explain/context call is mid-flight
    expect(find.textContaining('Working out what'), findsOneWidget);
    await tester.pumpAndSettle(); // POST /explain/context resolves → stored gloss
    // The combined meaning renders directly (no fixed format, no disclosure toggle).
    expect(
      find.text('here the word means a sentence-specific meaning; the whole sentence rendered'),
      findsOneWidget,
    );
    expect(find.text('Explain here'), findsNothing); // CTA gone once a gloss exists
  });

  testWidgets('Explain → quota exhausted shows the daily-limit message (state 14)', (tester) async {
    final api = _signedIn(_Fake(explainQuota: true));
    await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('serendipity'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Explain here'));
    await tester.tap(find.text('Explain here'));
    await tester.pumpAndSettle(); // 429 → quota
    expect(find.text('Context explanations are done for today'), findsOneWidget);
    // No fake "waitlist" CTA — Pro (unlimited in-context) is purchasable now, so the copy says so.
    expect(find.text('Join the waitlist'), findsNothing);
    expect(find.textContaining('Pro removes the daily cap'), findsOneWidget);
  });

  testWidgets('Explain → offline (transport failure) shows the connection message (state 15)', (
    tester,
  ) async {
    final api = _signedIn(_Fake(explainThrows: true));
    await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('serendipity'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Explain here'));
    await tester.tap(find.text('Explain here'));
    await tester.pumpAndSettle(); // transport throw → offline
    expect(find.text('Explaining in context needs a connection'), findsOneWidget);
    expect(find.text('Retry'), findsNothing); // offline intentionally has no retry button
  });

  testWidgets(
    'Explain → failed (502) shows the failed message, then Retry succeeds (states 16→13)',
    (tester) async {
      final api = _signedIn(_Fake(explainFailCount: 1)); // first call 502, retry succeeds
      await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('serendipity'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Explain here'));
      await tester.tap(find.text('Explain here'));
      await tester.pumpAndSettle(); // 502 → failed
      expect(find.text('Couldn’t generate that explanation'), findsOneWidget);

      await tester.ensureVisible(find.text('Retry'));
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle(); // the retry call succeeds → gloss
      expect(
        find.text('here the word means a sentence-specific meaning; the whole sentence rendered'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'editing a context clears a stale failed-explain message + restores the CTA (CR fix)',
    (tester) async {
      final api = _signedIn(_Fake(explainFailCount: 99)); // explain always fails
      await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('serendipity'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Explain here'));
      await tester.tap(find.text('Explain here'));
      await tester.pumpAndSettle(); // 502 → failed
      expect(find.text('Couldn’t generate that explanation'), findsOneWidget);

      // Edit + save the sentence — the stale failed message must clear and the CTA must return.
      await tester.ensureVisible(find.text('Edit'));
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'an edited sentence');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Couldn’t generate that explanation'), findsNothing);
      expect(find.text('Explain here'), findsOneWidget);
    },
  );

  testWidgets('Edit context → Save persists the new sentence (real PATCH)', (tester) async {
    final api = _signedIn(_Fake());
    await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('serendipity'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Edit')); // the per-context Edit (not "Edit word")
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'an edited sentence about serendipity');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('an edited sentence about serendipity'), findsWidgets);
  });

  testWidgets('Remove context → the sentence is gone (real DELETE)', (tester) async {
    final api = _signedIn(_Fake());
    await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('serendipity'));
    await tester.pumpAndSettle();
    expect(find.textContaining('a moment of serendipity'), findsWidgets);

    await tester.ensureVisible(find.text('Remove'));
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.textContaining('a moment of serendipity'), findsNothing);
  });

  testWidgets('a persisted gloss renders the combined in-context meaning (detail state 13)', (
    tester,
  ) async {
    final api = _signedIn(_Fake(withGloss: true));
    await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('serendipity'));
    await tester.pumpAndSettle();

    // One combined explanation renders directly — no fixed format, no disclosure toggle.
    expect(
      find.text('here it means a sentence-specific meaning; the whole sentence rendered'),
      findsOneWidget,
    );
    expect(find.text('Explain here'), findsNothing); // CTA hidden when a gloss exists
  });

  testWidgets(
    'signed out reads the LOCAL catalog (never the server) + the pre-login banner (state 5)',
    (tester) async {
      // No token → controller.preLogin == true → it reads the device-local source, NOT `/words`.
      final t = _Recording();
      final api = CapechoApi(baseUrl: 'https://api.test', transport: t);
      final local = _FakeLocalWordBook([
        _localRow('l1', 'serendipity', createdAt: 200),
        _localRow('l2', 'perfunctory', createdAt: 100),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: WordBookScreen(api: api, local: local),
        ),
      );
      await tester.pumpAndSettle();

      // The local words render…
      expect(find.text('serendipity'), findsOneWidget);
      expect(find.text('perfunctory'), findsOneWidget);
      // …and the account-scoped `/words` was never called (isolation: signed-out reads local only).
      expect(t.paths.any((p) => p.endsWith('/words')), isFalse);

      // The pre-login treatment is intact.
      expect(find.textContaining('saved on this Mac'), findsOneWidget); // banner
      expect(find.text('Sign in'), findsOneWidget); // banner CTA
      expect(find.textContaining('Not yet scheduled'), findsWidgets); // per-row note
      expect(find.text('Not signed in'), findsOneWidget); // masthead meta
      expect(find.textContaining('on this device'), findsOneWidget); // count suffix
      // Export is server-backed → hidden signed-out.
      expect(find.text('Export'), findsNothing);
    },
  );

  testWidgets('signed in with un-synced local captures shows the "Sync N" banner', (tester) async {
    final auth = AuthController(
      api: CapechoApi(baseUrl: 'https://api.test', transport: _MeTransport()),
      store: _TokenStore('test-session'),
      collectClaimRows: () async => const [],
      installId: () async => 'i',
      anonymousCount: () => 2, // two local captures await sync
    );
    await auth.restore();
    expect(auth.isSignedIn, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: WordBookScreen(api: auth.api, auth: auth),
      ),
    );
    await tester.pumpAndSettle();

    // The signed-in catalog is server-backed (empty here) and the explicit-sync banner is offered.
    expect(find.textContaining('on this device'), findsOneWidget);
    expect(find.text('Sync'), findsOneWidget);
    // No pre-login banner when signed in.
    expect(find.textContaining('saved on this Mac'), findsNothing);
  });

  testWidgets('a failed Sync surfaces an error (not a silent no-op) and keeps the banner', (
    tester,
  ) async {
    final auth = AuthController(
      api: CapechoApi(baseUrl: 'https://api.test', transport: _MeTransport(claimFails: true)),
      store: _TokenStore('test-session'),
      collectClaimRows: () async => const [
        ClaimRow(clientRowId: 'r1', surfaceUnit: 'serendipity', targetLanguage: 'en'),
      ],
      installId: () async => 'i',
      markClaimed: (_, _) {},
      anonymousCount: () => 1,
    );
    await auth.restore();
    await tester.pumpWidget(
      MaterialApp(
        home: WordBookScreen(api: auth.api, auth: auth),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sync'), findsOneWidget);
    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();

    // The failure is surfaced (was previously a silent no-op)…
    expect(find.textContaining('Couldn’t sync'), findsOneWidget);
    // …and the banner stays for a retry (nothing was claimed).
    expect(find.text('Sync'), findsOneWidget);
  });

  testWidgets('signed-in catalog shows no pre-login banner (state 3, the meter path)', (
    tester,
  ) async {
    final api = _signedIn(_Fake());
    await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
    await tester.pumpAndSettle();
    expect(find.textContaining('saved on this Mac'), findsNothing);
    expect(find.textContaining('Not yet scheduled'), findsNothing);
  });

  testWidgets('Export → CSV → saved to a .csv file (dialog states 17 + 19)', (tester) async {
    final api = _signedIn(_Fake());
    String? savedName;
    Uint8List? savedBytes;
    Future<String?> saver({required String suggestedName, required Uint8List bytes}) async {
      savedName = suggestedName;
      savedBytes = bytes;
      return '/tmp/$suggestedName'; // simulate a successful save panel
    }

    await tester.pumpWidget(
      MaterialApp(
        home: WordBookScreen(api: api, saveExportFile: saver),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect(find.text('Export Word Book'), findsOneWidget); // dialog title
    expect(find.text('Anki deck'), findsOneWidget);
    expect(
      find.textContaining('captured with Capecho'),
      findsOneWidget,
    ); // attribution toggle (off)

    await tester.tap(find.text('CSV')); // switch format
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export CSV'));
    await tester.pumpAndSettle();
    expect(find.text('Word Book exported'), findsOneWidget); // complete
    expect(find.textContaining('capecho-export.csv'), findsOneWidget);
    // The CSV body (not the clipboard) was handed to the native save panel as a .csv.
    expect(savedName, 'capecho-export.csv');
    expect(utf8.decode(savedBytes!), contains('word,context'));
  });

  testWidgets('Export → Anki → builds + saves a one-click .apkg deck (no more "coming soon")', (
    tester,
  ) async {
    final api = _signedIn(_Fake());
    String? savedName;
    Uint8List? savedBytes;
    Future<String?> saver({required String suggestedName, required Uint8List bytes}) async {
      savedName = suggestedName;
      savedBytes = bytes;
      return '/tmp/$suggestedName';
    }

    await tester.pumpWidget(
      MaterialApp(
        home: WordBookScreen(api: api, saveExportFile: saver),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export deck')); // Anki is the default format
    await tester.pumpAndSettle();

    // Lands on the same "exported" screen — no calm "coming soon" placeholder anymore.
    expect(find.text('Word Book exported'), findsOneWidget);
    expect(find.text('Anki deck export'), findsNothing);
    expect(find.textContaining('capecho.apkg'), findsOneWidget);
    expect(savedName, 'capecho.apkg');
    // A real ZIP (.apkg) was assembled on-device — the bytes start with the 'PK' local-header signature.
    expect(savedBytes!.sublist(0, 2), [0x50, 0x4b]);
  });

  testWidgets('Delete word → Recently deleted → Restore (state 10)', (tester) async {
    final api = _signedIn(_Fake());
    await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('serendipity'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Delete word'));
    await tester.tap(find.text('Delete word'));
    await tester.pumpAndSettle();

    // Back on the catalog: serendipity is gone, the Recently-deleted entry point (a compact icon+count
    // with the full label in its tooltip) appeared.
    expect(find.text('serendipity'), findsNothing);
    expect(find.byTooltip('Recently deleted (1)'), findsOneWidget);

    await tester.tap(find.byTooltip('Recently deleted (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Recently deleted'), findsWidgets); // the route head
    expect(find.text('serendipity'), findsOneWidget); // the deleted row
    expect(find.text('Restore'), findsOneWidget);

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    // The route pops itself (list empty); serendipity is back in the catalog, the entry point is gone.
    expect(find.text('serendipity'), findsOneWidget);
    expect(find.byTooltip('Recently deleted (1)'), findsNothing);
  });

  testWidgets('root Word Book shows the brand header, no back button', (tester) async {
    // Opened straight from the menu bar (no onBack) -> the shared header leads with the Capecho. brand
    // and the catalog dismisses via Esc / the window, so there is no back chevron.
    final api = _signedIn(_Fake());
    await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('Word Book'), findsOneWidget); // the unified header title
    expect(find.byIcon(Icons.chevron_left), findsNothing); // no back button on a root surface
  });

  testWidgets('nested Word Book (from Settings) shows a back button wired to onBack', (
    tester,
  ) async {
    // Opened FROM Settings (onBack provided) -> the shared header swaps the brand for a "Settings" back
    // button; tapping it calls onBack (the host pops the slide-in route).
    var backs = 0;
    final api = _signedIn(_Fake());
    await tester.pumpWidget(
      MaterialApp(
        home: WordBookScreen(api: api, onBack: () => backs++, backLabel: 'Settings'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_left), findsOneWidget); // the back chevron
    expect(find.text('Settings'), findsOneWidget); // its label = the parent surface
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(backs, 1);
  });

  testWidgets('a tapped detail shows a "Word Book" back button (nested page)', (tester) async {
    final api = _signedIn(_Fake());
    await tester.pumpWidget(MaterialApp(home: WordBookScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('serendipity'));
    await tester.pumpAndSettle();
    // The pushed detail wears the shared header with a back-to-catalog button.
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    expect(find.text('Word Book'), findsOneWidget); // the back label (catalog is offstage)
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.text('Explain here'), findsNothing); // detail gone, back on the catalog
  });
}
