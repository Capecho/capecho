import 'dart:convert';

import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:capecho_mobile/review/review_screen.dart';
import 'package:capecho_mobile/sign_in/sign_in_screen.dart';
import 'package:capecho_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// URL-aware fake transport so prefetch concurrency (context/explain across cards) isn't
/// order-fragile — each endpoint returns its configured body. Mirrors the macOS review tests.
class _FakeTransport implements HttpTransport {
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

  @override
  Future<TransportResponse> send(TransportRequest r) async {
    reqs.add(r);
    final path = Uri.parse(r.url).path;
    final Object body;
    if (path.endsWith('/review/due')) {
      body = dueBody;
    } else if (path.endsWith('/review')) {
      body = reviewBody;
    } else if (path.endsWith('/contexts')) {
      body = contextsBody;
    } else if (path.endsWith('/explain')) {
      body = explainBody;
    } else if (path.endsWith('/words')) {
      body = wordsBody;
    } else {
      body = const <String, Object?>{};
    }
    return TransportResponse(statusCode: 200, body: jsonEncode(body));
  }
}

class _FakeStore implements SessionStore {
  String? token;
  @override
  Future<String?> loadToken() async => token;
  @override
  Future<void> saveToken(String t) async => token = t;
  @override
  Future<void> clear() async => token = null;
}

Map<String, Object?> _dueCard(String id, String unit, {String lang = 'en'}) => {
  'wordId': id,
  'surfaceUnit': unit,
  'targetLanguage': lang,
  'state': 'new',
  'dueAt': 0,
  'isNew': true,
};

Map<String, Object?> _ctx(String text, {int? start, int? end}) => {
  'id': 'c1',
  'wordId': 'w1',
  'contextLanguage': 'en',
  'contextText': text,
  'spanStart': start,
  'spanEnd': end,
  'meaning': null,
  'createdAt': 1,
};

Map<String, Object?> _explainHit(String summary, {String pos = 'noun'}) => {
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

CapechoApi _signedInApi(_FakeTransport t) =>
    CapechoApi(baseUrl: 'https://api.test', transport: t)..restoreToken('test-session');

void main() {
  testWidgets('sign-in screen shows the headline + Google/email providers', (tester) async {
    final auth = AuthController(
      api: CapechoApi(baseUrl: 'https://api.test', transport: _FakeTransport()),
      store: _FakeStore(),
      collectClaimRows: () async => const <ClaimRow>[],
      installId: () async => 'install-1',
    );
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: capechoTheme(Brightness.light),
        home: SignInScreen(auth: auth),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with email'), findsOneWidget);
    expect(find.text('Your Word Book syncs across every device you sign in on.'), findsOneWidget);
  });

  testWidgets('review: empty queue + empty word book shows the cold empty state', (tester) async {
    final api = _signedInApi(_FakeTransport());
    await tester.pumpWidget(
      MaterialApp(
        theme: capechoTheme(Brightness.light),
        home: Scaffold(body: ReviewScreen(api: api)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Your words will appear here'), findsOneWidget);
  });

  testWidgets('review: tap flips the card, then a rating advances to done', (tester) async {
    final t = _FakeTransport()
      ..dueBody = {
        'due': [_dueCard('w1', 'serendipity')],
        'new': [],
        'counts': {'due': 1, 'new': 0},
      }
      ..contextsBody = {
        'contexts': [_ctx('a moment of serendipity', start: 11, end: 22)],
      }
      ..explainBody = _explainHit('good fortune', pos: 'noun');
    await tester.pumpWidget(
      MaterialApp(
        theme: capechoTheme(Brightness.light),
        home: Scaffold(body: ReviewScreen(api: _signedInApi(t))),
      ),
    );
    await tester.pumpAndSettle();

    // Front: task framing + tap-to-flip affordance.
    expect(find.text('DO YOU KNOW THIS WORD HERE?'), findsOneWidget);
    expect(find.text('Tap to reveal meaning'), findsOneWidget);

    // Tap flips to the back: unit + meaning + the four ratings.
    await tester.tap(find.text('Tap to reveal meaning'));
    await tester.pumpAndSettle();
    expect(find.text('serendipity'), findsOneWidget);
    expect(find.text('good fortune'), findsOneWidget);
    expect(find.text('Forget'), findsOneWidget);
    expect(find.text('Good'), findsOneWidget);

    // Rating the only card advances to the session-end rest state.
    await tester.tap(find.text('Good'));
    await tester.pumpAndSettle();
    expect(find.text('That’s the set.'), findsOneWidget);
    expect(find.text('1 reviewed today'), findsOneWidget);
  });

  testWidgets('review: a long headword stays on one line; POS shows inline below the head', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const longWord = 'pneumonoultramicroscopicsilicovolcanoconiosis';
    final t = _FakeTransport()
      ..dueBody = {
        'due': [_dueCard('w1', longWord)],
        'new': [],
        'counts': {'due': 1, 'new': 0},
      }
      ..contextsBody = {
        'contexts': [_ctx('a moment of $longWord', start: 12, end: 12 + longWord.length)],
      }
      ..explainBody = _explainHit('good fortune', pos: 'noun');
    await tester.pumpWidget(
      MaterialApp(
        theme: capechoTheme(Brightness.light),
        home: Scaffold(body: ReviewScreen(api: _signedInApi(t))),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Tap to reveal meaning'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final wordFinder = find.text(longWord);
    expect(wordFinder, findsOneWidget);
    final wordText = tester.widget<Text>(wordFinder);
    expect(wordText.maxLines, 1);
    expect(wordText.softWrap, isFalse);
    final fitted = tester.widget<FittedBox>(
      find.ancestor(of: wordFinder, matching: find.byType(FittedBox)),
    );
    expect(fitted.fit, BoxFit.scaleDown);

    // POS now sits inline on the sense line (founder request — matching the overlay), below the head;
    // the target-language label stays in the head.
    expect(find.text('noun'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('noun')).dy,
      greaterThan(tester.getTopLeft(find.text(longWord)).dy),
    );
  });
}
