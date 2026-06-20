import 'package:capecho_api/capecho_api.dart';
import 'package:flutter/foundation.dart';

import 'session_store.dart';

/// Drives sign-in for the macOS onboarding step 4 + the (future) Settings account row. Holds the
/// session via [CapechoApi] + persists the token via [SessionStore]; on a successful sign-in it
/// claims the device's locally-captured words into the new account (best-effort — a claim failure
/// never blocks sign-in).
///
/// State is plain flags (not an enum) so the UI can read [busy] / [codeSent] / [error] /
/// [isSignedIn] directly. All the platform seams ([appleCredential]) are injectable so the whole
/// controller is unit-testable with a fake API + fake store and no plugins.
class AuthController extends ChangeNotifier {
  AuthController({
    required this.api,
    required this.store,
    required this.collectClaimRows,
    required this.installId,
    this.markClaimed,
    this.anonymousCount,
    this.onSyncAttempted,
    this.onSyncAccepted,
    this.onCapReached,
    this.timezoneName,
    this.appleCredential,
    this.googleCredential,
  });

  final CapechoApi api;
  final SessionStore store;

  /// Builds the claim payload from the device's ANONYMOUS local captures (the app wires this from its
  /// repository; tests pass a stub). Returns [] when there's nothing to sync.
  final Future<List<ClaimRow>> Function() collectClaimRows;

  /// The stable per-install id (claim idempotency key).
  final Future<String> Function() installId;

  /// Marks the given local `client_row_id`s as synced into the account (identified by `accountId`)
  /// after a successful claim, so they leave the signed-out Word Book and the signed-in "already
  /// saved" cue can scope to the owning account. The controller passes the id of the account whose
  /// session STARTED the claim (bound before the network round-trip), so a mid-claim account switch
  /// never stamps a row for the wrong account. Injected by the app (wires
  /// `CaptureRepository.markClaimed`); null in tests / pre-store construction. See [syncLocalCaptures].
  final void Function(List<String> clientRowIds, String accountId)? markClaimed;

  /// Returns how many local captures are still anonymous (un-synced). Injected by the app (wires
  /// `CaptureRepository.anonymousWords().length`); null → 0. Drives [pendingAnonymousCount].
  final int Function()? anonymousCount;

  /// §14 chain-completeness hooks (CEO-10): [onSyncAttempted] fires with every submitted row's
  /// client_row_id per claim chunk; [onSyncAccepted] with the rows the server acknowledged. The app
  /// wires these to the metrics recorder; null in tests. They never affect the claim outcome.
  final void Function(Iterable<String> clientRowIds)? onSyncAttempted;
  final void Function(Iterable<String> clientRowIds)? onSyncAccepted;

  /// Fires when a claim/sync is blocked by the free saved-word cap (a row came back `cap_reached`) — the
  /// app surfaces the milestone "upgrade to Pro" prompt. The blocked word stays an anonymous local
  /// capture (un-claimed), so it isn't lost. Injected by the app; null in tests / when there's no UI.
  final void Function()? onCapReached;

  /// IANA timezone for the account (first-create only); null → server defaults to UTC.
  final String? timezoneName;

  /// Returns an Apple identity token (the OIDC credential to exchange at `/auth/session`). The app
  /// injects the real Sign in with Apple flow (`appleIdentityToken`); tests inject a fake. The
  /// function may throw [SocialSignInCanceled] to abort silently or [SocialSignInUnavailable] to
  /// steer to email. Null → Apple is unavailable on this build.
  final Future<String> Function()? appleCredential;

  /// Returns a Google ID token — same contract as [appleCredential]. The app injects the real
  /// google_sign_in flow (`googleIdToken`); null → Google is unavailable on this build.
  final Future<String> Function()? googleCredential;

  bool _busy = false;
  bool get busy => _busy;

  bool _signedIn = false;
  bool get isSignedIn => _signedIn;

  /// Monotonic session identity, bumped on every sign-in / sign-out / delete. Background work that
  /// outlives a session change (an in-flight `/words/claim` or `/account` fetch) captures this at entry
  /// and bails if it changed — so a stale response can't upload into, or overwrite, a DIFFERENT account
  /// (the `isSignedIn` check alone can't catch an account *switch*, since it's true for both accounts).
  int _sessionEpoch = 0;

