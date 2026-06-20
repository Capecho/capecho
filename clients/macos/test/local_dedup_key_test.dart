import 'dart:convert';
import 'dart:io';

import 'package:capecho/capture_repository.dart';
import 'package:flutter_test/flutter_test.dart';

// Parity: localDedupKey MUST reproduce the shared dedup-key vectors (the TS server `dedupKey` asserts the
// same JSON), so the offline dedup key can't silently drift from the server's. NFC-stable cases only —
// the client omits NFC (Dart has no native NFC); the server applies it + re-keys authoritatively on sync.
// Same drift-guard pattern as junk_gate_vectors.json. NOT a lemmatizer: `saw`/`studied` stay distinct.
void main() {
  test('localDedupKey matches the shared cross-port parity fixture', () {
    final path = [
      '../../shared/capture-core/test/fixtures/dedup_key_vectors.json', // cwd = clients/macos (flutter test)
      'shared/capture-core/test/fixtures/dedup_key_vectors.json', // cwd = repo root
    ].firstWhere((p) => File(p).existsSync(), orElse: () => '');
    expect(
      path,
      isNotEmpty,
      reason: 'dedup_key_vectors.json not found (cwd=${Directory.current.path})',
    );

    final data = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    final cases = (data['cases'] as List).cast<Map<String, dynamic>>();
    expect(cases, isNotEmpty);
    for (final c in cases) {
      expect(localDedupKey(c['in'] as String), c['out'], reason: 'in="${c['in']}"');
    }
  });
}
