import 'dart:convert';
import 'dart:io';

import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:path_provider/path_provider.dart';

// The language-prefs controller + persistence seam live in capecho_app_core (shared with mobile). This
// file supplies the macOS file-backed store; consumers import the controller + seam from capecho_app_core.

/// File-backed [LanguagePrefsStore] in the app's sandboxed Application Support container (next to
/// `appearance`, `session.token` + the local store). The signed-out capture language choice is a
/// per-device default (the account takes over once signed in), so it lives on disk here rather than on
/// the account. path_provider only — no new plugin, so the macOS app stays SwiftPM-pure (same reasoning
/// as [FileAppearanceStore] / [FileSessionStore]).
class FileLanguagePrefsStore implements LanguagePrefsStore {
  FileLanguagePrefsStore(this._file, {LanguagePrefs? defaultPrefs})
    : _default = defaultPrefs ?? LanguagePrefs.fallback;

  final File _file;

  /// Returned when nothing has been saved yet — seeded from the OS locale by the caller (main.dart) so
  /// a fresh install lands on the user's native (explanation) language with zero config (Lane C). Falls
  /// back to English when the caller passes none.
  final LanguagePrefs _default;

  static Future<FileLanguagePrefsStore> open({LanguagePrefs? defaultPrefs}) async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/Capecho');
    await dir.create(recursive: true);
    return FileLanguagePrefsStore(File('${dir.path}/language'), defaultPrefs: defaultPrefs);
  }

  @override
  Future<LanguagePrefs> read() async {
    if (!await _file.exists()) return _default; // first run → the locale-seeded default
    final raw = jsonDecode(await _file.readAsString());
    if (raw is! Map) return _default;
    final learning = raw['learning'];
    final explanation = raw['explanation'];
    final follows = raw['follows'];
    return LanguagePrefs(
      learningLanguage: learning is String && learning.isNotEmpty
          ? learning
          : _default.learningLanguage,
      explanationLanguage: explanation is String && explanation.isNotEmpty
          ? explanation
          : _default.explanationLanguage,
      explanationFollowsLearning: follows is bool ? follows : false,
    );
  }

  @override
  Future<void> write(LanguagePrefs prefs) => _file.writeAsString(
    jsonEncode({
      'learning': prefs.learningLanguage,
      'explanation': prefs.explanationLanguage,
      'follows': prefs.explanationFollowsLearning,
    }),
    flush: true,
  );
}
