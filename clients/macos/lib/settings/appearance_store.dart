import 'dart:io';

import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:path_provider/path_provider.dart';

// The appearance controller + persistence seam + the shared picker live in capecho_app_core (shared
// with mobile). This file supplies the macOS file-backed store below; consumers import the controller
// + seam directly from capecho_app_core.

/// File-backed [AppearanceStore] in the app's sandboxed Application Support container (next to
/// `session.token` + the local store). Appearance is a per-device preference, so it lives on disk here
/// rather than on the account. path_provider only — no new plugin, so the macOS app stays SwiftPM-pure
/// (same reasoning as [FileSessionStore]).
class FileAppearanceStore implements AppearanceStore {
  FileAppearanceStore(this._file);

  final File _file;

  static Future<FileAppearanceStore> open() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/Capecho');
    await dir.create(recursive: true);
    return FileAppearanceStore(File('${dir.path}/appearance'));
  }

  @override
  Future<ThemeMode> read() async {
    if (!await _file.exists()) return ThemeMode.system;
    return themeModeFromString((await _file.readAsString()).trim());
  }

  @override
  Future<void> write(ThemeMode mode) => _file.writeAsString(themeModeToString(mode), flush: true);
}
