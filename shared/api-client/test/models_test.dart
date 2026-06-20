import 'package:capecho_api/capecho_api.dart';
import 'package:test/test.dart';

// These pin the exact backend wire contract (field names + casing). If the server changes a key,
// one of these fails — which is the point: sync correctness depends on this mapping.

void main() {
  group('auth', () {
    test('AuthSession + Account parse the /auth/session shape (snake_case user)', () {
      final s = AuthSession.fromJson({
        'token': 'tok_abc',
        'expires_at': 1717000000000,
        'user': {
          'id': 'acc-1',
          'iana_timezone': 'America/New_York',
          'explanation_language': 'en',
          'explanation_follows_learning': false,
          'learning_language': 'es',
          'reminder_enabled': false,
          'pro': false,
        },
      });
      expect(s.token, 'tok_abc');
      expect(s.expiresAt, 1717000000000);
      expect(s.account.id, 'acc-1');
      expect(s.account.ianaTimezone, 'America/New_York');
      expect(s.account.explanationLanguage, 'en');
      expect(s.account.learningLanguage, 'es');
    });

    test('learning_language may be null', () {
      final a = Account.fromJson({
        'id': 'a',
        'iana_timezone': 'UTC',
        'explanation_language': 'en',
        'explanation_follows_learning': false,
        'learning_language': null,
        'reminder_enabled': false,
        'pro': false,
      });
      expect(a.learningLanguage, isNull);
    });

    test('AuthProvider wire strings', () {
      expect(AuthProvider.apple.wire, 'apple');
      expect(AuthProvider.google.wire, 'google');
    });

    test('Account parses Pro entitlement (pro + pro_until)', () {
      final pro = Account.fromJson({
        'id': 'a',
        'iana_timezone': 'UTC',
        'explanation_language': 'en',
        'explanation_follows_learning': false,
        'learning_language': null,
        'reminder_enabled': false,
        'pro': true,
        'pro_until': 1893456000000,
      });
      expect(pro.pro, isTrue);
      expect(pro.proUntil, 1893456000000);
    });

    test('Account parses the identity fields (provider + email); a null email stays null', () {
      final a = Account.fromJson({
        'id': 'a',
        'iana_timezone': 'UTC',
        'explanation_language': 'en',
        'explanation_follows_learning': false,
        'learning_language': null,
        'reminder_enabled': false,
        'pro': false,
        'provider': 'google',
        'email': 'mei@example.com',
      });
      expect(a.provider, 'google');
      expect(a.email, 'mei@example.com');

      // The provider may share no email (e.g. Apple private relay) → a null value, not a crash.
      final relay = Account.fromJson({
        'id': 'a',
        'iana_timezone': 'UTC',
        'explanation_language': 'en',
        'explanation_follows_learning': false,
        'learning_language': null,
        'reminder_enabled': false,
        'pro': false,
        'provider': 'apple',
        'email': null,
      });
      expect(relay.provider, 'apple');
      expect(relay.email, isNull);
    });
  });

  group('words', () {
    test('Word parses the snake_case D1 row; is_phrase 0/1 → bool; nullable fields', () {
      final w = Word.fromJson({
        'id': 'w1',
        'user_id': 'u1',
        'target_language': 'en',
        'surface_unit': 'Serendipity',
        'normalized_unit': 'serendipity',
        'target_normalization_version': 'v1',
        'is_phrase': 0,
        'explanation_state': 'ready',
        'explanation_cache_key': 'k1',
        'fsrs_epoch': 1,
        'created_at': 1000,
        'updated_at': 2000,
        'deleted_at': null,
      });
      expect(w.id, 'w1');
      expect(w.userId, 'u1');
      expect(w.surfaceUnit, 'Serendipity');
      expect(w.normalizedUnit, 'serendipity');
      expect(w.isPhrase, isFalse);
      expect(w.explanationState, ExplanationState.ready);
      expect(w.explanationCacheKey, 'k1');
      expect(w.fsrsEpoch, 1);
      expect(w.deletedAt, isNull);
      expect(w.fsrs, isNull); // no `fsrs` key on this row → null (a never-reviewed card)
    });

    test('Word.fsrs parses the per-unit projection (snake_case due_at/last_review_at)', () {
      final w = Word.fromJson({
        'id': 'w1',
        'user_id': 'u1',
        'target_language': 'en',
        'surface_unit': 's',
        'normalized_unit': 's',
        'target_normalization_version': 'v1',
        'is_phrase': 0,
        'explanation_state': 'ready',
        'explanation_cache_key': 'k',
        'fsrs_epoch': 0,
        'created_at': 1,
        'updated_at': 2,
        'deleted_at': null,
        'fsrs': {
          'stability': 12.5,
          'difficulty': 5.0,
          'due_at': 9999,
          'state': 'review',
          'reps': 3,
          'lapses': 1,
          'last_review_at': 8000,
        },
      });
      expect(w.fsrs, isNotNull);
      expect(w.fsrs!.stability, 12.5);
      expect(w.fsrs!.difficulty, 5.0);
      expect(w.fsrs!.dueAt, 9999);
      expect(w.fsrs!.state, CardState.review);
      expect(w.fsrs!.reps, 3);
      expect(w.fsrs!.lapses, 1);
      expect(w.fsrs!.lastReviewAt, 8000);
    });

    test('is_phrase truthy + a soft-deleted row', () {
      final w = Word.fromJson({
        'id': 'w2',
        'user_id': 'u1',
        'target_language': 'es',
        'surface_unit': 'a phrase',
        'normalized_unit': 'a phrase',
        'target_normalization_version': 'v1',
        'is_phrase': 1,
        'explanation_state': 'language_unsupported',
        'explanation_cache_key': null,
        'fsrs_epoch': 0,
        'created_at': 1,
        'updated_at': 1,
        'deleted_at': 99,
      });
      expect(w.isPhrase, isTrue);
      expect(w.explanationState, ExplanationState.languageUnsupported);
      expect(w.deletedAt, 99);
    });
  });

  group('review', () {
    test('DueReviews parses due + new (camelCase) + counts; .all is due-then-new', () {
      final r = DueReviews.fromJson({
        'due': [
          {
            'wordId': 'w1',
            'surfaceUnit': 'x',
            'targetLanguage': 'en',
            'state': 'review',
            'dueAt': 1000,
            'isNew': false
          },
        ],
        'new': [
          {
            'wordId': 'w2',
            'surfaceUnit': 'y',
            'targetLanguage': 'es',
            'state': 'new',
            'dueAt': 2000,
            'isNew': true
          },
        ],
        'counts': {'due': 1, 'new': 1},
      });
      expect(r.dueCount, 1);
      expect(r.newCount, 1);
      expect(r.all.map((c) => c.wordId), ['w1', 'w2']); // due first, then new
      expect(r.due.first.state, CardState.review);
      expect(r.newCards.first.state, CardState.isNew);
      expect(r.newCards.first.isNew, isTrue);
    });

    test('counts fall back to list lengths when absent', () {
      final r = DueReviews.fromJson({'due': [], 'new': []});
      expect(r.dueCount, 0);
      expect(r.newCount, 0);
      expect(r.all, isEmpty);
    });

    test('Rating maps to the 1–4 wire values', () {
      expect(Rating.again.value, 1);
      expect(Rating.hard.value, 2);
      expect(Rating.good.value, 3);
      expect(Rating.easy.value, 4);
      expect(Rating.fromValue(4), Rating.easy);
    });

    test('SyncEvent serializes to the snake_case review/sync wire body (source defaults to app)',
        () {
      const e = SyncEvent(wordId: 'w1', eventId: 'ev1', rating: Rating.good, clientReviewTs: 12345);
      expect(e.toJson(), {
        'word_id': 'w1',
        'event_id': 'ev1',
        'rating': 3,
        'client_review_ts': 12345,
        'source': 'app',
      });
    });

    test('SyncEvent carries a non-default source and round-trips through fromJson', () {
      const e = SyncEvent(
          wordId: 'w1', eventId: 'ev1', rating: Rating.again, clientReviewTs: 7, source: 'widget');
      expect(e.toJson()['source'], 'widget');
      final back = SyncEvent.fromJson(e.toJson());
      expect(back.wordId, 'w1');
      expect(back.eventId, 'ev1');
      expect(back.rating, Rating.again);
      expect(back.clientReviewTs, 7);
      expect(back.source, 'widget');
    });

    test('SyncEvent.fromJson defaults an absent source to app', () {
      final back =
          SyncEvent.fromJson({'word_id': 'w', 'event_id': 'e', 'rating': 3, 'client_review_ts': 1});
      expect(back.source, 'app');
    });

    test('ReviewOutcome + ProjectedCard parse the POST /review 200 shape (camelCase card)', () {
      final o = ReviewOutcome.fromJson({
        'status': 'applied',
        'replay': true,
        'card': {
          'stability': 12.5,
          'difficulty': 5.0,
          'dueAt': 5000,
          'lastReviewAt': 1000,
          'reps': 3,
          'lapses': 1,
          'state': 'review',
        },
      });
      expect(o.replay, isTrue);
      expect(o.card!.stability, 12.5);
      expect(o.card!.difficulty, 5.0);
      expect(o.card!.dueAt, 5000);
      expect(o.card!.reps, 3);
      expect(o.card!.lapses, 1);
      expect(o.card!.state, CardState.review);
    });

    test('SyncEventResult maps per-event statuses', () {
      expect(
        SyncEventResult.fromJson({'eventId': 'e1', 'status': 'applied', 'card': null}).status,
        ReviewStatus.applied,
      );
      expect(
        SyncEventResult.fromJson({'eventId': 'e2', 'status': 'unit_deleted'}).status,
        ReviewStatus.unitDeleted,
      );
      expect(
        SyncEventResult.fromJson({'eventId': 'e3', 'status': 'id_conflict'}).status,
        ReviewStatus.idConflict,
      );
    });
  });

  group('explain + contexts', () {
    test('ExplainResult + WordExplanation parse camelCase (per-POS senses; primarySense derived)',
        () {
      final r = ExplainResult.fromJson({
        'status': 'generated',
        'explanation': {
          'readings': [
            {
              'pronunciationPrimary': 'ˌsɛrənˈdɪpɪti',
              'pronunciationSecondary': '',
              'pos': [
                {
                  'partOfSpeech': 'noun',
                  'senses': ['a happy chance discovery', 'the knack for finding them'],
                },
              ],
            },
          ],
        },
      });
      expect(r.status, ExplainStatus.generated);
      expect(r.hasExplanation, isTrue);
      final e = r.explanation!;
      expect(e.primarySense, 'a happy chance discovery'); // first sense of the first POS
      final reading = e.readings.single;
      expect(reading.pronunciationPrimary, 'ˌsɛrənˈdɪpɪti');
      expect(reading.pronunciationSecondary, ''); // omit-on-failed slot stays renderable-empty
      expect(reading.isIdiom, isFalse);
      expect(reading.pos.single.partOfSpeech, 'noun');
      expect(reading.pos.single.senses, ['a happy chance discovery', 'the knack for finding them']);
    });

    test('WordExplanation parses readings grouped by pronunciation (the `abuse` heteronym)', () {
      final r = ExplainResult.fromJson({
        'status': 'hit',
        'explanation': {
          'readings': [
            {
              'pronunciationPrimary': 'əˈbjus',
              'pronunciationSecondary': 'əˈbjuːs',
              'pos': [
                {
                  'partOfSpeech': 'noun',
                  'senses': ['cruel or harmful treatment'],
                },
              ],
            },
            {
              'pronunciationPrimary': 'əˈbjuz',
              'pronunciationSecondary': 'əˈbjuːz',
              'pos': [
                {
                  'partOfSpeech': 'verb',
                  'senses': ['to treat cruelly or wrongly'],
                },
              ],
            },
          ],
        },
      });
      final e = r.explanation!;
      expect(e.readings, hasLength(2));
      // reading 0: the noun pronunciation, both slots.
      expect(e.readings[0].pronunciationPrimary, 'əˈbjus');
      expect(e.readings[0].pronunciationSecondary, 'əˈbjuːs');
      expect(e.readings[0].pos.single.partOfSpeech, 'noun');
      // reading 1: the verb pronunciation.
      expect(e.readings[1].pronunciationPrimary, 'əˈbjuz');
      expect(e.readings[1].pos.single.partOfSpeech, 'verb');
    });

    test('an idiom reading carries kind + senses, no pronunciation', () {
      final e = WordExplanation.fromJson({
        'readings': [
          {
            'pronunciationPrimary': '',
            'pronunciationSecondary': '',
            'kind': 'idiom',
            'pos': [
              {
                'partOfSpeech': 'idiom',
                'senses': ['打破僵局'],
              },
            ],
          },
        ],
      });
      expect(e.readings.single.isIdiom, isTrue);
      expect(e.readings.single.hasPronunciation, isFalse);
      expect(e.primarySense, '打破僵局');
    });

    test('language_unsupported / anon_miss carry no explanation', () {
      expect(ExplainResult.fromJson({'status': 'language_unsupported'}).hasExplanation, isFalse);
      expect(ExplainResult.fromJson({'status': 'anon_miss', 'detail': 'sign in'}).status,
          ExplainStatus.anonMiss);
    });

    test('ContextView parses camelCase + nullable span/gloss', () {
      final c = ContextView.fromJson({
        'id': 'c1',
        'wordId': 'w1',
        'contextLanguage': 'en',
        'contextText': 'an ephemeral moment',
        'spanStart': 3,
        'spanEnd': 12,
        'meaning': null,
        'createdAt': 1000,
      });
      expect(c.wordId, 'w1');
      expect(c.contextText, 'an ephemeral moment');
      expect(c.spanStart, 3);
      expect(c.spanEnd, 12);
      expect(c.meaning, isNull);
      expect(c.hasGloss, isFalse);
    });

    test('ContextView with a generated gloss exposes the combined meaning + hasGloss', () {
      final c = ContextView.fromJson({
        'id': 'c1',
        'wordId': 'w1',
        'contextLanguage': 'en',
        'contextText': 'It was an ephemeral moment.',
        'spanStart': null,
        'spanEnd': null,
        'meaning': '这里 ephemeral 指短暂、转瞬即逝；这句话是说那是一个转瞬即逝的瞬间。',
        'createdAt': 1000,
      });
      expect(c.meaning, '这里 ephemeral 指短暂、转瞬即逝；这句话是说那是一个转瞬即逝的瞬间。');
      expect(c.hasGloss, isTrue);
    });

    test('ContextView parses capture source (app/title); hasSource + copyWith preserve them', () {
      final c = ContextView.fromJson({
        'id': 'c1',
        'wordId': 'w1',
        'contextLanguage': 'en',
        'contextText': 'down the slide',
        'spanStart': null,
        'spanEnd': null,
        'meaning': null,
        'sourceApp': 'Google Chrome',
        'sourceTitle': 'Slides — Wikipedia',
        'createdAt': 1000,
      });
      expect(c.sourceApp, 'Google Chrome');
      expect(c.sourceTitle, 'Slides — Wikipedia');
      expect(c.hasSource, isTrue);
      // An edit clears the gloss but keeps the source provenance.
      final edited = c.copyWith(contextText: 'a new sentence', clearGloss: true);
      expect(edited.sourceApp, 'Google Chrome');
      expect(edited.sourceTitle, 'Slides — Wikipedia');
    });

    test('ContextView with no source reads back null + hasSource false', () {
      final c = ContextView.fromJson({
        'id': 'c1',
        'wordId': 'w1',
        'contextLanguage': null,
        'contextText': 'x',
        'spanStart': null,
        'spanEnd': null,
        'meaning': null,
        'createdAt': 1000,
      });
      expect(c.sourceApp, isNull);
      expect(c.sourceTitle, isNull);
      expect(c.hasSource, isFalse);
    });
  });

  group('readings (pronunciation + POS metadata)', () {
    test('Reading parses both slots + per-POS senses; missing fields default empty (omit-on-fail)',
        () {
      final full = Reading.fromJson({
        'pronunciationPrimary': 'ˈɑbdʒɛkt',
        'pronunciationSecondary': 'ˈɒbdʒɪkt',
        'pos': [
          {
            'partOfSpeech': 'noun',
            'senses': ['a thing you can see or touch'],
            'hasMore': true, // a legacy key from an old cached blob — silently ignored now
          },
        ],
      });
      expect(full.pronunciationPrimary, 'ˈɑbdʒɛkt');
      expect(full.pronunciationSecondary, 'ˈɒbdʒɪkt');
      expect(full.hasPronunciation, isTrue);
      expect(full.pos.single.partOfSpeech, 'noun');
      expect(full.pos.single.senses, ['a thing you can see or touch']); // legacy hasMore ignored

      final bare = Reading.fromJson(<String, dynamic>{});
      expect(bare.pronunciationPrimary, '');
      expect(bare.pronunciationSecondary, '');
      expect(bare.hasPronunciation, isFalse);
      expect(bare.pos, isEmpty);
    });

    test('an explanation with no readings has an empty primarySense', () {
      final e = WordExplanation.fromJson(<String, dynamic>{});
      expect(e.primarySense, isEmpty);
      expect(e.readings, isEmpty);
    });
  });

  group('claim', () {
    test('ClaimRow + ClaimContext serialize to snake_case (omitting absent optionals)', () {
      const row = ClaimRow(
        clientRowId: 'r1',
        surfaceUnit: 'word',
        targetLanguage: 'en',
        context:
            const ClaimContext(text: 'a sentence', contextLanguage: 'en', spanStart: 2, spanEnd: 6),
      );
      expect(row.toJson(), {
        'client_row_id': 'r1',
        'surface_unit': 'word',
        'target_language': 'en',
        'context': {'text': 'a sentence', 'context_language': 'en', 'span_start': 2, 'span_end': 6},
      });
      // bare row (no context) omits the context key
      expect(
        const ClaimRow(clientRowId: 'r2', surfaceUnit: 'x', targetLanguage: 'en')
            .toJson()
            .containsKey('context'),
        isFalse,
      );
    });

    test('ClaimContext carries preview_handle when present (E2 adopt-on-save), omits it when null',
        () {
      expect(
        const ClaimContext(text: 'a sentence', previewHandle: 'pv1').toJson(),
        {'text': 'a sentence', 'preview_handle': 'pv1'},
      );
      expect(
        const ClaimContext(text: 'a sentence').toJson().containsKey('preview_handle'),
        isFalse,
      );
    });

    test('ClaimContext serializes capture-source metadata to snake_case, omitting absent ones', () {
      expect(
        const ClaimContext(
          text: 'a sentence',
          sourceApp: 'Google Chrome',
          sourceTitle: 'A page title',
          detectedLanguage: 'en',
          detectedLanguageConfidence: 0.9,
        ).toJson(),
        {
          'text': 'a sentence',
          'source_app': 'Google Chrome',
          'source_title': 'A page title',
          'detected_language': 'en',
          'detected_language_confidence': 0.9,
        },
      );
      // All source fields are independently optional — a context without them omits every key.
      final bare = const ClaimContext(text: 'a sentence').toJson();
      expect(bare.containsKey('source_app'), isFalse);
      expect(bare.containsKey('source_title'), isFalse);
      expect(bare.containsKey('detected_language'), isFalse);
      expect(bare.containsKey('detected_language_confidence'), isFalse);
    });

    test('ClaimResult parses camelCase; .claimed reflects a returned wordId', () {
      final ok = ClaimResult.fromJson(
          {'clientRowId': 'r1', 'status': 'created', 'wordId': 'w1', 'contextStored': true});
      expect(ok.claimed, isTrue);
      expect(ok.wordId, 'w1');
      expect(ok.contextStored, isTrue);
      final rejected = ClaimResult.fromJson({'clientRowId': 'r2', 'status': 'empty_unit'});
      expect(rejected.claimed, isFalse);
    });
  });

  group('lenient enum parsing', () {
    test('unknown enum strings fall back instead of throwing', () {
      expect(CardState.fromWire('???'), CardState.review);
      expect(ExplanationState.fromWire('mystery'), ExplanationState.pending);
      expect(ExplainStatus.fromWire(null), ExplainStatus.anonMiss);
      expect(ReviewStatus.fromWire('weird'), ReviewStatus.error);
    });
  });

  test('AppleVerifyResult.fromJson maps pro/horizon/status + the cross-account flag', () {
    final r = AppleVerifyResult.fromJson({
      'pro': false,
      'pro_until': null,
      'status': 'noop',
      'attributed_to_other_account': true,
    });
    expect(r.pro, isFalse);
    expect(r.status, 'noop');
    expect(r.attributedToOtherAccount, isTrue); // the snake_case wire field maps through
    // An absent flag defaults to false (lenient parse — an older server can't break the client).
    final r2 = AppleVerifyResult.fromJson({'pro': true, 'pro_until': 1, 'status': 'active'});
    expect(r2.attributedToOtherAccount, isFalse);
  });
}
