import 'dart:convert';

import 'errors.dart';
import 'metric_event.dart';
import 'models.dart';
import 'transport.dart';

/// The typed Capecho backend client. Holds the current bearer token (set on sign-in, cleared on
/// sign-out) and injects it as `Authorization: Bearer …` on every authed request. All methods throw
/// [ApiException] on a non-2xx response; a true transport failure (no network) propagates from the
/// injected [HttpTransport].
class CapechoApi {
  CapechoApi({required String baseUrl, required this.transport})
      : _base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  final String _base;
  final HttpTransport transport;

  String? _token;

  /// The current bearer token, or null when signed out.
  String? get token => _token;

  /// True when a session token is held (does not check expiry — see [AuthSession.expiresAt]).
  bool get hasSession => _token != null;

  /// Restore a persisted token (e.g. from the Keychain at launch) without a fresh sign-in.
  void restoreToken(String token) => _token = token;

  /// Drop the local token (does NOT call the server; use [signOut] to also revoke server-side).
  void clearToken() => _token = null;

  // --- auth ------------------------------------------------------------------

  /// `POST /auth/session` — verify an OIDC credential (Apple/Google ID token) → bearer session.
  /// On success the returned token is stored on this client.
  Future<AuthSession> signIn(
    AuthProvider provider,
    String credential, {
    String? timezone,
    String? learningLanguage,
  }) async {
    final json = await _json('POST', '/auth/session', auth: false, body: {
      'provider': provider.wire,
      'credential': credential,
      if (timezone != null) 'timezone': timezone,
      if (learningLanguage != null) 'learning_language': learningLanguage,
    });
    return _adopt(AuthSession.fromJson(json));
  }

  /// Sign in with an Apple `identityToken` (Sign in with Apple).
  Future<AuthSession> signInWithApple(String identityToken,
          {String? timezone, String? learningLanguage}) =>
      signIn(AuthProvider.apple, identityToken,
          timezone: timezone, learningLanguage: learningLanguage);

  /// Sign in with a Google `idToken`.
  Future<AuthSession> signInWithGoogle(String idToken,
          {String? timezone, String? learningLanguage}) =>
      signIn(AuthProvider.google, idToken, timezone: timezone, learningLanguage: learningLanguage);

  /// `POST /auth/email/start` — email a 6-digit sign-in code. Throws [ApiException] on
  /// `too_many_requests` (429) or `email_unavailable` (503).
  Future<void> startEmailSignIn(String email) async {
    await _json('POST', '/auth/email/start', auth: false, body: {'email': email});
  }

  /// `POST /auth/email/verify` — exchange the emailed code for a bearer session. On success the
  /// token is stored on this client. Throws with `code_expired` / `too_many_attempts` /
  /// `auth_failed` (see [ApiException.needsFreshCode]).
  Future<AuthSession> verifyEmailCode(
    String email,
    String code, {
    String? timezone,
    String? learningLanguage,
  }) async {
    final json = await _json('POST', '/auth/email/verify', auth: false, body: {
      'email': email,
      'code': code,
      if (timezone != null) 'timezone': timezone,
      if (learningLanguage != null) 'learning_language': learningLanguage,
    });
    return _adopt(AuthSession.fromJson(json));
  }

  /// `GET /auth/me` — the signed-in account.
  Future<Account> me() async {
    final json = await _json('GET', '/auth/me');
    return Account.fromJson(json['user'] as Map<String, dynamic>);
  }

  /// `PATCH /account` — update the signed-in account's preferences (Settings). Only the non-null
  /// arguments are sent (an absent field is left unchanged server-side). Returns the updated [Account].
  Future<Account> updateAccount({
    String? explanationLanguage,
    bool? explanationFollowsLearning,
    String? learningLanguage,
    bool? reminderEnabled,
    String? reminderTime,
  }) async {
    final json = await _json('PATCH', '/account', body: {
      if (explanationLanguage != null) 'explanation_language': explanationLanguage,
      if (explanationFollowsLearning != null)
        'explanation_follows_learning': explanationFollowsLearning,
      if (learningLanguage != null) 'learning_language': learningLanguage,
      if (reminderEnabled != null) 'reminder_enabled': reminderEnabled,
      if (reminderTime != null) 'reminder_time': reminderTime,
    });
    return Account.fromJson(json['user'] as Map<String, dynamic>);
  }

