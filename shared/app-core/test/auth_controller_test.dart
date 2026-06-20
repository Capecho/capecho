import 'dart:async';
import 'dart:convert';

import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory [SessionStore] so the controller can `restore()` a session without a platform store.
class _MemStore implements SessionStore {
  String? token;
  @override
  Future<String?> loadToken() async => token;
  @override
  Future<void> saveToken(String t) async => token = t;
  @override
  Future<void> clear() async => token = null;
}

class _Net implements Exception {
  const _Net();
}

/// Programmable transport. The `/words/claim` and `/auth/me` responses can be GATED on a [Completer]
/// so a test can change the session WHILE a request is in flight, and can be made to throw.
class _Txp implements HttpTransport {
  _Txp({required this.explanationLanguage});
  String explanationLanguage;
  bool throwOnClaim = false;
  bool capOnClaim = false; // make /words/claim return a cap_reached row
  bool throwOnMe = false;
  Completer<void>? gate;
  final List<String> paths = [];

  Map<String, dynamic> get _account => {
    'id': 'acct-1',
    'iana_timezone': 'UTC',
    'explanation_language': explanationLanguage,
    'explanation_follows_learning': false,
    'learning_language': 'en',
    'reminder_enabled': false,
    'pro': false,
  };

  @override
  Future<TransportResponse> send(TransportRequest r) async {
    final path = Uri.parse(r.url).path;
    paths.add(path);
    final gated = path.endsWith('/words/claim') || path.endsWith('/auth/me');
    if (gated && gate != null) await gate!.future;
    if (path.endsWith('/words/claim')) {
      if (throwOnClaim) throw const _Net();
      if (capOnClaim) {
        return TransportResponse(
          statusCode: 200,
          body: jsonEncode({
            'results': [
              {'clientRowId': 'w1', 'status': 'cap_reached', 'wordId': null},
            ],
          }),
        );
      }
      return TransportResponse(
        statusCode: 200,
        body: jsonEncode({
          'results': [
            {'clientRowId': 'w1', 'status': 'created', 'wordId': 'srv1', 'contextStored': true},
          ],
        }),
      );
    }
    if (path.endsWith('/auth/me')) {
      if (throwOnMe) throw const _Net();
      return TransportResponse(statusCode: 200, body: jsonEncode({'user': _account}));
    }
    // /auth/signout and anything else → immediate empty 200 (never gated, so signOut can't deadlock).
    return const TransportResponse(statusCode: 200, body: '{}');
  }
}

