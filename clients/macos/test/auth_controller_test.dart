import 'dart:convert';

import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records requests + returns queued responses (default 200 `{}`). Drives the AuthController through
/// the REAL CapechoApi, so these exercise the client + controller together.
class FakeTransport implements HttpTransport {
  final List<TransportRequest> requests = [];
  final List<TransportResponse> _queue = [];
  bool throwNext = false;

  void enqueue(int status, Object body) => _queue.add(
    TransportResponse(statusCode: status, body: body is String ? body : jsonEncode(body)),
  );

  TransportRequest get last => requests.last;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    requests.add(request);
    if (throwNext) {
      throwNext = false;
      throw const _NetworkError();
    }
    return _queue.isNotEmpty
        ? _queue.removeAt(0)
        : const TransportResponse(statusCode: 200, body: '{}');
  }
}

class _NetworkError implements Exception {
  const _NetworkError();
}

/// In-memory SessionStore; can be told to throw (simulating an unavailable Keychain).
class FakeStore implements SessionStore {
  String? token;
  bool throwOnAccess = false;

  @override
  Future<String?> loadToken() async {
    if (throwOnAccess) throw Exception('keychain unavailable');
    return token;
  }

  @override
  Future<void> saveToken(String t) async {
    if (throwOnAccess) throw Exception('keychain unavailable');
    token = t;
  }

  @override
  Future<void> clear() async {
    if (throwOnAccess) throw Exception('keychain unavailable');
    token = null;
  }
}

const _sessionBody = {
  'token': 'tok_1',
  'expires_at': 999,
  'user': {
    'id': 'acc-1',
    'iana_timezone': 'UTC',
    'explanation_language': 'en',
    'explanation_follows_learning': false,
    'learning_language': null,
    'reminder_enabled': false,
    'pro': false,
  },
};

