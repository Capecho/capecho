import 'dart:convert';
import 'dart:io';

import 'package:capecho_capture_core/capecho_capture_core.dart';
import 'package:test/test.dart';

/// The SHARED gibberish-gate parity fixture (companion to junk_gate_vectors). The TS twin
/// (backend `input.test.ts`) asserts against the SAME vectors, so the two hand-ported
/// `isLikelyGibberish` implementations can't silently diverge.
Map<String, dynamic> _loadVectors(String name) {
  final candidates = [
    'test/fixtures/$name', // cwd = capture-core package root (the usual `dart test` cwd)
    'fixtures/$name',
    'shared/capture-core/test/fixtures/$name', // cwd = repo root
  ];
  for (final p in candidates) {
    final f = File(p);
    if (f.existsSync()) return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  }
  throw StateError('$name not found (cwd=${Directory.current.path})');
}

void main() {
  final vectors = _loadVectors('gibberish_vectors.json');
  final pass = (vectors['pass'] as List).cast<String>();
  final reject = (vectors['reject'] as List).cast<String>();

  // Same silent-failure guard as the junk gate: a gibberish gate that rejects a REAL word means the
  // word is never explained/saved. Every "pass" entry MUST pass (isLikelyGibberish == false).
  group('MUST pass — real units reach /explain', () {
    for (final u in pass) {
      test(
          'passes ${jsonEncode(u)}',
          () => expect(isLikelyGibberish(u), isFalse,
              reason: '${jsonEncode(u)} must reach /explain'));
    }
  });

  group('rejects single-token keyboard-mash / long repeats', () {
    for (final j in reject) {
      test('rejects ${jsonEncode(j)}', () => expect(isLikelyGibberish(j), isTrue));
    }
  });

  // The gibberish gate is STRICTER than the junk gate, so it must never reject a word the junk gate
  // already passes (else captures the junk fixture guarantees would silently start dropping).
  group('never flags a junk-gate pass word', () {
    final junkPass = (_loadVectors('junk_gate_vectors.json')['pass'] as List).cast<String>();
    for (final u in junkPass) {
      test('non-gibberish ${jsonEncode(u)}', () => expect(isLikelyGibberish(u), isFalse));
    }
  });

  test('trims before judging; phrases and non-Latin scripts pass', () {
    expect(isLikelyGibberish('  asdfg  '), isTrue); // a >=5-key walk, trimmed
    expect(isLikelyGibberish('asdf'), isFalse); // a bare 4-key walk defers to L3 (the >=5 floor)
    expect(isLikelyGibberish('   '), isFalse); // empty after trim → junk gate's job
    expect(isLikelyGibberish('the asdf'), isFalse); // a phrase is deferred to the LLM authority
    expect(isLikelyGibberish('学習'), isFalse);
  });
}
