import 'dart:convert';

import 'package:capecho/review/review_screen.dart';
import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Serves one due card (with context + an English meaning), so the screen can render the full
/// front → flip → back → rate → done path.
class _Fake implements HttpTransport {
  _Fake({
    this.dueEmpty = false,
    this.wordsStatus = 200,
    this.cards = 1,
    this.heteronym = false,
    this.withPronunciation = false,
    this.reviewStatus = 200,
  });
  final bool dueEmpty;
  final int wordsStatus;
  final int cards;

  /// Non-2xx makes `submitReview` throw → the rating queues offline (drives the sync badge).
  final int reviewStatus;

  /// When true, `/explain` returns a heteronym (two readings with distinct pronunciations) — used to
  /// prove the back stays the one summary with no reading/chip (a single line can't carry two
  /// pronunciations) and never surfaces the per-reading modules.
  final bool heteronym;

  /// When true, `/explain` returns enriched pronunciations — used to prove a single-reading word's IPA
  /// surfaces on the back beneath the head (but never on the front).
  final bool withPronunciation;

  @override
  Future<TransportResponse> send(TransportRequest r) async {
    final path = Uri.parse(r.url).path;
    Object body = const {};
    int status = 200;
    if (path.endsWith('/review/due')) {
      body = dueEmpty
          ? {
              'due': [],
              'new': [],
              'counts': {'due': 0, 'new': 0},
            }
          : {
              'due': [
                for (var i = 1; i <= cards; i++)
                  {
                    'wordId': 'w$i',
                    'surfaceUnit': i == 1 ? 'serendipity' : 'word$i',
                    'targetLanguage': 'en',
                    'state': 'new',
                    'dueAt': 0,
                    'isNew': true,
                  },
              ],
              'new': [],
              'counts': {'due': cards, 'new': 0},
            };
    } else if (path.endsWith('/contexts')) {
      body = {
        'contexts': [
          {
            'id': 'c1',
            'wordId': 'w1',
            'contextLanguage': 'en',
            'contextText': 'a moment of serendipity',
            'spanStart': 11,
            'spanEnd': 22,
            'meaning': null,
            'createdAt': 1,
          },
        ],
      };
    } else if (path.endsWith('/explain')) {
      body = {
        'status': 'hit',
        'explanation': {
          // Per-POS senses — the back renders these (grouped by POS), pronunciation suppressed on the
          // card (it sits in the head; E7 keeps the answer minimal).
          'readings': heteronym
              ? [
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
                ]
              : [
                  {
                    'pronunciationPrimary': withPronunciation ? 'ˌsɛrənˈdɪpɪti' : '',
                    'pronunciationSecondary': withPronunciation ? 'ˌsɛrənˈdɪpɪti' : '',
                    'pos': [
                      {
                        'partOfSpeech': 'noun',
                        'senses': ['good fortune'],
                      },
                    ],
                  },
                ],
        },
      };
    } else if (path.endsWith('/review')) {
      status = reviewStatus;
      body = {'status': 'applied', 'replay': false, 'card': null};
    } else if (path.endsWith('/words')) {
      status = wordsStatus;
      body = {'words': []};
    }
    return TransportResponse(statusCode: status, body: jsonEncode(body));
  }
}

/// A SIGNED-IN client (holds a token) — gets `ReviewController.start()` past the signed-out gate to
/// the real `/review/due` fetch, which is what every card-flow test below exercises.
CapechoApi _api(HttpTransport t) =>
    CapechoApi(baseUrl: 'https://api.test', transport: t)..restoreToken('test-session');

class _NoStore implements SessionStore {
  @override
  Future<String?> loadToken() async => null;
  @override
  Future<void> saveToken(String t) async {}
  @override
  Future<void> clear() async {}
}

/// A signed-OUT auth controller (no token restored) for the gate test.
AuthController _signedOutAuth() => AuthController(
  api: CapechoApi(baseUrl: 'https://api.test', transport: _Fake()),
  store: _NoStore(),
  collectClaimRows: () async => const [],
  installId: () async => 'i',
);