  /// `POST /auth/signout` — revoke the current session server-side, then drop the local token.
  /// Idempotent; safe to call when already signed out.
  Future<void> signOut() async {
    try {
      await _json('POST', '/auth/signout');
    } finally {
      _token = null;
    }
  }

  /// `DELETE /account` — mark the signed-in account for hard deletion (the backend revokes this
  /// session and starts the retention window; re-signing in within it cancels the deletion). Drops the
  /// local token ONLY on success — a failure (offline / non-2xx) means the account wasn't deleted, so
  /// the session is kept and the caller can retry. Throws [ApiException] on a non-2xx (e.g. 401).
  Future<void> deleteAccount() async {
    await _json('DELETE', '/account');
    _token = null; // success: the backend revoked the session, so drop the now-inert token
  }

  // --- billing ---------------------------------------------------------------

  /// `POST /billing/stripe/checkout` — start a Pro subscription purchase on the Stripe rail (web +
  /// macOS-direct build). [plan] is `'monthly'` | `'annual'`. Returns the Stripe Checkout URL to open
  /// in the browser; fulfillment happens server-side via the webhook (the client never asserts Pro).
  /// Throws [ApiException] on a non-2xx — notably 503 `billing_unconfigured` until the secret key + the
  /// chosen price id are set on the backend.
  Future<String> startCheckout({String plan = 'monthly'}) async {
    final json = await _json('POST', '/billing/stripe/checkout', body: {'plan': plan});
    return json['url'] as String;
  }

  /// `POST /billing/apple/verify` — submit a StoreKit 2 signed transaction (the JWS
  /// `serverVerificationData` the App Store hands back on a purchase/restore) right after an in-app
  /// purchase. The server re-fetches the canonical subscription state from Apple (API-authority),
  /// updates the entitlement, and returns the resulting Pro state for an instant unlock. Requires a
  /// Bearer session. Throws [ApiException] on a non-2xx — notably 503 `billing_unconfigured` (Apple
  /// keys unset) or 502 `upstream_unavailable` (the App Store couldn't be reached).
  Future<AppleVerifyResult> verifyApplePurchase(String signedTransaction) async {
    final json = await _json(
      'POST',
      '/billing/apple/verify',
      body: {'signed_transaction': signedTransaction},
    );
    return AppleVerifyResult.fromJson(json);
  }

  // --- words + claim ---------------------------------------------------------

  /// `GET /words` — the account's Word Book (active words, oldest first).
  Future<List<Word>> listWords() async {
    final json = await _json('GET', '/words');
    return _list(json['words'], Word.fromJson);
  }

  /// `DELETE /words/{id}` — soft-delete (tombstone) a word. Idempotent-ish: throws `not_found` (404)
  /// if there's no live word by that id for this account.
  Future<void> deleteWord(String wordId) async {
    await _json('DELETE', '/words/$wordId');
  }

  /// `POST /words/{id}/restore` — un-delete a tombstoned word, PRESERVING its FSRS history (unlike
  /// re-saving the same text, which resets to a new card). Throws `not_found` (404) when there's no
  /// tombstoned word by that id for this account.
  Future<void> restoreWord(String wordId) async {
    await _json('POST', '/words/$wordId/restore');
  }

  /// `POST /words/claim` — claim locally-captured rows into the account after sign-in (idempotent on
  /// `(install_id, client_row_id)`). Max 500 rows per call.
  Future<List<ClaimResult>> claim({required String installId, required List<ClaimRow> rows}) async {
    final json = await _json('POST', '/words/claim', body: {
      'install_id': installId,
      'rows': rows.map((r) => r.toJson()).toList(),
    });
    return _list(json['results'], ClaimResult.fromJson);
  }

  // --- review + sync ---------------------------------------------------------

  /// `GET /review/due` — the due + new cards for this session. [newLimit] overrides the per-day
  /// new-card soft cap.
  Future<DueReviews> dueReviews({int? newLimit}) async {
    final json = await _json('GET', '/review/due',
        query: newLimit == null ? null : {'new_limit': '$newLimit'});
    return DueReviews.fromJson(json);
  }

