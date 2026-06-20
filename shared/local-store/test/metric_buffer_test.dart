import 'dart:io';

import 'package:capecho_local_store/capecho_local_store.dart';
import 'package:test/test.dart';

String stubNormalizer(String u) => u.trim().toLowerCase();
const kVersion = 'test-v';

void main() {
  group('metric buffer', () {
    late LocalStore store;
    setUp(() => store =
        LocalStore.openInMemory(normalizer: stubNormalizer, normalizationVersion: kVersion));
    tearDown(() => store.close());

    test('enqueue → FIFO batch → delete-through drains the queue', () {
      store.enqueueMetric('{"e":1}', now: 1);
      store.enqueueMetric('{"e":2}', now: 2);
      store.enqueueMetric('{"e":3}', now: 3);
      final batch = store.metricBatch(2);
      expect(batch.map((r) => r.payload).toList(), ['{"e":1}', '{"e":2}']); // oldest first
      store.deleteMetricsThrough(batch.last.seq);
      expect(store.metricBatch(10).map((r) => r.payload).toList(), ['{"e":3}']);
    });

    test('the bounded buffer drops the OLDEST past the cap and counts the drop', () {
      for (var i = 0; i < kMaxMetricBuffer + 5; i++) {
        store.enqueueMetric('{"i":$i}', now: i);
      }
      expect(store.metricBatch(kMaxMetricBuffer + 100), hasLength(kMaxMetricBuffer));
      expect(store.metricDroppedCount(), 5);
      expect(store.metricBatch(1).single.payload, '{"i":5}'); // 0..4 evicted, 5 is now oldest
    });

    test('an empty buffer yields an empty batch and zero drops', () {
      expect(store.metricBatch(10), isEmpty);
      expect(store.metricDroppedCount(), 0);
    });
  });

  test('the buffer is durable across reopen (offline survival across a restart)', () {
    final dir = Directory.systemTemp.createTempSync('capecho-mbuf');
    final path = '${dir.path}/s.db';
    final s1 =
        LocalStore.open(path: path, normalizer: stubNormalizer, normalizationVersion: kVersion);
    s1.enqueueMetric('{"persist":true}', now: 1);
    s1.close();
    final s2 =
        LocalStore.open(path: path, normalizer: stubNormalizer, normalizationVersion: kVersion);
    expect(s2.metricBatch(10).single.payload, '{"persist":true}');
    s2.close();
    dir.deleteSync(recursive: true);
  });
}
