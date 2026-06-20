import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Whether a capture records its source app + window title ("where I met this word"). Device-local
/// (macOS only — capture is desktop), default ON. Read per-capture so toggling it off in Settings
/// stops the next capture from carrying the source; existing saved sources are untouched.
class CaptureSourceController extends ChangeNotifier {
  CaptureSourceController({CaptureSourceStore? store})
    : _store = store ?? _InMemoryCaptureSourceStore();

  final CaptureSourceStore _store;
  bool _enabled = true;

  bool get enabled => _enabled;

  Future<void> load() async {
    _enabled = await _store.read();
    notifyListeners();
  }

  void setEnabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    notifyListeners();
    unawaited(_store.write(value));
  }
}

abstract interface class CaptureSourceStore {
  Future<bool> read();
  Future<void> write(bool enabled);
}

class _InMemoryCaptureSourceStore implements CaptureSourceStore {
  bool _enabled = true;

  @override
  Future<bool> read() async => _enabled;

  @override
  Future<void> write(bool enabled) async => _enabled = enabled;
}

/// On-disk flag under `{ApplicationSupport}/Capecho/capture-source` ('1'/'0'). path_provider only
/// (SwiftPM-pure), mirroring the appearance + language stores.
class FileCaptureSourceStore implements CaptureSourceStore {
  FileCaptureSourceStore(this._file);

  final File _file;

  static Future<FileCaptureSourceStore> open() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/Capecho');
    await dir.create(recursive: true);
    return FileCaptureSourceStore(File('${dir.path}/capture-source'));
  }

  @override
  Future<bool> read() async {
    if (!await _file.exists()) return true;
    return (await _file.readAsString()).trim() != '0';
  }

  @override
  Future<void> write(bool enabled) => _file.writeAsString(enabled ? '1' : '0', flush: true);
}