void main() {
  late _Txp txp;
  late CapechoApi api;
  late _MemStore store;
  late List<String> claimed;
  late List<String> claimedAccounts; // the accountId markClaimed was called with, per call
  late int capReachedFires; // how many times onCapReached fired
  late AuthController auth;

  Future<void> signIn() async {
    store.token = 'tok';
    await auth.restore(); // GET /auth/me → signed in
    expect(auth.isSignedIn, isTrue);
  }

  setUp(() {
    txp = _Txp(explanationLanguage: 'en');
    api = CapechoApi(baseUrl: 'https://api.test', transport: txp);
    store = _MemStore();
    claimed = [];
    claimedAccounts = [];
    capReachedFires = 0;
    auth = AuthController(
      api: api,
      store: store,
      collectClaimRows: () async => const [],
      installId: () async => 'inst',
      markClaimed: (ids, accountId) {
        claimed.addAll(ids);
        claimedAccounts.add(accountId);
      },
      anonymousCount: () => 0,
      onCapReached: () => capReachedFires++,
    );
  });

  ClaimRow row() => const ClaimRow(clientRowId: 'w1', surfaceUnit: 'x', targetLanguage: 'en');

  group('claimRows', () {
    test('marks accepted rows claimed; never touches busy', () async {
      await signIn();
      expect(auth.busy, isFalse);
      await auth.claimRows([row()]);
      expect(claimed, ['w1']); // server accepted (wordId non-null) → marked claimed locally
      expect(claimedAccounts, [
        'acct-1',
      ], reason: 'the row is stamped with the id of the account that owned the claim');
      expect(auth.busy, isFalse); // background work must not flip the UI-blocking flag
      expect(auth.error, isNull);
    });

    test('a claim failure leaves rows anonymous and surfaces no error', () async {
      await signIn();
      txp.throwOnClaim = true;
      await auth.claimRows([row()]);
      expect(claimed, isEmpty); // not marked — stays anonymous for a later sync
      expect(auth.error, isNull); // silent background upload, never a user-facing error
      expect(auth.busy, isFalse);
    });

    test('aborts (no markClaimed) when the session changes mid-claim', () async {
      await signIn();
      final gate = Completer<void>();
      txp.gate = gate;
      final f = auth.claimRows([row()]); // parks awaiting the gated /words/claim
      await Future<void>.delayed(Duration.zero);
      await auth.signOut(); // bumps the session epoch while the claim is in flight
      gate.complete();
      await f;
      expect(claimed, isEmpty); // the stale response must NOT stamp local rows for the dead session
    });

    test('no-op when signed out', () async {
      await auth.claimRows([row()]);
      expect(claimed, isEmpty);
      expect(txp.paths, isEmpty);
    });

    test('a cap_reached row fires onCapReached and is not claimed', () async {
      await signIn();
      txp.capOnClaim = true;
      await auth.claimRows([row()]);
      expect(capReachedFires, 1); // the milestone-prompt nudge fired
      expect(claimed, isEmpty); // the blocked row stays anonymous (kept on the device)
    });
  });

  group('isPro', () {
    test('reflects the account Pro flag; false when signed out', () async {
      expect(auth.isPro, isFalse); // signed out
      await signIn();
      expect(auth.isPro, isFalse); // the fake account carries no pro flag → free
      auth.applyAccount(
        const Account(
          id: 'acct-1',
          ianaTimezone: 'UTC',
          explanationLanguage: 'en',
          explanationFollowsLearning: false,
          learningLanguage: 'en',
          reminderEnabled: false,
          pro: true,
          proUntil: 1893456000000,
        ),
      );
      expect(auth.isPro, isTrue);
    });
  });

  group('refreshAccount', () {
    test('applies the freshly fetched account', () async {
      await signIn(); // account explanation_language = en
      txp.explanationLanguage = 'es'; // another client changed it
      await auth.refreshAccount();
      expect(auth.account?.explanationLanguage, 'es');
    });

    test('keeps the cached account on a fetch failure', () async {
      await signIn();
      txp.throwOnMe = true;
      await auth.refreshAccount();
      expect(auth.account?.explanationLanguage, 'en'); // unchanged, not blanked
    });

    test('drops the result when a newer account write lands mid-fetch (same session)', () async {
      await signIn(); // account explanation_language = en
      final gate = Completer<void>();
      txp.gate = gate;
      txp.explanationLanguage = 'es'; // the in-flight /auth/me would return this stale snapshot
      final f = auth.refreshAccount(); // parks awaiting the gated /auth/me
      await Future<void>.delayed(Duration.zero);
      // A save lands while the refresh is in flight (user changed a pref in Settings).
      auth.applyAccount(
        const Account(
          id: 'acct-1',
          ianaTimezone: 'UTC',
          explanationLanguage: 'fr',
          explanationFollowsLearning: false,
          learningLanguage: 'en',
          reminderEnabled: false,
          pro: false,
        ),
      );
      gate.complete();
      await f;
      expect(
        auth.account?.explanationLanguage,
        'fr',
      ); // the save wins; the stale refresh is discarded
    });

    test('drops the result when the session ends mid-fetch', () async {
      await signIn();
      final gate = Completer<void>();
      txp.gate = gate;
      txp.explanationLanguage = 'es';
      final f = auth.refreshAccount(); // parks awaiting the gated /auth/me
      await Future<void>.delayed(Duration.zero);
      await auth.signOut(); // session ends while the fetch is in flight
      gate.complete();
      await f;
      expect(auth.isSignedIn, isFalse);
      expect(auth.account, isNull); // the stale 'es' response must not resurrect a dead session
    });
  });
}
