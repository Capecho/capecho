import 'dart:convert';
import 'dart:io';

import 'package:capture_native/capture_native.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

/// Opt-in capture diagnostic for tuning reconstruction (OFF by default).
///
/// When a sentinel file named `CAPTURE_DEBUG` exists in the Capecho support dir,
/// every capture appends one JSON line to `capture-debug.jsonl` — the raw
/// [OcrSnapshot] (every line's text + bounding box + the cursor) plus the
/// reconstructed word / sentence / context. The snapshot round-trips through
/// `OcrSnapshot.fromMap`, so a bad capture can be replayed offline as a unit test
/// against the exact geometry that produced it.
///
/// With NO sentinel the hook is never wired — zero overhead, nothing written. The
/// dump contains OCR'd on-screen text, so it is enabled deliberately by a
/// developer and the file removed afterwards.
///
/// IMPORTANT: the macOS app is sandboxed AND `path_provider` adds a bundle-id
/// subdir, so the support dir is NOT `~/Library/Application Support`. Enable +
/// locate the dump with:
///
///   D=$(dirname "$(find ~/Library/Containers/com.capecho.app -path '*/Capecho' -type d | head -1)")/Capecho
///   touch "$D/CAPTURE_DEBUG"      # then restart the app, reproduce, and read:
///   find ~/Library/Containers/com.capecho.app -name capture-debug.jsonl
abstract final class CaptureDebug {
  static const sentinelName = 'CAPTURE_DEBUG';
  static const outputName = 'capture-debug.jsonl';

  /// Wires [capture]'s debug hook to a JSONL writer WHEN the sentinel is present;
  /// no-op otherwise. Call once at startup. Returns the output path when enabled.
  static Future<String?> maybeEnable(CaptureNative capture) async {
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory('${supportDir.path}/Capecho');
    if (!File('${dir.path}/$sentinelName').existsSync()) return null;

    final out = File('${dir.path}/$outputName');
    debugPrint('[CaptureDebug] enabled → dumping captures to ${out.path}');
    capture.onDebugCapture = (snapshot, result) {
      try {
        final line = jsonEncode({
          'ts': DateTime.now().toIso8601String(),
          'word': result.word,
          'sentence': result.sentence,
          'context': result.context,
          'source': result.contextSource.name,
          'snapshot': snapshot.toMap(),
        });
        out.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
      } catch (_) {
        // A diagnostic must never break capture; swallow encode / write errors.
      }
    };
    return out.path;
  }
}
