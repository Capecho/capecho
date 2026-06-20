/// Persists the bearer session token across launches. An interface so [AuthController] is testable
/// with an in-memory fake and the concrete store is per-platform: a file in the sandboxed Application
/// Support container on macOS (`FileSessionStore`), the Keychain / EncryptedSharedPreferences on
/// mobile (`SecureSessionStore`).
///
/// Only the opaque token is stored — the account is re-fetched via `GET /auth/me` on restore — so
/// there is no PII at rest beyond the token, and a token the server has since revoked/expired simply
/// fails the restore (and is cleared).
abstract class SessionStore {
  Future<String?> loadToken();
  Future<void> saveToken(String token);
  Future<void> clear();
}