  /// `POST /review` — apply one rating and get the server FSRS projection. Throws on
  /// `not_found` (404), `unit_deleted` (409), `event_id_conflict` (409).
  Future<ReviewOutcome> submitReview(SyncEvent event) async {
    final json = await _json('POST', '/review', body: event.toJson());
    return ReviewOutcome.fromJson(json);
  }

  /// `POST /sync` — flush a batch of queued offline ratings; per-event results come back in order.
  /// Max 500 events per call.
  Future<List<SyncEventResult>> sync(List<SyncEvent> events) async {
    final json =
        await _json('POST', '/sync', body: {'events': events.map((e) => e.toJson()).toList()});
    return _list(json['results'], SyncEventResult.fromJson);
  }

  // --- explain + contexts ----------------------------------------------------

  /// `GET /explain` — the free word-layer explanation. Works signed-in (generates on miss) or
  /// anonymous (HIT-only). Throws on `budget_exhausted` (503) / `generation_failed` (502). A
  /// `not_a_word` (422 — the unit isn't a real word, whether a server gate or the model's own verdict
  /// caught it) is NOT thrown: it resolves to [ExplainStatus.notAWord] so the caller shows the calm
  /// "not a word" state rather than an error.
  Future<ExplainResult> explain({
    required String unit,
    required String target,
    String? explanationLang,
    String? wordId,
  }) async {
    try {
      final json = await _json('GET', '/explain', query: {
        'unit': unit,
        'target': target,
        if (explanationLang != null) 'explanation_lang': explanationLang,
        if (wordId != null) 'word_id': wordId,
      });
      return ExplainResult.fromJson(json);
    } on ApiException catch (e) {
      if (e.error == 'not_a_word') {
        return const ExplainResult(status: ExplainStatus.notAWord, explanation: null);
      }
      rethrow;
    }
  }

  /// `GET /contexts?word_id=` — the saved context sentences for a word (decrypted server-side).
  Future<List<ContextView>> contexts(String wordId) async {
    final json = await _json('GET', '/contexts', query: {'word_id': wordId});
    return _list(json['contexts'], ContextView.fromJson);
  }

  /// `POST /explain/context` — the paid sentence-specific explanation (metered, §16). Returns the gloss
  /// + whether this call was charged (false = served from a stored gloss on re-view). Throws
  /// [ApiException] on `quota_exhausted` (429), `generation_failed` (502), `not_found` (404), etc.
  Future<ContextExplanation> explainContext(
    String contextId, {
    String? explanationLang,
    String? idempotencyKey,
  }) async {
    final json = await _json('POST', '/explain/context', body: {
      'word_context_id': contextId,
      if (explanationLang != null) 'explanation_lang': explanationLang,
      if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
    });
    return ContextExplanation.fromJson(json);
  }

  /// `POST /explain/context/preview` (E2) — explain a word IN its captured sentence BEFORE it is saved,
  /// on the raw (word, sentence), so the in-context meaning is reachable from the overlay. Metered from
  /// the SAME daily pool as [explainContext]. Returns the gloss + a [ContextPreview.previewHandle] that
  /// Save passes back to adopt the gloss with no recharge. Throws on `quota_exhausted` (429),
  /// `generation_failed` (502), `invalid_unit`/`context_too_large` (422), etc.
  Future<ContextPreview> explainContextPreview({
    required String surfaceUnit,
    required String contextText,
    String? targetLanguage,
    String? contextLanguage,
    int? spanStart,
    int? spanEnd,
    String? explanationLang,
    String? idempotencyKey,
  }) async {
    final json = await _json('POST', '/explain/context/preview', body: {
      'surface_unit': surfaceUnit,
      'context_text': contextText,
      if (targetLanguage != null) 'target_language': targetLanguage,
      if (contextLanguage != null) 'context_language': contextLanguage,
      if (spanStart != null) 'span_start': spanStart,
      if (spanEnd != null) 'span_end': spanEnd,
      if (explanationLang != null) 'explanation_lang': explanationLang,
      if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
    });
    return ContextPreview.fromJson(json);
  }

  /// `PATCH /contexts/{id}` — edit a saved context's sentence text. The server clears that context's
  /// stored gloss (it was for the old sentence). Throws on `empty_context` / `context_too_large` (422)
  /// or `not_found` (404).
  Future<void> editContext(String contextId, String contextText) async {
    await _json('PATCH', '/contexts/$contextId', body: {'context_text': contextText});
  }