void main() {
  late FakeTransport t;
  late FakeStore store;

  AuthController make({
    List<ClaimRow> claimRows = const [
      ClaimRow(clientRowId: 'r1', surfaceUnit: 'serendipity', targetLanguage: 'en'),
    ],
    Future<String> Function()? appleCredential,
    Future<String> Function()? googleCredential,
  }) {
    return AuthController(
      api: CapechoApi(baseUrl: 'https://api.test', transport: t),
      store: store,
      collectClaimRows: () async => claimRows,
      installId: () async => 'inst-1',
      appleCredential: appleCredential ?? () async => 'apple-id-token',
      googleCredential: googleCredential ?? () async => 'google-id-token',
    );
  }

  setUp(() {
    t = FakeTransport();
    store = FakeStore();
  });

  group('email sign-in', () {
    test('startEmail → code sent; pendingEmail trimmed', () async {
      t.enqueue(200, {'status': 'sent'});
      final a = make();
      await a.startEmail('  user@example.com ');
      expect(a.codeSent, isTrue);
      expect(a.pendingEmail, 'user@example.com');
      expect(a.busy, isFalse);
      expect(a.error, isNull);
      expect(jsonDecode(t.last.body!), {'email': 'user@example.com'});
    });

    test('startEmail 429 → a friendly error, no code-entry advance', () async {
      t.enqueue(429, {'error': 'too_many_requests'});
      final a = make();
      await a.startEmail('user@example.com');
      expect(a.codeSent, isFalse);
      expect(a.error, isNotNull);
    });

    test('verifyEmail → signed in + token persisted, with NO auto-claim', () async {
      t.enqueue(200, {'status': 'sent'});
      final a = make();
      await a.startEmail('user@example.com');
      t.enqueue(200, _sessionBody); // verify
      await a.verifyEmail('424242');
      expect(a.isSignedIn, isTrue);
      expect(a.account?.id, 'acc-1');
      expect(store.token, 'tok_1'); // persisted
      expect(a.codeSent, isFalse); // email sub-flow reset
      // Local captures are NOT auto-claimed on sign-in — syncing is an explicit choice now.
      expect(a.claimedCount, 0);
      expect(t.requests.any((r) => r.url.endsWith('/words/claim')), isFalse);
    });

    test('a concurrent second start is ignored (re-entrancy guard)', () async {
      t.enqueue(200, {'status': 'sent'});
      final a = make();
      final f1 = a.startEmail('user@example.com');
      final f2 = a.startEmail('user@example.com'); // busy → ignored, no second request
      await Future.wait([f1, f2]);
      expect(t.requests.where((r) => r.url.endsWith('/auth/email/start')).length, 1);
    });

    test('verifyEmail wrong code → stays on code entry with an error', () async {
      t.enqueue(200, {'status': 'sent'});
      final a = make();
      await a.startEmail('user@example.com');
      t.enqueue(401, {'error': 'auth_failed'});
      await a.verifyEmail('000000');
      expect(a.isSignedIn, isFalse);
      expect(a.codeSent, isTrue); // can retry the same email
      expect(a.error, contains('didn’t match'));
    });

    test('verifyEmail code_expired → forces a fresh code request', () async {
      t.enqueue(200, {'status': 'sent'});
      final a = make();
      await a.startEmail('user@example.com');
      t.enqueue(401, {'error': 'code_expired'});
      await a.verifyEmail('000000');
      expect(a.isSignedIn, isFalse);
      expect(a.codeSent, isFalse); // back to the email field
      expect(a.error, contains('expired'));
    });
  });

  group('syncLocalCaptures (explicit, user-chosen claim)', () {
    AuthController makeSignedIn({
      List<ClaimRow> claimRows = const [
        ClaimRow(clientRowId: 'r1', surfaceUnit: 'serendipity', targetLanguage: 'en'),
      ],
      List<String>? claimedSink,
      int Function()? anonymousCount,
      List<String>? attemptedSink,
      List<String>? acceptedSink,
    }) {
      return AuthController(
        api: CapechoApi(baseUrl: 'https://api.test', transport: t),
        store: store,
        collectClaimRows: () async => claimRows,
        installId: () async => 'inst-1',
        markClaimed: claimedSink == null ? null : (ids, _) => claimedSink.addAll(ids),
        anonymousCount: anonymousCount,
        onSyncAttempted: attemptedSink == null ? null : (ids) => attemptedSink.addAll(ids),
        onSyncAccepted: acceptedSink == null ? null : (ids) => acceptedSink.addAll(ids),
        appleCredential: () async => 'apple-id-token',
      );
    }

    test('claims anonymous rows, stamps them locally, and reports the count', () async {
      t.enqueue(200, _sessionBody);
      final claimed = <String>[];
      final a = makeSignedIn(claimedSink: claimed);
      await a.signInWithApple();
      expect(a.isSignedIn, isTrue);

      t.enqueue(200, {
        'results': [
          {'clientRowId': 'r1', 'status': 'created', 'wordId': 'w1'},
        ],
      });
      final n = await a.syncLocalCaptures();
      expect(n, 1);
      expect(a.claimedCount, 1);
      expect(claimed, ['r1'], reason: 'markClaimed stamps only the rows the server accepted');
      expect(t.last.url, endsWith('/words/claim'));
    });

    test('is a no-op (no request) when signed out', () async {
      final a = makeSignedIn();
      expect(await a.syncLocalCaptures(), 0);
      expect(t.requests, isEmpty);
    });

    test(
      'emits the §14 sync funnel: attempted = all submitted, accepted = server-acknowledged',
      () async {
        t.enqueue(200, _sessionBody);
        final attempted = <String>[];
        final accepted = <String>[];
        final a = makeSignedIn(
          claimRows: const [
            ClaimRow(clientRowId: 'r1', surfaceUnit: 'serendipity', targetLanguage: 'en'),
            ClaimRow(
              clientRowId: 'r2',
              surfaceUnit: 'a whole sentence not a unit',
              targetLanguage: 'en',
            ),
          ],
          attemptedSink: attempted,
          acceptedSink: accepted,
        );
        await a.signInWithApple();
        t.enqueue(200, {
          'results': [
            {'clientRowId': 'r1', 'status': 'created', 'wordId': 'w1', 'contextStored': false},
            {
              'clientRowId': 'r2',
              'status': 'unit_too_large',
              'wordId': null,
              'contextStored': false,
            },
          ],
        });
        await a.syncLocalCaptures();
        expect(attempted, ['r1', 'r2'], reason: 'every submitted row is a sync_attempted');
        expect(accepted, [
          'r1',
        ], reason: 'only the server-acknowledged (wordId != null) row is a sync_accepted');
      },
    );

    test('a failure leaves rows anonymous (nothing stamped) and surfaces an error', () async {
      t.enqueue(200, _sessionBody);
      final claimed = <String>[];
      final a = makeSignedIn(claimedSink: claimed);
      await a.signInWithApple();
      t.enqueue(500, {'error': 'internal_error'});
      final n = await a.syncLocalCaptures();
      expect(n, 0);
      expect(claimed, isEmpty);
      expect(a.error, isNotNull);
    });

    test('pendingAnonymousCount is live, and 0 when signed out', () async {
      var count = 3;
      final a = makeSignedIn(anonymousCount: () => count);
      expect(a.pendingAnonymousCount, 0, reason: 'signed out → nothing to sync');
      t.enqueue(200, _sessionBody);
      await a.signInWithApple();
      expect(a.pendingAnonymousCount, 3);
      count = 0;
      expect(a.pendingAnonymousCount, 0);
    });
  });

  group('restore', () {
    test('a valid persisted token restores the session', () async {
      store.token = 'tok_old';
      t.enqueue(200, {
        'user': {
          'id': 'acc-1',
          'iana_timezone': 'UTC',
          'explanation_language': 'en',
          'explanation_follows_learning': false,
          'learning_language': null,
          'reminder_enabled': false,
          'pro': false,
        },
      });
      final a = make();
      await a.restore();
      expect(a.isSignedIn, isTrue);
      expect(a.account?.id, 'acc-1');
      expect(t.last.headers['authorization'], 'Bearer tok_old'); // me() used the token
    });

    test('an invalid/expired token is cleared and leaves the user signed out', () async {
      store.token = 'tok_bad';
      t.enqueue(401, {'error': 'unauthorized'});
      final a = make();
      await a.restore();
      expect(a.isSignedIn, isFalse);
      expect(store.token, isNull); // dropped
    });

    test('an unavailable Keychain does not crash restore', () async {
      store
        ..token = 'whatever'
        ..throwOnAccess = true;
      final a = make();
      await a.restore(); // must not throw
      expect(a.isSignedIn, isFalse);
    });
  });

  group('apple + signout', () {
    test('signInWithApple posts the identity token + signs in', () async {
      t.enqueue(200, _sessionBody);
      final a = make(claimRows: const []);
      await a.signInWithApple();
      expect(a.isSignedIn, isTrue);
      // the first request was POST /auth/session with provider apple + the injected token
      final body = jsonDecode(t.requests.first.body!) as Map<String, dynamic>;
      expect(body['provider'], 'apple');
      expect(body['credential'], 'apple-id-token');
    });

    test('a canceled Apple sheet is silent (no error)', () async {
      final a = make(appleCredential: () async => throw const SocialSignInCanceled());
      await a.signInWithApple();
      expect(a.isSignedIn, isFalse);
      expect(a.error, isNull);
      expect(a.busy, isFalse);
    });

    test('signOut clears the session even if the keychain throws', () async {
      t.enqueue(200, _sessionBody);
      final a = make(claimRows: const []);
      await a.signInWithApple();
      expect(a.isSignedIn, isTrue);
      store.throwOnAccess = true; // keychain clear() throws
      t.enqueue(200, {'status': 'signed_out'});
      await a.signOut();
      expect(a.isSignedIn, isFalse); // still signed out locally
    });
  });

  group('delete account', () {
    // Sign-in no longer auto-claims, so only the session response is consumed; enqueue the
    // deleteAccount response directly next.
    test('deleteAccount success → signed out, account cleared', () async {
      t.enqueue(200, _sessionBody);
      final a = make(claimRows: const []);
      await a.signInWithApple();
      expect(a.isSignedIn, isTrue);
      t.enqueue(200, {'status': 'deletion_scheduled'});
      await a.deleteAccount();
      expect(a.isSignedIn, isFalse);
      expect(a.account, isNull);
      expect(
        await store.loadToken(),
        isNull,
      ); // the persisted token is cleared too (no credential at rest)
    });

    test('deleteAccount failure → stays signed in (retryable) and rethrows', () async {
      t.enqueue(200, _sessionBody);
      final a = make(claimRows: const []);
      await a.signInWithApple();
      t.enqueue(503, {'error': 'internal_error'}); // the delete didn't reach / was rejected
      final err = await a.deleteAccount().then<Object?>((_) => null, onError: (e) => e);
      expect(err, isA<ApiException>()); // surfaces so the dialog can show it
      expect(a.isSignedIn, isTrue); // session preserved — the user can retry
    });
  });

  group('google + cancel + unavailable', () {
    test('signInWithGoogle posts the id token + signs in', () async {
      t.enqueue(200, _sessionBody);
      final a = make(claimRows: const []);
      await a.signInWithGoogle();
      expect(a.isSignedIn, isTrue);
      final body = jsonDecode(t.requests.first.body!) as Map<String, dynamic>;
      expect(body['provider'], 'google');
      expect(body['credential'], 'google-id-token');
    });

    test('a user-canceled provider sheet is silent (no error, signed out)', () async {
      final a = make(googleCredential: () async => throw const SocialSignInCanceled());
      await a.signInWithGoogle();
      expect(a.isSignedIn, isFalse);
      expect(a.error, isNull); // cancellation is not an error
      expect(a.busy, isFalse);
    });

    test('an unavailable provider steers to email with a calm message', () async {
      final a = make(googleCredential: () async => throw const SocialSignInUnavailable());
      await a.signInWithGoogle();
      expect(a.isSignedIn, isFalse);
      expect(a.error, contains('use email'));
    });

    test('an uninjected provider falls back to unavailable (not a crash)', () async {
      final a = AuthController(
        api: CapechoApi(baseUrl: 'https://api.test', transport: t),
        store: store,
        collectClaimRows: () async => const [],
        installId: () async => 'i',
      ); // no apple/google credential injected → the _unavailable fallback
      await a.signInWithApple();
      expect(a.isSignedIn, isFalse);
      expect(a.error, contains('use email'));
    });
  });
}