void main() {
  testWidgets('front → flip (Space) → back → rate (tap Good) → done', (tester) async {
    final api = _api(_Fake());
    await tester.pumpWidget(MaterialApp(home: ReviewScreen(api: api)));
    await tester.pumpAndSettle();

    // Front: task prompt + the highlighted sentence; ratings are back-only.
    expect(find.text('DO YOU KNOW THIS WORD HERE?'), findsOneWidget);
    expect(find.textContaining('serendipity'), findsWidgets);
    expect(find.text('Good'), findsNothing);

    // Flip with Space → the back shows the meaning + the four ratings.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.textContaining('good fortune'), findsOneWidget);
    expect(find.text('Forget'), findsOneWidget);
    expect(find.text('Good'), findsOneWidget);

    // Rate Good → advances past the only card to the session-end state.
    await tester.tap(find.text('Good'));
    await tester.pumpAndSettle();
    expect(find.text('That’s the set.'), findsOneWidget);
    expect(find.text('1 reviewed today'), findsOneWidget);
  });

  testWidgets('Esc calls onClose (hide the window), not a route pop (Issue 1)', (tester) async {
    // The agent supplies onClose=hideWindow: closing a surface returns to the menu bar (there is no
    // shell to pop back to). So Esc must invoke onClose and NOT pop the route.
    final api = _api(_Fake());
    var closed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ReviewScreen(api: api, onClose: () => closed++),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(closed, 1);
    expect(
      find.byType(ReviewScreen),
      findsOneWidget,
    ); // onClose handled dismissal; the route stayed
  });

  testWidgets('rating offline shows the "saved, will sync" badge + offline pill (state 6)', (
    tester,
  ) async {
    // Two cards so we land on card 2 (still mid-session) after the queued rating; /review fails (503).
    final api = _api(_Fake(cards: 2, reviewStatus: 503));
    await tester.pumpWidget(MaterialApp(home: ReviewScreen(api: api)));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.space); // flip card 1
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3); // rate Good → submit fails → queues
    await tester.pumpAndSettle();

    expect(find.textContaining('Offline · 1 queued'), findsOneWidget); // persistent header pill
    expect(find.textContaining('saved, will sync'), findsOneWidget); // per-rating badge
    expect(find.textContaining('Rated'), findsOneWidget);
  });

  testWidgets('keyboard 3 also rates from the back', (tester) async {
    final api = _api(_Fake());
    await tester.pumpWidget(MaterialApp(home: ReviewScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space); // flip
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3); // Good
    await tester.pumpAndSettle();
    expect(find.text('That’s the set.'), findsOneWidget);
  });

  testWidgets('nothing due but the Word Book is non-trivial → all caught up', (tester) async {
    final api = _api(_Fake(dueEmpty: true, wordsStatus: 500));
    await tester.pumpWidget(MaterialApp(home: ReviewScreen(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('All caught up'), findsOneWidget);
  });

  testWidgets('rate buttons are non-focusable so Tab cannot divert Space/⏎ from the flip', (
    tester,
  ) async {
    final api = _api(_Fake());
    await tester.pumpWidget(MaterialApp(home: ReviewScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space); // flip to the back (ratings visible)
    await tester.pumpAndSettle();
    // The four rating buttons are the InkWells with an onTap; all must be keyboard-unfocusable, so the
    // screen's top-level Focus stays the sole keyboard authority (1/2/3/4 rate, Space/⏎ flip).
    final rateInk = tester
        .widgetList<InkWell>(find.byType(InkWell))
        .where((w) => w.onTap != null)
        .toList();
    expect(rateInk.length, 4);
    expect(rateInk.every((w) => w.canRequestFocus == false), isTrue);
  });

  testWidgets('after a keyboard rating, the next card still flips with Space (focus stays put)', (
    tester,
  ) async {
    final api = _api(_Fake(cards: 2));
    await tester.pumpWidget(MaterialApp(home: ReviewScreen(api: api)));
    await tester.pumpAndSettle();
    // Card 1: flip + rate Good via keyboard → advance to card 2 (front).
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.pumpAndSettle();
    expect(find.text('Good'), findsNothing); // on card 2's front
    expect(find.text('That’s the set.'), findsNothing); // 2-card session, not done
    // Space must flip card 2 — proving keyboard focus stayed on the top node across the advance.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.text('Good'), findsOneWidget); // card 2 back, reached purely by keyboard
  });

  testWidgets('front card shows one flip hint, not the duplicate footer legend', (tester) async {
    final api = _api(_Fake());
    await tester.pumpWidget(MaterialApp(home: ReviewScreen(api: api)));
    await tester.pumpAndSettle();

    expect(find.text('Space'), findsOneWidget);
    expect(find.text(' to flip'), findsOneWidget);
    // ⏎ still flips (see `_onKey`) but is dropped from the hint — only Space is taught.
    expect(find.text('⏎'), findsNothing);
    expect(find.text('flip'), findsNothing);
    expect(find.text('close'), findsNothing);
  });

  testWidgets('the back is the summary — the word\'s only explanation text', (tester) async {
    final api = _api(_Fake());
    await tester.pumpWidget(MaterialApp(home: ReviewScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space); // flip to the back
    await tester.pumpAndSettle();
    // The card back is the one summary — there is no per-sense gloss to join or trim.
    expect(find.textContaining('good fortune'), findsOneWidget);
  });

  testWidgets('the back shows a single-reading word\'s IPA beneath the head; the front does not', (
    tester,
  ) async {
    final api = _api(_Fake(withPronunciation: true));
    await tester.pumpWidget(MaterialApp(home: ReviewScreen(api: api)));
    await tester.pumpAndSettle();
    // Front: just the word + the question — no reading (it would give the pronunciation away).
    expect(find.textContaining('sɛrənˈdɪpɪti'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.space); // flip to the back
    await tester.pumpAndSettle();
    // Back: the summary AND the reading on its own line beneath the head.
    expect(find.textContaining('good fortune'), findsOneWidget);
    expect(find.textContaining('sɛrənˈdɪpɪti'), findsOneWidget);
  });

  testWidgets("a heteronym back lists both readings' senses, POS inline per line, no IPA", (
    tester,
  ) async {
    final api = _api(_Fake(heteronym: true));
    await tester.pumpWidget(MaterialApp(home: ReviewScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space); // flip to the back
    await tester.pumpAndSettle();
    // Both readings' senses render (Phase 1: the senses ARE the answer).
    expect(find.textContaining('a thing you can see or touch'), findsOneWidget);
    expect(find.textContaining('to disagree'), findsOneWidget);
    // POS sits inline on each line now (founder request — matching the overlay), not a head chip.
    expect(find.text('noun'), findsOneWidget);
    expect(find.text('verb'), findsOneWidget);
    // The IPA still stays out of the recall body (it lives in the card head).
    expect(find.textContaining('ˈɑbdʒɛkt'), findsNothing);
    expect(find.textContaining('əbˈdʒɛkt'), findsNothing);
  });

  testWidgets('the back card does not overflow at the minimum window size (640×440)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 440); // MainFlutterWindow contentMinSize
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _api(_Fake());
    await tester.pumpWidget(MaterialApp(home: ReviewScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space); // flip to the back (the taller face)
    await tester.pumpAndSettle();
    // A RenderFlex overflow would surface here as a caught exception.
    expect(tester.takeException(), isNull);
  });

  testWidgets('signed out → the gate explains cloud sync + embeds the inline sign-in panel', (
    tester,
  ) async {
    final auth = _signedOutAuth();
    // A token-less client → the controller shows the signed-out gate (it never fetches /review/due).
    final api = CapechoApi(baseUrl: 'https://api.test', transport: _Fake());
    await tester.pumpWidget(
      MaterialApp(
        home: ReviewScreen(api: api, auth: auth),
      ),
    );
    await tester.pumpAndSettle();

    // The warm explainer (scheduling lives in the cloud)…
    expect(find.textContaining('syncs across your devices'), findsOneWidget);
    // …and the shared sign-in panel embedded right here (Google is always offered).
    expect(find.text('Continue with Google'), findsOneWidget);
    // The card flow never started.
    expect(find.text('Good'), findsNothing);
  });
}