  /// `DELETE /contexts/{id}` — remove a saved context. Throws on `not_found` (404).
  Future<void> deleteContext(String contextId) async {
    await _json('DELETE', '/contexts/$contextId');
  }

  // --- export ----------------------------------------------------------------

  /// `GET /export?format=csv` — the Word Book as CSV text (the client saves it to a `.csv` file).
  Future<String> exportCsv({bool attribution = false}) async {
    final res = await transport.send(TransportRequest(
      method: 'GET',
      url: _url('/export', {'format': 'csv', if (attribution) 'attribution': 'true'}),
      headers: _headers(auth: true, jsonBody: false),
    ));
    if (res.statusCode >= 200 && res.statusCode < 300) return res.body;
    throw _errorFrom(res);
  }

  /// `GET /export?format=json` — the Word Book as structured [ExportRow]s (one active unit each). The
  /// macOS client assembles these into a one-click Anki `.apkg` deck locally; `attribution` is applied
  /// by the deck builder (as a note tag), so it is NOT a request param here. The body is a top-level
  /// JSON array, so this fetches the raw body and decodes it directly (the `_json` helper is object-only).
  Future<List<ExportRow>> exportRows() async {
    final res = await transport.send(TransportRequest(
      method: 'GET',
      url: _url('/export', {'format': 'json'}),
      headers: _headers(auth: true, jsonBody: false),
    ));
    if (res.statusCode < 200 || res.statusCode >= 300) throw _errorFrom(res);
    final decoded = res.body.isEmpty ? const [] : jsonDecode(res.body);
    return (decoded as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(ExportRow.fromJson)
        .toList();
  }

  // --- internals -------------------------------------------------------------

  AuthSession _adopt(AuthSession session) {
    _token = session.token;
    return session;
  }

  String _url(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$_base$path');
    if (query == null || query.isEmpty) return uri.toString();
    return uri.replace(queryParameters: {...uri.queryParameters, ...query}).toString();
  }

  // --- §14 metrics (CEO-10) --------------------------------------------------

  /// `POST /metrics` — submit a batch of §14 metric events. `auth: true` attaches the bearer WHEN a
  /// session is held and otherwise sends anonymously (install_id only), which the server accepts so
  /// the pre-login first-capture latency is measured. Returns the server's accepted/dropped tally.
  Future<MetricIngestResult> postMetrics(MetricBatch batch) async {
    final json = await _json('POST', '/metrics', auth: true, body: batch.toJson());
    return MetricIngestResult.fromJson(json);
  }

  Map<String, String> _headers({required bool auth, required bool jsonBody}) {
    final h = <String, String>{'accept': 'application/json'};
    if (jsonBody) h['content-type'] = 'application/json';
    if (auth && _token != null) h['authorization'] = 'Bearer $_token';
    return h;
  }

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool auth = true,
  }) async {
    final res = await transport.send(TransportRequest(
      method: method,
      url: _url(path, query),
      headers: _headers(auth: auth, jsonBody: body != null),
      body: body == null ? null : jsonEncode(body),
    ));
    final decoded = _decode(res.body);
    if (res.statusCode >= 200 && res.statusCode < 300) return decoded ?? <String, dynamic>{};
    throw ApiException(
      statusCode: res.statusCode,
      error: (decoded?['error'] as String?) ?? 'http_${res.statusCode}',
      detail: decoded?['detail'] as String?,
    );
  }

  ApiException _errorFrom(TransportResponse res) {
    final decoded = _decode(res.body);
    return ApiException(
      statusCode: res.statusCode,
      error: (decoded?['error'] as String?) ?? 'http_${res.statusCode}',
      detail: decoded?['detail'] as String?,
    );
  }

  static Map<String, dynamic>? _decode(String body) {
    if (body.isEmpty) return null;
    try {
      final d = jsonDecode(body);
      return d is Map<String, dynamic> ? d : null;
    } catch (_) {
      return null;
    }
  }

  static List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) from) =>
      (raw as List? ?? const []).cast<Map<String, dynamic>>().map(from).toList();
}
