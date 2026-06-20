import 'dart:convert';

import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_mobile/theme.dart';
import 'package:capecho_mobile/word_book/word_book_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// URL-aware fake transport so the catalog's lazy per-row `/contexts` prefetch + the detail's `/explain`
/// aren't order-fragile — each endpoint returns its configured body. Mirrors widget_test.dart.
class _FakeTransport implements HttpTransport {
  final List<TransportRequest> reqs = [];
  Object wordsBody = {'words': []};
  Object dueBody = {
    'due': [],
    'new': [],
    'counts': {'due': 0, 'new': 0},
  };
  Object contextsBody = {'contexts': []};
  Object explainBody = {'status': 'language_unsupported'};

  @override
  Future<TransportResponse> send(TransportRequest r) async {
    reqs.add(r);
    final path = Uri.parse(r.url).path;
    final Object body;
    if (path.endsWith('/review/due')) {
      body = dueBody;
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

/// A `GET /words` row (snake_case, like the real wire). [fsrs] is the per-unit memory-meter projection.
Map<String, Object?> _word(
  String id,
  String unit, {
  String lang = 'en',
  String? pos,
  Map<String, Object?>? fsrs,
  int createdAt = 1,
}) => {
  'id': id,
  'user_id': 'u1',
  'target_language': lang,
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
  'fsrs': fsrs,
};

Map<String, Object?> _ctx(String id, String wordId, String text, {int? start, int? end}) => {
  'id': id,
  'wordId': wordId,
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

/// An enriched hit: a heteronym — two readings (a noun + a verb), each with both pronunciation slots +
/// its POS carrying a sense, so the Word Book detail renders each reading block (DR3).
Map<String, Object?> _explainHitEnriched() => {
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

// A held session is what routes the controller to `/words` (vs the local/empty path).
CapechoApi _signedInApi(_FakeTransport t) =>
    CapechoApi(baseUrl: 'https://api.test', transport: t)..restoreToken('test-session');

Widget _host(CapechoApi api) => MaterialApp(
  theme: capechoTheme(Brightness.light),
  home: Scaffold(
    body: SafeArea(child: WordBookScreen(api: api)),
  ),
);

void main() {
  testWidgets('catalog renders the units, the count, and the due line', (tester) async {
    final t = _FakeTransport()
      ..wordsBody = {
        'words': [
          _word('w1', 'serendipity', pos: 'noun', createdAt: 2),
          _word('w2', 'ephemeral', pos: 'adj', createdAt: 1),
        ],
      }
      ..dueBody = {
        'due': [],
        'new': [],
        'counts': {'due': 3, 'new': 0},
      }
      ..contextsBody = {
        'contexts': [_ctx('c1', 'w1', 'a moment of serendipity', start: 11, end: 22)],
      };
    await tester.pumpWidget(_host(_signedInApi(t)));
    await tester.pumpAndSettle();

    // Masthead + the server-FSRS "N due today" line.
    expect(find.text('Word Book'), findsOneWidget);
    expect(find.text('3 due today'), findsOneWidget);
    // Both units render, newest-first; the toolbar count is present.
    expect(find.text('serendipity'), findsOneWidget);
    expect(find.text('ephemeral'), findsOneWidget);
    expect(find.text('2 words and phrases'), findsOneWidget);
  });

  testWidgets('tapping a row opens the detail with its meaning + highlighted context', (
    tester,
  ) async {
    final t = _FakeTransport()
      ..wordsBody = {
        'words': [_word('w1', 'serendipity', pos: 'noun')],
      }
      ..contextsBody = {
        'contexts': [_ctx('c1', 'w1', 'a moment of serendipity', start: 11, end: 22)],
      }
      ..explainBody = _explainHit('good fortune', pos: 'noun');
    await tester.pumpWidget(_host(_signedInApi(t)));
    await tester.pumpAndSettle();

    // Tap the catalog row (the unit text) to push the detail.
    await tester.tap(find.text('serendipity'));
    await tester.pumpAndSettle();

    // Detail: the back-to-Word-Book affordance, the meaning, the saved context, and the paid CTA.
    // The meaning + context render as Text.rich (POS span / span highlight), so match by substring.
    expect(find.text('Word Book'), findsWidgets); // the SurfaceHeader back label
    // The word headlines the body only — the top chrome bar no longer mirrors it
    // (header keeps just the back affordance), so it appears exactly once.
    expect(find.text('serendipity'), findsOneWidget);
    expect(find.textContaining('good fortune'), findsOneWidget);
    expect(find.text('Your contexts'.toUpperCase()), findsOneWidget);
    expect(find.textContaining('a moment of serendipity'), findsOneWidget);
    expect(find.text('Explain here'), findsOneWidget);
    expect(find.text('Delete word'), findsOneWidget);
  });

  testWidgets('the detail splits a heteronym into per-reading modules (IPA + POS + gloss)', (
    tester,
  ) async {
    final t = _FakeTransport()
      ..wordsBody = {
        'words': [_word('w1', 'object', pos: 'noun')],
      }
      ..contextsBody = {'contexts': const []}
      ..explainBody = _explainHitEnriched();
    await tester.pumpWidget(_host(_signedInApi(t)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('object'));
    await tester.pumpAndSettle();

    // Each reading is a block — its pronunciation line + per-POS senses. Both readings'
    // senses render, each under its POS label.
    expect(find.textContaining('a thing you can see or touch'), findsOneWidget);
    expect(find.textContaining('to disagree'), findsOneWidget);
    expect(find.text('noun'), findsOneWidget); // the POS label (left column of its row)
    expect(find.text('verb'), findsOneWidget);
    // The pronunciation line stays in the detail (a RichText with a `semanticsLabel`, so screen readers
    // hear "pronunciation" not the glyphs — DR4 — which is why we assert the visible text via
    // includeSemanticsLabels: false rather than a plain text finder).
    bool visibleIpa(String ipa) => find
        .byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText(includeSemanticsLabels: false).contains(ipa),
        )
        .evaluate()
        .isNotEmpty;
    expect(visibleIpa('US /ˈɑbdʒɛkt/'), isTrue); // noun, US reading (equal weight, US listed first)
    expect(visibleIpa('UK /ˈɒbdʒɪkt/'), isTrue); // noun, UK reading
    expect(visibleIpa('US /əbˈdʒɛkt/'), isTrue); // verb, US reading
    // Audio (tap-to-hear) is deferred — the speaker buttons are hidden in this build (no TTS).
    expect(find.byIcon(Icons.volume_up_outlined), findsNothing);
  });

  testWidgets('empty account shows the first-run capture invite', (tester) async {
    await tester.pumpWidget(_host(_signedInApi(_FakeTransport())));
    await tester.pumpAndSettle();
    expect(find.text('Your Word Book is ready for its first word.'), findsOneWidget);
  });
}