  /// The current session identity. A caller that awaits a network round-trip and then applies the
  /// result (e.g. a Settings `PATCH /account`) captures this before the await and skips applying if it
  /// changed — so a response for account A can't land on account B after a mid-flight switch (an
  /// `isSignedIn` check alone can't tell the two apart, since both are signed in).
  int get sessionEpoch => _sessionEpoch;

  Account? _account;
  Account? get account => _account;

  /// Whether the signed-in account holds Pro (server-authoritative; false when signed out). Surfaces
  /// for the Settings status row + gating Pro-only affordances — the server re-checks every gated path,
  /// so this is a UI hint, never the access control itself.
  bool get isPro => _account?.pro ?? false;

  /// Counts authoritative account writes (a Settings `PATCH /account` apply). A `refreshAccount`
  /// `GET /auth/me` captures this before its fetch and discards its result if a newer write landed
  /// meanwhile — so a slow refresh issued at Settings-open can't overwrite a save the user made while
  /// it was in flight (both are the same session, so the epoch can't catch this).
  int _accountWrites = 0;

  /// Replace the cached account with a server-authoritative copy (e.g. after a Settings
  /// `PATCH /account` returns the updated record), so every surface reading [account] sees the
  /// saved preferences — not the pre-edit values.
  void applyAccount(Account account) {
    _account = account;
    _accountWrites++;
    _notify();
  }

  String? _error;
  String? get error => _error;

  /// Email sub-flow: a code has been sent and we're awaiting its entry.
  bool _codeSent = false;
  bool get codeSent => _codeSent;

  String? _pendingEmail;
  String? get pendingEmail => _pendingEmail;

  /// How many local captures were claimed into the account on the last [syncLocalCaptures] (0 if none).
  int _claimedCount = 0;
  int get claimedCount => _claimedCount;

  /// How many local captures are still anonymous (un-synced) and could be synced into the account —
  /// drives the Word Book "Sync N words" affordance. 0 when signed out (there's no account to sync
  /// into yet) or when nothing is pending. Read live each call, so it reflects new captures.
  int get pendingAnonymousCount => isSignedIn ? (anonymousCount?.call() ?? 0) : 0;

  /// The server caps a single claim batch; chunk the Word Book so a large local store still claims.
  static const int _maxClaimRowsPerCall = 500;

  /// Sync the device's anonymous local captures into the signed-in account — the explicit,
  /// user-chosen claim (the silent auto-claim on sign-in was removed so a signed-out user's words
  /// never leave the device without consent). Chunks to the server's per-batch cap, then marks the
  /// claimed rows locally ([markClaimed]) so they leave the signed-out catalog. Returns the number of
  /// rows claimed; a no-op returning 0 when signed out / busy / nothing pending. Best-effort: a
  /// failure leaves the rows anonymous (a later sync retries) and surfaces via [error].
  Future<int> syncLocalCaptures() async {
    if (!isSignedIn || _busy) return 0;
    // The account the claimed rows belong to. Held _busy below blocks a mid-sync sign-out (signOut
    // early-returns while busy), so the session can't switch under us — capture it once up front.
    final accountId = _account?.id;
    if (accountId == null) return 0;
    _begin();
    var claimed = 0;
    var capHit = false;
    try {
      final rows = await collectClaimRows();
      if (rows.isNotEmpty) {
        final install = await installId();
        // Chunk to the server's per-batch cap so a Word Book larger than one batch still syncs fully.
        for (var i = 0; i < rows.length; i += _maxClaimRowsPerCall) {
          final end = (i + _maxClaimRowsPerCall).clamp(0, rows.length);
          final chunk = rows.sublist(i, end);
          // §14: every row in this chunk is now submitted (the chain denominator).
          onSyncAttempted?.call([for (final r in chunk) r.clientRowId]);
          final results = await api.claim(installId: install, rows: chunk);
          // Stamp the rows the server accepted PER CHUNK — so a later chunk's failure can't strand an
          // earlier chunk's accepted rows as anonymous (which would re-surface them in the "Sync N"
          // banner under a misleading success). The unaccepted rest stay anonymous for a later retry.
          final accepted = [
            for (final r in results)
              if (r.claimed) r.clientRowId,
          ];
          // §14: the rows the server acknowledged (reconciled server-side against the live word).
          onSyncAccepted?.call(accepted);
          if (results.any((r) => r.capReached)) capHit = true;
          if (accepted.isNotEmpty) markClaimed?.call(accepted, accountId);
          claimed += accepted.length;
          _claimedCount = claimed;
        }
        // One nudge per sync even if several chunks hit the cap (the un-claimed rows stay on the device).
        if (capHit) onCapReached?.call();
      }
    } on ApiException catch (_) {
      _error = 'Couldn’t sync your words — try again.';
    } catch (_) {
      _error = 'Couldn’t sync your words — check your connection.';
    } finally {
      _end();
    }
    return claimed;
  }

