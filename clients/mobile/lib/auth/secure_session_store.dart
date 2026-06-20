import 'dart:math';

import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The mobile [SessionStore]: the bearer token at rest in the iOS Keychain / Android
/// EncryptedSharedPreferences (vs the macOS file-backed store, which stays SwiftPM-pure). Only the
/// opaque token lives here — the account is re-fetched via `GET /auth/me` on restore — so a revoked
/// token simply fails the restore and is cleared.
class SecureSessionStore implements SessionStore {
  SecureSessionStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // Android (v10+) stores secrets under custom ciphers by default — the deprecated
            // encryptedSharedPreferences flag is gone; existing data migrates on first access.
            // Keep the bearer token device-local: readable after first unlock, but NOT synced to
            // iCloud Keychain and excluded from encrypted device backups. (The plugin default,
            // kSecAttrAccessibleWhenUnlocked, is iCloud-synced + backed up — a long-lived credential
            // shouldn't leave the device.)
            iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
          );

  final FlutterSecureStorage _storage;

  static const _tokenKey = 'capecho.session.token';
  static const _installIdKey = 'capecho.install.id';

  @override
  Future<String?> loadToken() async {
    final t = await _storage.read(key: _tokenKey);
    return (t == null || t.isEmpty) ? null : t;
  }

  @override
  Future<void> saveToken(String token) => _storage.write(key: _tokenKey, value: token);

  @override
  Future<void> clear() => _storage.delete(key: _tokenKey);

  /// A stable per-install id (the claim idempotency key). Mobile has no local captures to claim at
  /// MVP — but [AuthController] requires the seam, and the metrics/claim paths will use it later — so
  /// generate-and-persist a random id on first read rather than threading a placeholder.
  Future<String> installId() async {
    final existing = await _storage.read(key: _installIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = _randomHex(16);
    await _storage.write(key: _installIdKey, value: id);
    return id;
  }

  static String _randomHex(int bytes) {
    final r = Random.secure();
    return List<int>.generate(
      bytes,
      (_) => r.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
