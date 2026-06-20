import 'dart:convert';

import 'package:capecho_api/capecho_api.dart';
import 'package:test/test.dart';

/// A scriptable fake transport: records every request and returns the next queued response (or a
/// default 200 `{}`). Lets us assert the exact request the client built and feed canned responses.
class FakeTransport implements HttpTransport {
  final List<TransportRequest> requests = [];
  final List<TransportResponse> _queue = [];

  void enqueue(int status, Object body) => _queue
      .add(TransportResponse(statusCode: status, body: body is String ? body : jsonEncode(body)));

  TransportRequest get last => requests.last;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    requests.add(request);
    return _queue.isNotEmpty
        ? _queue.removeAt(0)
        : const TransportResponse(statusCode: 200, body: '{}');
  }
}

/// A transport that simulates a hard network failure (the seam contract says these propagate).
class ThrowingTransport implements HttpTransport {
  @override
  Future<TransportResponse> send(TransportRequest request) async =>
      throw StateError('network down');
}

void main() {
  late FakeTransport t;
  late CapechoApi api;

  setUp(() {
    t = FakeTransport();
    api = CapechoApi(baseUrl: 'https://api.capecho.test/', transport: t);
  });

  Map<String, dynamic> bodyOf(TransportRequest r) => jsonDecode(r.body!) as Map<String, dynamic>;

  group('base URL + headers', () {
    test('trailing slash is trimmed; a GET carries no content-type body header', () async {
      api.restoreToken('t');
      t.enqueue(200, {'words': []});
      await api.listWords();
      expect(t.last.url, 'https://api.capecho.test/words');
      expect(t.last.headers.containsKey('content-type'), isFalse);
      expect(t.last.method, 'GET');
    });
  });

  group('auth', () {
    test('signIn posts to /auth/session WITHOUT an auth header, stores the token', () async {
      expect(api.hasSession, isFalse);
      t.enqueue(200, {
        'token': 'tok1',
        'expires_at': 999,
        'user': {
          'id': 'a',
          'iana_timezone': 'UTC',
          'explanation_language': 'en',
          'explanation_follows_learning': false,
          'learning_language': null,
          'reminder_enabled': false,
          'pro': false,
        },
      });
      final s = await api.signInWithApple('id-token-123', timezone: 'UTC', learningLanguage: 'en');
      expect(s.token, 'tok1');
      expect(api.token, 'tok1');
      expect(api.hasSession, isTrue);
      expect(t.last.url, 'https://api.capecho.test/auth/session');
      expect(t.last.headers.containsKey('authorization'),
          isFalse); // sign-in itself is unauthenticated
      expect(bodyOf(t.last), {
        'provider': 'apple',
        'credential': 'id-token-123',
        'timezone': 'UTC',
        'learning_language': 'en',
      });
    });

    test('subsequent authed calls carry Authorization: Bearer <token>', () async {
      t.enqueue(200, {
        'token': 'tok2',
        'expires_at': 1,
        'user': {
          'id': 'a',
          'iana_timezone': 'UTC',
          'explanation_language': 'en',
          'explanation_follows_learning': false,
          'learning_language': null,
          'reminder_enabled': false,
          'pro': false,
        },
      });
      await api.signInWithGoogle('g-token');
      t.enqueue(200, {'words': []});
      await api.listWords();
      expect(t.last.headers['authorization'], 'Bearer tok2');
    });

    test('startEmailSignIn posts {email} unauthenticated', () async {
      t.enqueue(200, {'status': 'sent'});
      await api.startEmailSignIn('user@example.com');
      expect(t.last.url, 'https://api.capecho.test/auth/email/start');
      expect(bodyOf(t.last), {'email': 'user@example.com'});
      expect(t.last.headers.containsKey('authorization'), isFalse);
    });

    test('verifyEmailCode posts code + stores the session token', () async {
      t.enqueue(200, {
        'token': 'tokE',
        'expires_at': 5,
        'user': {
          'id': 'e',
          'iana_timezone': 'UTC',
          'explanation_language': 'en',
          'explanation_follows_learning': false,
          'learning_language': null,
          'reminder_enabled': false,
          'pro': false,
        },
      });
      final s = await api.verifyEmailCode('user@example.com', '424242', timezone: 'UTC');
      expect(s.token, 'tokE');
      expect(api.token, 'tokE');
      expect(t.last.url, 'https://api.capecho.test/auth/email/verify');
      expect(bodyOf(t.last), {'email': 'user@example.com', 'code': '424242', 'timezone': 'UTC'});
    });

    test('signOut clears the token even though the call succeeds', () async {
      api.restoreToken('tokX');
      t.enqueue(200, {'status': 'signed_out'});
      await api.signOut();
      expect(api.hasSession, isFalse);
      expect(t.last.url, 'https://api.capecho.test/auth/signout');
    });

    test('signOut drops the local token even when the server call FAILS (finally)', () async {
      api.restoreToken('tokX');
      t.enqueue(500, {'error': 'internal_error'});
      final err = await api.signOut().then<Object?>((_) => null, onError: (e) => e);
      expect(err, isA<ApiException>()); // the failure still surfaces to the caller
      expect(api.hasSession, isFalse); // ...but the local token is gone regardless
    });

    test('deleteAccount DELETEs /account + drops the local token (the session is now inert)',
        () async {
      api.restoreToken('tokX');
      t.enqueue(200, {'status': 'deletion_scheduled'});
      await api.deleteAccount();
      expect(t.last.method, 'DELETE');
      expect(t.last.url, 'https://api.capecho.test/account');
      expect(api.hasSession, isFalse);
    });

    test('deleteAccount KEEPS the token on failure (the delete did not happen — retryable)',
        () async {
      api.restoreToken('tokX');
      t.enqueue(503, {'error': 'internal_error'});
      final err = await api.deleteAccount().then<Object?>((_) => null, onError: (e) => e);
      expect(err, isA<ApiException>()); // the failure surfaces
      expect(api.hasSession, isTrue); // ...and the session is preserved so the user can retry
    });

    test('me() GETs /auth/me and unwraps user', () async {
      api.restoreToken('tokX');
      t.enqueue(200, {
        'user': {
          'id': 'me',
          'iana_timezone': 'UTC',
          'explanation_language': 'en',
          'explanation_follows_learning': false,
          'learning_language': 'fr',
          'reminder_enabled': false,
          'pro': false,
        },
      });
      final acc = await api.me();
      expect(acc.id, 'me');
      expect(acc.learningLanguage, 'fr');
      expect(acc.reminderEnabled, isFalse);
      expect(t.last.headers['authorization'], 'Bearer tokX');
    });

    test('updateAccount PATCHes /account with only the provided fields + parses reminders',
        () async {
      api.restoreToken('t');
      t.enqueue(200, {
        'user': {
          'id': 'u1',
          'iana_timezone': 'UTC',
          'explanation_language': 'zh-Hans',
          'explanation_follows_learning': false,
          'learning_language': 'en',
          'reminder_enabled': true,
          'reminder_time': '20:30',
          'pro': false,
        },
      });
      final acc = await api.updateAccount(
          explanationLanguage: 'zh-Hans', reminderEnabled: true, reminderTime: '20:30');
      expect(acc.explanationLanguage, 'zh-Hans');
      expect(acc.reminderEnabled, isTrue);
      expect(acc.reminderTime, '20:30');
      expect(t.last.method, 'PATCH');
      expect(Uri.parse(t.last.url).path, '/account');
      // learning_language was NOT passed → it must be absent from the body (server leaves it unchanged).
      expect(bodyOf(t.last), {
        'explanation_language': 'zh-Hans',
        'reminder_enabled': true,
        'reminder_time': '20:30',
      });
    });
  });

  group('words + claim', () {
    test('listWords parses the words array', () async {
      api.restoreToken('t');
      t.enqueue(200, {
        'words': [
          {
            'id': 'w1',
            'user_id': 'u',
            'target_language': 'en',
            'surface_unit': 'hi',
            'normalized_unit': 'hi',
            'target_normalization_version': 'v1',
            'is_phrase': 0,
            'explanation_state': 'pending',
            'explanation_cache_key': null,
            'fsrs_epoch': 0,
            'created_at': 1,
            'updated_at': 1,
            'deleted_at': null,
          },
        ],
      });
      final words = await api.listWords();
      expect(words, hasLength(1));
      expect(words.first.surfaceUnit, 'hi');
      expect(words.first.fsrs, isNull); // no `fsrs` key → null (never-reviewed)
    });

    test('listWords surfaces the per-unit fsrs projection when present', () async {
      api.restoreToken('t');
      t.enqueue(200, {
        'words': [
          {
            'id': 'w1',
            'user_id': 'u',
            'target_language': 'en',
            'surface_unit': 'hi',
            'normalized_unit': 'hi',
            'target_normalization_version': 'v1',
            'is_phrase': 0,
            'explanation_state': 'ready',
            'explanation_cache_key': 'k',
            'fsrs_epoch': 0,
            'created_at': 1,
            'updated_at': 1,
            'deleted_at': null,
            'fsrs': {
              'stability': 9.0,
              'difficulty': 4.0,
              'due_at': 5,
              'state': 'review',
              'reps': 2,
              'lapses': 0,
              'last_review_at': 3
            },
          },
        ],
      });
      final words = await api.listWords();
      expect(words.first.fsrs, isNotNull);
      expect(words.first.fsrs!.dueAt, 5);
      expect(words.first.fsrs!.state, CardState.review);
    });

    test('deleteWord DELETEs /words/{id}; restoreWord POSTs /words/{id}/restore', () async {
      api.restoreToken('t');
      t.enqueue(200, {'status': 'deleted', 'id': 'w1'});
      await api.deleteWord('w1');
      expect(t.last.method, 'DELETE');
      expect(t.last.url, 'https://api.capecho.test/words/w1');

      t.enqueue(200, {'status': 'restored', 'id': 'w1'});
      await api.restoreWord('w1');
      expect(t.last.method, 'POST');
      expect(t.last.url, 'https://api.capecho.test/words/w1/restore');
    });

    test('claim posts install_id + snake_case rows', () async {
      api.restoreToken('t');
      t.enqueue(200, {
        'results': [
          {'clientRowId': 'r1', 'status': 'created', 'wordId': 'w1'},
        ],
      });
      final results = await api.claim(installId: 'inst-1', rows: [
        const ClaimRow(clientRowId: 'r1', surfaceUnit: 'word', targetLanguage: 'en'),
      ]);
      expect(results.single.claimed, isTrue);
      final body = bodyOf(t.last);
      expect(body['install_id'], 'inst-1');
      expect((body['rows'] as List).first,
          {'client_row_id': 'r1', 'surface_unit': 'word', 'target_language': 'en'});
    });
  });

  group('review + sync', () {
    test('dueReviews builds the new_limit query', () async {
      api.restoreToken('t');
      t.enqueue(200, {
        'due': [],
        'new': [],
        'counts': {'due': 0, 'new': 0}
      });
      await api.dueReviews(newLimit: 10);
      expect(t.last.url, 'https://api.capecho.test/review/due?new_limit=10');
      expect(t.last.method, 'GET');
    });

    test('submitReview posts the snake_case event body', () async {
      api.restoreToken('t');
      t.enqueue(200, {'status': 'applied', 'replay': false, 'card': null});
      final outcome = await api.submitReview(
        const SyncEvent(wordId: 'w1', eventId: 'ev1', rating: Rating.easy, clientReviewTs: 7),
      );
      expect(outcome.replay, isFalse);
      expect(t.last.url, 'https://api.capecho.test/review');
      expect(bodyOf(t.last), {
        'word_id': 'w1',
        'event_id': 'ev1',
        'rating': 4,
        'client_review_ts': 7,
        'source': 'app'
      });
    });

    test('sync posts {events:[...]} and parses ordered results', () async {
      api.restoreToken('t');
      t.enqueue(200, {
        'results': [
          {'eventId': 'ev1', 'status': 'applied', 'card': null},
          {'eventId': 'ev2', 'status': 'not_found'},
        ],
      });
      final results = await api.sync([
        const SyncEvent(wordId: 'w1', eventId: 'ev1', rating: Rating.good, clientReviewTs: 1),
        const SyncEvent(wordId: 'w2', eventId: 'ev2', rating: Rating.again, clientReviewTs: 2),
      ]);
      expect(results.map((r) => r.status), [ReviewStatus.applied, ReviewStatus.notFound]);
      expect(bodyOf(t.last)['events'] as List, hasLength(2));
    });
  });

  group('explain + contexts + export', () {
    test('explain builds the query (unit/target/explanation_lang/word_id)', () async {
      t.enqueue(200, {
        'status': 'hit',
        'explanation': {
          'unit': 'x',
          'targetLanguage': 'en',
          'explanationLanguage': 'en',
          'senses': [],
          'promptVersion': 'p',
        }
      });
      final r = await api.explain(unit: 'x', target: 'en', explanationLang: 'es', wordId: 'w1');
      expect(r.status, ExplainStatus.hit);
      final uri = Uri.parse(t.last.url);
      expect(uri.path, '/explain');
      expect(uri.queryParameters,
          {'unit': 'x', 'target': 'en', 'explanation_lang': 'es', 'word_id': 'w1'});
    });

    test('explain maps a 422 not_a_word to ExplainStatus.notAWord (not thrown)', () async {
      // The backend rejects a non-word with 422 {error: not_a_word} (junk/gibberish gate OR the model's
      // own verdict). The caller wants the calm "not a word" state, so this resolves — never throws.
      t.enqueue(422, {'error': 'not_a_word', 'detail': "that doesn't look like a word"});
      final r = await api.explain(unit: 'asdfgh', target: 'en');
      expect(r.status, ExplainStatus.notAWord);
      expect(r.explanation, isNull);
    });

    test('explain still propagates other 4xx/5xx as ApiException', () async {
      t.enqueue(503, {'error': 'budget_exhausted'});
      final err =
          await api.explain(unit: 'x', target: 'en').then<Object?>((_) => null, onError: (e) => e);
      expect(err, isA<ApiException>());
      expect((err as ApiException).error, 'budget_exhausted');
    });

    test('contexts builds word_id query and parses the array', () async {
      api.restoreToken('t');
      t.enqueue(200, {
        'contexts': [
          {
            'id': 'c1',
            'wordId': 'w1',
            'contextLanguage': 'en',
            'contextText': 's',
            'spanStart': null,
            'spanEnd': null,
            'meaning': null,
            'createdAt': 1
          },
        ]
      });
      final ctx = await api.contexts('w1');
      expect(ctx.single.id, 'c1');
      expect(Uri.parse(t.last.url).queryParameters, {'word_id': 'w1'});
    });

    test('exportCsv returns the raw body text', () async {
      api.restoreToken('t');
      t.enqueue(200, 'word,context\nhi,there\n');
      final csv = await api.exportCsv();
      expect(csv, contains('word,context'));
      expect(Uri.parse(t.last.url).queryParameters['format'], 'csv');
    });

    test('exportRows parses the top-level JSON array into ExportRows (format=json)', () async {
      api.restoreToken('t');
      t.enqueue(200, [
        {
          'word': 'serendipity',
          'context': 'a fresh serendipity',
          'contextLanguage': '',
          'definition': '(n) luck',
          'targetLanguage': 'en'
        },
        {
          'word': 'palabra',
          'context': 'the word palabra',
          'contextLanguage': 'en',
          'definition': '',
          'targetLanguage': 'es'
        },
      ]);
      final rows = await api.exportRows();
      expect(Uri.parse(t.last.url).queryParameters['format'], 'json');
      expect(rows, hasLength(2));
      expect(rows[0].word, 'serendipity');
      expect(rows[0].definition, '(n) luck');
      expect(rows[1].targetLanguage, 'es');
      expect(rows[1].contextLanguage, 'en'); // differs from target → carried through
    });

    test('explainContext POSTs word_context_id + parses {meaning, charged}', () async {
      api.restoreToken('t');
      t.enqueue(200, {
        'status': 'ready',
        'meaning': 'Here cell is a sentence-specific meaning; the whole sentence, rendered.',
        'charged': true,
      });
      final out = await api.explainContext('c1', explanationLang: 'es', idempotencyKey: 'k1');
      expect(
          out.meaning, 'Here cell is a sentence-specific meaning; the whole sentence, rendered.');
      expect(out.charged, isTrue);
      expect(t.last.method, 'POST');
      expect(Uri.parse(t.last.url).path, '/explain/context');
      expect(bodyOf(t.last),
          {'word_context_id': 'c1', 'explanation_lang': 'es', 'idempotency_key': 'k1'});
    });

    test('explainContext propagates quota_exhausted (429) as ApiException', () async {
      api.restoreToken('t');
      t.enqueue(429, {'error': 'quota_exhausted', 'detail': 'daily limit reached'});
      final err = await api.explainContext('c1').then<Object?>((_) => null, onError: (e) => e);
      expect(err, isA<ApiException>());
      expect((err as ApiException).error, 'quota_exhausted');
      expect(err.statusCode, 429);
    });

    test(
        'explainContextPreview POSTs raw word+sentence and parses {meaning, previewHandle, charged}',
        () async {
      api.restoreToken('t');
      t.enqueue(200, {
        'status': 'ready',
        'meaning': 'Here cell is the in-context meaning; the cell divides rapidly.',
        'previewHandle': 'ph1',
        'charged': true
      });
      final out = await api.explainContextPreview(
        surfaceUnit: 'cell',
        contextText: 'The cell divides rapidly.',
        targetLanguage: 'en',
        spanStart: 4,
        spanEnd: 8,
        idempotencyKey: 'k2',
      );
      expect(out.meaning, 'Here cell is the in-context meaning; the cell divides rapidly.');
      expect(out.previewHandle, 'ph1');
      expect(out.charged, isTrue);
      expect(t.last.method, 'POST');
      expect(Uri.parse(t.last.url).path, '/explain/context/preview');
      expect(bodyOf(t.last), {
        'surface_unit': 'cell',
        'context_text': 'The cell divides rapidly.',
        'target_language': 'en',
        'span_start': 4,
        'span_end': 8,
        'idempotency_key': 'k2',
      });
    });

    test('editContext PATCHes /contexts/{id} with context_text', () async {
      api.restoreToken('t');
      t.enqueue(200, {'status': 'updated', 'id': 'c1'});
      await api.editContext('c1', 'a new sentence');
      expect(t.last.method, 'PATCH');
      expect(Uri.parse(t.last.url).path, '/contexts/c1');
      expect(bodyOf(t.last), {'context_text': 'a new sentence'});
    });

    test('deleteContext DELETEs /contexts/{id}', () async {
      api.restoreToken('t');
      t.enqueue(200, {'status': 'deleted', 'id': 'c1'});
      await api.deleteContext('c1');
      expect(t.last.method, 'DELETE');
      expect(Uri.parse(t.last.url).path, '/contexts/c1');
    });
  });

  group('billing', () {
    test('startCheckout POSTs the plan and returns the Stripe url', () async {
      api.restoreToken('t');
      t.enqueue(200, {'url': 'https://checkout.stripe.test/sess_1'});
      final url = await api.startCheckout(plan: 'annual');
      expect(t.last.method, 'POST');
      expect(Uri.parse(t.last.url).path, '/billing/stripe/checkout');
      expect(bodyOf(t.last)['plan'], 'annual');
      expect(url, 'https://checkout.stripe.test/sess_1');
    });

    test('verifyApplePurchase POSTs the signed transaction and parses the entitlement', () async {
      api.restoreToken('t');
      t.enqueue(200, {'pro': true, 'pro_until': 1893456000000, 'status': 'active'});
      final result = await api.verifyApplePurchase('jws.signed.transaction');
      expect(t.last.method, 'POST');
      expect(Uri.parse(t.last.url).path, '/billing/apple/verify');
      expect(bodyOf(t.last)['signed_transaction'], 'jws.signed.transaction');
      expect(result.pro, isTrue);
      expect(result.proUntil, 1893456000000);
      expect(result.status, 'active');
    });

    test('verifyApplePurchase reflects a not-yet-active entitlement', () async {
      api.restoreToken('t');
      t.enqueue(200, {'pro': false, 'pro_until': null, 'status': 'expired'});
      final result = await api.verifyApplePurchase('jws');
      expect(result.pro, isFalse);
      expect(result.proUntil, isNull);
      expect(result.status, 'expired');
    });
  });

  group('error mapping', () {
    test('a non-2xx throws ApiException carrying error + detail + status', () async {
      api.restoreToken('t');
      t.enqueue(409, {'error': 'unit_deleted', 'detail': 'this unit was deleted'});
      final err = await api
          .submitReview(
              const SyncEvent(wordId: 'w', eventId: 'e', rating: Rating.good, clientReviewTs: 1))
          .then<Object?>((_) => null, onError: (e) => e);
      expect(err, isA<ApiException>());
      final ex = err as ApiException;
      expect(ex.statusCode, 409);
      expect(ex.error, 'unit_deleted');
      expect(ex.detail, 'this unit was deleted');
    });

    test('401 sets isUnauthorized', () async {
      t.enqueue(401, {'error': 'unauthorized'});
      final err = await api.me().then<Object?>((_) => null, onError: (e) => e);
      expect((err as ApiException).isUnauthorized, isTrue);
    });

    test('email needsFreshCode flags code_expired / too_many_attempts', () async {
      t.enqueue(401, {'error': 'code_expired'});
      final err = await api
          .verifyEmailCode('u@x.z', '000000')
          .then<Object?>((_) => null, onError: (e) => e);
      expect((err as ApiException).needsFreshCode, isTrue);
    });

    test('a non-2xx with a non-JSON body still yields a synthetic error code', () async {
      api.restoreToken('t');
      t.enqueue(502, 'Bad Gateway');
      final err = await api.listWords().then<Object?>((_) => null, onError: (e) => e);
      expect((err as ApiException).error, 'http_502');
    });

    test('a 2xx with an empty body parses as an empty map (no crash)', () async {
      api.restoreToken('t');
      t.enqueue(200, '');
      final words = await api.listWords();
      expect(words, isEmpty);
    });

    test('a true transport failure (network error) propagates to the caller', () async {
      final offline =
          CapechoApi(baseUrl: 'https://api.capecho.test', transport: ThrowingTransport());
      offline.restoreToken('t');
      final err = await offline.listWords().then<Object?>((_) => null, onError: (e) => e);
      expect(err, isA<StateError>()); // NOT wrapped — a hard transport error surfaces as-is
    });

    test('query values are percent-encoded (space + ampersand round-trip)', () async {
      t.enqueue(200, {'status': 'language_unsupported'});
      await api.explain(unit: 'time & tide', target: 'en');
      expect(t.last.url, isNot(contains('time & tide'))); // raw URL is escaped
      expect(Uri.parse(t.last.url).queryParameters['unit'], 'time & tide'); // decodes back
    });
  });
}
