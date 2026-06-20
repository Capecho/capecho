import 'dart:convert';
import 'dart:io';

import 'package:capecho_capture_core/capecho_capture_core.dart';
import 'package:test/test.dart';

/// The SHARED junk-gate parity fixture. The TS authoritative twin
/// (backend `input.test.ts`) asserts against the SAME vectors, so the two hand-ported
/// `isLikelyJunk` implementations can't silently diverge — bug #1 (the over-broad `@`
/// reject) lived in both copies precisely because nothing tied them together.
Map<String, dynamic> _loadVectors() {
  const candidates = [
    'test/fixtures/junk_gate_vectors.json', // cwd = capture-core package root (the usual `dart test` cwd)
    'fixtures/junk_gate_vectors.json',
    'shared/capture-core/test/fixtures/junk_gate_vectors.json', // cwd = repo root
  ];
  for (final p in candidates) {
    final f = File(p);
    if (f.existsSync()) return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  }
  throw StateError('junk_gate_vectors.json not found (cwd=${Directory.current.path})');
}

void main() {
  final vectors = _loadVectors();
  final pass = (vectors['pass'] as List).cast<String>();
  final reject = (vectors['reject'] as List).cast<String>();

  // The ONE silent-failure mode: a junk gate that rejects a REAL word means the
  // word is never explained/saved. Every "pass" entry MUST pass (isLikelyJunk == false). If you
  // tighten the filter and one flips, you've reintroduced the silent failure — and broken parity with
  // the server twin, which asserts the same fixture.
  group('MUST pass — real units reach /explain', () {
    for (final u in pass) {
      test('passes ${jsonEncode(u)}',
          () => expect(isLikelyJunk(u), isFalse, reason: '${jsonEncode(u)} must reach /explain'));
    }
  });

  group('rejects true degenerate junk only', () {
    for (final j in reject) {
      test('rejects ${jsonEncode(j)}', () => expect(isLikelyJunk(j), isTrue));
    }
  });

  test('trims before judging', () {
    expect(isLikelyJunk('  serendipity  '), isFalse);
    expect(isLikelyJunk('   学习 '), isFalse);
    expect(isLikelyJunk('   '), isTrue);
  });
}
