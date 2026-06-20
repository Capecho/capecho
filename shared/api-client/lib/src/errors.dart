/// The single exception type the client throws for a non-2xx response (or an unparseable one).
///
/// The backend's error shape is `{ "error": "<machine code>", "detail"?: "<human string>" }` (see
/// `backend/src/http.ts` `problem()`), so callers switch on [error] — e.g. `"unauthorized"`,
/// `"unit_deleted"`, `"event_id_conflict"`, `"budget_exhausted"`, `"too_many_attempts"`,
/// `"code_expired"`, `"email_unavailable"` — and surface [detail] only as a fallback message.
class ApiException implements Exception {
  ApiException({
    required this.statusCode,
    required this.error,
    this.detail,
  });

  /// HTTP status code (e.g. 401, 404, 409, 429, 503).
  final int statusCode;

  /// The backend's machine-readable `error` code, or the synthetic `"http_<code>"` when the response
  /// body carried no `error` field (e.g. a non-JSON gateway error).
  final String error;

  /// The backend's optional human-readable `detail`, if present.
  final String? detail;

  /// True for an auth failure (no/expired/revoked session) — the app should route to sign-in.
  bool get isUnauthorized => statusCode == 401;

  /// True when a daily AI capacity cap was hit (global word-layer budget).
  bool get isBudgetExhausted => error == 'budget_exhausted';

  /// True when a NET-NEW save was blocked by the free saved-word cap (the Pro lever) — `POST /words`
  /// 402. Existing words are untouched; the client surfaces the upgrade prompt + keeps the word local.
  bool get isCapReached => statusCode == 402 && error == 'cap_reached';

  /// True when the caller should request a fresh email code (expired or attempt-locked).
  bool get needsFreshCode => error == 'code_expired' || error == 'too_many_attempts';

  @override
  String toString() => 'ApiException($statusCode $error${detail != null ? ': $detail' : ''})';
}
