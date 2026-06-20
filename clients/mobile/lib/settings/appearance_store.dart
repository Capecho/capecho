import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// [AppearanceStore] backed by the same flutter_secure_storage the session token uses. Appearance is a
/// non-secret, per-device preference — it's stored here only to reuse a persistence backend the app
/// already ships (rather than add a plugin for one value), kept device-local (no iCloud sync / backup,
/// like the token) and defaulting to System when unset.
class SecureAppearanceStore implements AppearanceStore {
  SecureAppearanceStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
          );

  final FlutterSecureStorage _storage;

  static const _key = 'capecho.appearance.theme_mode';

  @override
  Future<ThemeMode> read() async => themeModeFromString(await _storage.read(key: _key));

  @override
  Future<void> write(ThemeMode mode) => _storage.write(key: _key, value: themeModeToString(mode));
}
