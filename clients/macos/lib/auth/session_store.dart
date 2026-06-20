import 'dart:io';

import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:path_provider/path_provider.dart';

// The [SessionStore] interface moved to capecho_app_core (the mobile client implements it over the
// Keychain). The macOS file-backed impl below stays here — it's platform-specific.
export 'package:capecho_app_core/capecho_app_core.dart' show SessionStore;

/// File-backed [SessionStore] in the app's sandboxed Application Support container (co-located with
/// the local store + capture journal). No new native plugin, so the macOS app stays SwiftPM.
///
/// TODO(M3-hardening): move the token to the macOS Keychain. Deferred because `flutter_secure_storage`'s
/// macOS variant lacks Swift Package Manager support and would drag CocoaPods back in (the rest of the
/// app — incl. the Apple/Google sign-in plugins — is SwiftPM-pure); revisit with a SwiftPM-native
/// keychain wrapper. The container is per-app and OS-protected, which is acceptable until then.
class FileSessionStore implements SessionStore {
  FileSessionStore(this._file);

  final File _file;

  static Future<FileSessionStore> open() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/Capecho');
    await dir.create(recursive: true);
    return FileSessionStore(File('${dir.path}/session.token'));
  }

  @override
  Future<String?> loadToken() async {
    if (!await _file.exists()) return null;
    final t = (await _file.readAsString()).trim();
    return t.isEmpty ? null : t;
  }

  @override
  Future<void> saveToken(String token) => _file.writeAsString(token, flush: true);

  @override
  Future<void> clear() async {
    if (await _file.exists()) await _file.delete();
  }
}
