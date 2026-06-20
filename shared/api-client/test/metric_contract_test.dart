import 'dart:convert';
import 'dart:io';

import 'package:capecho_api/capecho_api.dart';
import 'package:test/test.dart';

// The Dart metric contract must equal the committed fixture, which the TS validator also asserts
// against (backend/test/metric-contract.test.ts) — so a Dart↔TS drift fails CI (ENG-3 posture, same
// as the normalization golden vectors). cwd-tolerant fixture read (mirrors the normalization parity test).

Map<String, dynamic> _readFixture() {
  const candidates = <String>[
    'fixtures/metric-events-contract.json', // cwd = shared/api-client
    '../api-client/fixtures/metric-events-contract.json', // cwd = shared
    'shared/api-client/fixtures/metric-events-contract.json', // cwd = repo root
  ];
  for (final p in candidates) {
    final f = File(p);
    if (f.existsSync()) return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  }
  throw StateError('metric-events-contract.json not found (cwd=${Directory.current.path})');
}

void main() {
  final fx = _readFixture();

  test('the Dart metric contract matches the committed fixture (Dart↔TS parity anchor)', () {
    expect(kMetricContractVersion, fx['version']);
    expect(kMetricMaxDurationMs, fx['maxDurationMs']);

    final events = (fx['events'] as Map).cast<String, dynamic>();
    expect(kMetricEventContract.keys.toSet(), events.keys.toSet(), reason: 'event-type set');

    for (final entry in events.entries) {
      final type = entry.key;
      final spec = (entry.value as Map).cast<String, dynamic>();
      final dartSpec = kMetricEventContract[type]!;
      expect(dartSpec.needsClientRowId, spec['needsClientRowId'], reason: '$type.needsClientRowId');

      final fields = (spec['fields'] as Map).cast<String, dynamic>();
      expect(dartSpec.fields.keys.toSet(), fields.keys.toSet(), reason: '$type field set');
      for (final f in fields.entries) {
        final fj = (f.value as Map).cast<String, dynamic>();
        final df = dartSpec.fields[f.key]!;
        expect(df.type, fj['type'], reason: '$type.${f.key}.type');
        if (fj['type'] == 'int') {
          expect(df.min, fj['min'], reason: '$type.${f.key}.min');
          expect(df.max, fj['max'], reason: '$type.${f.key}.max');
        } else if (fj['type'] == 'enum') {
          expect(df.values, (fj['values'] as List).cast<String>(), reason: '$type.${f.key}.values');
        }
      }
    }
  });

  test('every MetricEventType enum value has a contract entry and vice versa', () {
    expect(MetricEventType.values.map((e) => e.wire).toSet(), kMetricEventContract.keys.toSet());
  });
}