  /// Claim a SPECIFIC set of rows into the signed-in account immediately — used to upload a word the
  /// moment it's captured WHILE signed in, so post-login captures reach the account without waiting for
  /// the manual backlog [syncLocalCaptures]. Only claims the rows it's given (never the pre-login
  /// backlog, which stays an explicit user choice). Best-effort + idempotent: marks the accepted rows
  /// claimed locally; a failure leaves them anonymous for a later sync. Background, so — unlike
  /// [syncLocalCaptures] — it does NOT touch [busy] (it mustn't block or be blocked by UI actions).
  Future<void> claimRows(List<ClaimRow> rows) async {
    if (!isSignedIn || rows.isEmpty) return;
    // Bind to the session that started this claim: if the user signs out / switches accounts while a
    // chunk is in flight, abort before marking anything locally so a word captured under account A
    // isn't stamped claimed (or its result trusted) against account B. The account id is captured here
    // too — so even the local `markClaimed` stamp records the account that OWNED the claim, never
    // whatever happens to be current when the response lands.
    final epoch = _sessionEpoch;
    final accountId = _account?.id;
    if (accountId == null) return;
    var claimedAny = false;
    try {
      final install = await installId();
      for (var i = 0; i < rows.length; i += _maxClaimRowsPerCall) {
        if (_sessionEpoch != epoch) {
          return; // session changed mid-claim — stop, don't touch new account
        }
        final end = (i + _maxClaimRowsPerCall).clamp(0, rows.length);
        final chunk = rows.sublist(i, end);
        onSyncAttempted?.call([for (final r in chunk) r.clientRowId]);
        final results = await api.claim(installId: install, rows: chunk);
        if (_sessionEpoch != epoch) {
          return; // session changed during the request — don't mark/trust it
        }
        final accepted = [
          for (final r in results)
            if (r.claimed) r.clientRowId,
        ];
        onSyncAccepted?.call(accepted);
        // A capture blocked by the free cap → nudge upgrade. The row stays anonymous (not in `accepted`),
        // so it's kept on the device, not lost.
        if (results.any((r) => r.capReached)) onCapReached?.call();
        if (accepted.isNotEmpty) {
          markClaimed?.call(accepted, accountId);
          claimedAny = true;
        }
      }
    } catch (_) {
      // Leave the rows anonymous; the manual Sync (or the next capture) retries. Never surfaces an
      // error — this is a silent background upload, not a user-initiated action.
    }
    // The anonymous count changed → let the Word Book's "Sync N" banner re-read it.
    if (claimedAny) _notify();
  }

  /// Re-fetch the account from the server (`GET /account` via [CapechoApi.me]) and apply it, so a
  /// surface that re-reads [account] on open reflects preference changes made on another device/client
  /// (the two clients otherwise only see their own last write). No-op when signed out; a transient /
  /// offline failure keeps the cached account rather than blanking the UI.
  Future<void> refreshAccount() async {
    if (!isSignedIn) return;
    final epoch = _sessionEpoch;
    final writes = _accountWrites;
    try {
      final fresh = await api.me();
      // Drop the result if the session changed during the fetch — a sign-out (no account to apply to)
      // OR a switch to a different account (whose prefs the stale response would otherwise overwrite;
      // `isSignedIn` is true for the new account, so the epoch is what distinguishes them). Also drop
      // it if a newer account write landed meanwhile (a save raced this refresh) so a pre-save snapshot
      // can't revert the just-saved value.
      if (_sessionEpoch != epoch || !isSignedIn || _accountWrites != writes) return;
      _account = fresh;
      _notify();
    } catch (_) {
      // Keep the cached account; a transient/offline failure must not wipe Settings.
    }
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// notifyListeners that is inert after dispose — the unawaited `restore()` future can resolve
  /// after the host tears the controller down at launch.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Restore a persisted session on launch. A token the server has revoked/expired fails `me()` and
  /// is cleared, leaving the user signed out.
  Future<void> restore() async {
    String? token;
    try {
      token = await store.loadToken();
    } catch (_) {
      return; // Token store unavailable → no persisted session; stay signed out.
    }
    if (token == null || token.isEmpty) return;
    api.restoreToken(token);
    try {
      _account = await api.me();
      _signedIn = true;
    } catch (_) {
      api.clearToken();
      await store.clear();
    }
    _notify();
  }

  /// Email step 1: request a 6-digit code. On success the UI moves to code entry.
  Future<void> startEmail(String email) async {
    if (_busy) return; // a TextField Enter-submit can race the button; one request at a time
    final trimmed = email.trim();
    _begin();
    try {
      await api.startEmailSignIn(trimmed);
      _pendingEmail = trimmed;
      _codeSent = true;
    } on ApiException catch (e) {
      _error = _emailStartError(e);
    } catch (_) {
      _error = 'Couldn’t send the code — check your connection.';
    } finally {
      _end();
    }
  }

  /// Email step 2: verify the code → bearer session → claim local captures.
  Future<void> verifyEmail(String code) async {
    if (_busy) return;
    final email = _pendingEmail;
    if (email == null) return;
    _begin();
    try {
      final session = await api.verifyEmailCode(email, code.trim(), timezone: timezoneName);
      await _onSignedIn(session);
    } on ApiException catch (e) {
      if (e.needsFreshCode) {
        _codeSent = false; // force a fresh request
        _error = e.error == 'too_many_attempts'
            ? 'Too many tries — request a new code.'
            : 'That code expired — request a new one.';
      } else {
        _error = 'That code didn’t match. Try again.';
      }
    } catch (_) {
      _error = 'Couldn’t verify the code — check your connection.';
    } finally {
      _end();
    }
  }

  /// Sign in with Apple (native). Cancellation is silent; a missing entitlement / unconfigured build
  /// surfaces a calm steer to email.
  Future<void> signInWithApple() => _socialSignIn(
    credential: appleCredential ?? _unavailable,
    exchange: (token) => api.signInWithApple(token, timezone: timezoneName),
    unavailableMessage: 'Apple sign-in isn’t set up on this build yet — use email for now.',
    // A backend reject (an unverifiable token — usually APPLE_CLIENT_ID / the App ID's "Sign in
    // with Apple" capability not yet configured) lands here, so steer to email instead of an
    // endless retry. See clients/macos/SIGN-IN-SETUP.md.
    failureMessage:
        'Apple sign-in couldn’t be verified — if it keeps failing, it isn’t fully set up yet, so use email for now.',
  );

  /// Sign in with Google (native). Same outcomes as [signInWithApple].
  Future<void> signInWithGoogle() => _socialSignIn(
    credential: googleCredential ?? _unavailable,
    exchange: (token) => api.signInWithGoogle(token, timezone: timezoneName),
    unavailableMessage: 'Google sign-in isn’t set up on this build yet — use email for now.',
    // Same as Apple: a backend reject (token aud not in GOOGLE_CLIENT_ID, or the OAuth client not
    // configured) lands here — steer to email rather than an endless retry. See SIGN-IN-SETUP.md.
    failureMessage:
        'Google sign-in couldn’t be verified — if it keeps failing, it isn’t fully set up yet, so use email for now.',
  );

  /// Shared engine for the OIDC providers: fetch a provider credential, exchange it for a bearer
  /// session, then claim the device's local captures. A [SocialSignInCanceled] is silent (the user
  /// backed out of the system sheet); [SocialSignInUnavailable] shows [unavailableMessage]; any other
  /// failure shows [failureMessage]. Re-entrant calls (a double-tap / Enter race) are ignored.
  Future<void> _socialSignIn({
    required Future<String> Function() credential,
    required Future<AuthSession> Function(String) exchange,
    required String unavailableMessage,
    required String failureMessage,
  }) async {
    if (_busy) return;
    _begin();
    try {
      final token = await credential();
      final session = await exchange(token);
      await _onSignedIn(session);
    } on SocialSignInCanceled {
      // The user dismissed the native sheet — not an error, just stop.
    } on SocialSignInUnavailable {
      _error = unavailableMessage;
    } catch (_) {
      _error = failureMessage;
    } finally {
      _end();
    }
  }

  /// Revoke the session server-side, drop the token, and reset to signed-out.
  Future<void> signOut() async {
    if (_busy) return;
    _begin();
    try {
      await api.signOut();
    } catch (_) {
      // signOut already drops the in-memory token in `finally`; ignore network failure.
    }
    try {
      await store.clear();
    } catch (_) {
      // Token store unavailable — the server session is already revoked; ignore.
    }
    _sessionEpoch++; // session ended → in-flight claims/refreshes from this session must not apply
    _signedIn = false;
    _account = null;
    _claimedCount = 0;
    _resetEmail();
    _end();
  }

  /// Delete the account (`DELETE /account`): the backend marks it for hard deletion + revokes the
  /// session, so on success we reset to signed-out locally. On a failure the session is preserved (the
  /// delete didn't happen) and the error is rethrown so the caller can surface it + let the user retry.
  /// Re-signing in within the retention window cancels the deletion.
  Future<void> deleteAccount() async {
    if (_busy) return;
    _begin();
    try {
      await api.deleteAccount();
      // Drop the persisted (now-revoked) token too, like signOut — don't leave a credential at rest
      // after an explicit account deletion. Best-effort: the server session is already gone.
      try {
        await store.clear();
      } catch (_) {}
      _sessionEpoch++; // account gone → invalidate in-flight prior-session background work
      _signedIn = false;
      _account = null;
      _claimedCount = 0;
      _resetEmail();
    } finally {
      _end();
    }
  }

  /// Back out of the email sub-flow to the provider buttons.
  void resetEmailFlow() {
    _resetEmail();
    _error = null;
    _notify();
  }

  Future<void> _onSignedIn(AuthSession session) async {
    await _saveTokenBestEffort(session.token);
    _sessionEpoch++; // new session identity → invalidate any in-flight prior-session background work
    _account = session.account;
    _signedIn = true;
    _resetEmail();
    // Local captures are deliberately NOT auto-claimed here. Syncing anonymous local words into the
    // account is an explicit user choice ([syncLocalCaptures], surfaced as the Word Book "Sync N"
    // affordance) so a signed-out user's words never leave the device without consent.
  }

  Future<void> _saveTokenBestEffort(String token) async {
    try {
      await store.saveToken(token);
    } catch (_) {
      // Token store unavailable → in-memory session only (api already holds the token). Don't fail.
    }
  }

  /// Default provider credential when none is injected: the provider is unavailable on this build.
  /// The app wires the real plugin flow in `main`; tests inject a fake. Static so it can be used as a
  /// tear-off for the `?? _unavailable` fallback.
  static Future<String> _unavailable() async => throw const SocialSignInUnavailable();

  String _emailStartError(ApiException e) {
    if (e.statusCode == 429) return 'A code was just sent — check your email or wait a moment.';
    if (e.error == 'email_unavailable') return 'Email sign-in isn’t available right now.';
    if (e.statusCode == 400) return 'Enter a valid email address.';
    return 'Couldn’t send the code — try again.';
  }

  void _begin() {
    _busy = true;
    _error = null;
    _notify();
  }

  void _end() {
    _busy = false;
    _notify();
  }

  void _resetEmail() {
    _codeSent = false;
    _pendingEmail = null;
  }
}

/// Thrown by a provider credential function when the user dismissed the native sign-in sheet. The
/// controller treats it as a silent cancel — no error is surfaced.
class SocialSignInCanceled implements Exception {
  const SocialSignInCanceled();
}

/// Thrown when a social provider isn't usable on this build — the entitlement / OAuth client isn't
/// configured, or the platform doesn't support it. The controller steers the user to email.
class SocialSignInUnavailable implements Exception {
  const SocialSignInUnavailable();
}
