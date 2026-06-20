import 'dart:async';
import 'dart:convert';

import 'package:capecho/metrics_recorder.dart';
import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_local_store/capecho_local_store.dart';
import 'package:capture_native/capture_native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records POST /metrics requests; scriptable status/body, or a simulated offline throw.
class _FakeTransport implements HttpTransport {
  final List<TransportRequest> posts = [];
  int status = 200;
  String body = '{"accepted":1,"dropped":0}';
  bool offline = false;
  void Function()? onSend; // fires at the start of each send (to inject mid-flush state)

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    onSend?.call();
    if (offline) throw StateError('offline');
    posts.add(request);
    return TransportResponse(statusCode: status, body: body);
  }
}

String _norm(String u) => u.trim().toLowerCase();

void main() {
  late _FakeTransport transport;
  late CapechoApi api;
  late LocalStore store;
  late StreamController<CaptureLifecycleEvent> lifecycle;
  late MetricsRecorder recorder;

  setUp(() {
    transport = _FakeTransport();
    api = CapechoApi(baseUrl: 'https://api.capecho.test', transport: transport);
    store = LocalStore.openInMemory(normalizer: _norm, normalizationVersion: 'test');
    lifecycle = StreamController<CaptureLifecycleEvent>.broadcast();
    recorder = MetricsRecorder(
      lifecycle: lifecycle.stream,
      store: store,
      api: api,
      installId: 'inst-1',
      appVersion: '0.29',
      clock: () => 1234,
    );
    recorder.start();
  });

  tearDown(() async {
    await recorder.dispose();
    await lifecycle.close();
    store.close();
  });

  test(
    'capture_completed is word-id-keyed: timings (lifecycle) join the drain word id (T17)',
    () async {
      // The 'completed' lifecycle carries the journal clientRowId + timings; alone it does NOT emit —
      // the event is deferred until the local-store drain assigns the word id.
      lifecycle.add(
        const CaptureLifecycleEvent(
          phase: 'completed',
          clientRowId: 'journal-1',
          selToPanelMs: 120,
          panelToSaveMs: 3400,
          totalMs: 3520,
          source: 'ocr',
          hasContext: true,
          langOverride: false,
        ),
      );
      await pumpEventQueue();
      expect(transport.posts, isEmpty); // deferred — no word id yet

      // The drain reports (journal id → word id); the halves join and emit, keyed by the WORD id.
      recorder.onCaptureDrained([(clientRowId: 'journal-1', wordId: 'word-1')]);
      await pumpEventQueue();

      expect(transport.posts, hasLength(1));
      final body = jsonDecode(transport.posts.single.body!) as Map<String, dynamic>;
      final event = (body['events'] as List).single as Map<String, dynamic>;
      expect(event['eventType'], 'capture_completed');
      expect(event['clientRowId'], 'word-1'); // the WORD id, not the journal id 'journal-1'
      expect((event['metadata'] as Map).cast<String, Object?>(), {
        'selToPanelMs': 120,
        'panelToSaveMs': 3400,
        'totalMs': 3520,
        'source': 'ocr',
        'hasContext': true,
        'langOverride': false,
      });
      expect(store.metricBatch(10), isEmpty); // drained after a successful flush
    },
  );

  test('the join works drain-first too: the word id can arrive before the timings (T17)', () async {
    recorder.onCaptureDrained([(clientRowId: 'journal-2', wordId: 'word-2')]);
    await pumpEventQueue();
    expect(transport.posts, isEmpty); // no timings yet

    lifecycle.add(
      const CaptureLifecycleEvent(
        phase: 'completed',
        clientRowId: 'journal-2',
        selToPanelMs: 1,
        panelToSaveMs: 2,
        totalMs: 3,
        source: 'clipboard',
        hasContext: false,
        langOverride: true,
      ),
    );
    await pumpEventQueue();
    final event =
        ((jsonDecode(transport.posts.single.body!) as Map<String, dynamic>)['events'] as List)
                .single
            as Map<String, dynamic>;
    expect(event['eventType'], 'capture_completed');
    expect(event['clientRowId'], 'word-2');
  });

  test(
    'an unjoined completed half never emits (orphan; e.g. a normalized-empty save — T17)',
    () async {
      lifecycle.add(
        const CaptureLifecycleEvent(
          phase: 'completed',
          clientRowId: 'journal-orphan',
          selToPanelMs: 1,
          panelToSaveMs: 2,
          totalMs: 3,
          source: 'ocr',
          hasContext: true,
          langOverride: false,
        ),
      );
      // A different journal id drains (the orphan produced no word) → no pair completes for either.
      recorder.onCaptureDrained([(clientRowId: 'journal-other', wordId: 'word-other')]);
      await pumpEventQueue();
      expect(transport.posts, isEmpty);
      expect(store.metricBatch(10), isEmpty);
    },
  );

  test('an offline flush keeps the event buffered; a later flush sends it', () async {
    transport.offline = true;
    lifecycle.add(const CaptureLifecycleEvent(phase: 'abandoned', selToPanelMs: 90));
    await pumpEventQueue();
    expect(transport.posts, isEmpty);
    expect(store.metricBatch(10), hasLength(1)); // kept for retry

    transport.offline = false;
    await recorder.flush();
    expect(transport.posts, hasLength(1));
    expect(store.metricBatch(10), isEmpty);
  });

  test('a server 4xx drops the batch (no wedge); a 5xx keeps it for retry', () async {
    transport.status = 400;
    transport.body = '{"error":"bad_event"}';
    lifecycle.add(const CaptureLifecycleEvent(phase: 'abandoned', selToPanelMs: 50));
    await pumpEventQueue();
    expect(store.metricBatch(10), isEmpty); // non-retryable → dropped

    transport.status = 503;
    transport.body = '{"error":"unavailable"}';
    lifecycle.add(const CaptureLifecycleEvent(phase: 'abandoned', selToPanelMs: 60));
    await pumpEventQueue();
    expect(store.metricBatch(10), hasLength(1)); // retryable → kept
  });

  test('a completed missing a required field is dropped (never enqueued or sent)', () async {
    // No clientRowId → contract-invalid → drop rather than wedge a flush batch.
    lifecycle.add(
      const CaptureLifecycleEvent(
        phase: 'completed',
        selToPanelMs: 1,
        panelToSaveMs: 1,
        totalMs: 1,
        source: 'ocr',
        hasContext: true,
        langOverride: false,
      ),
    );
    await pumpEventQueue();
    expect(store.metricBatch(10), isEmpty);
    expect(transport.posts, isEmpty);
  });

  test('every posted metadata key is within the contract (no captured text — T8)', () async {
    lifecycle.add(
      const CaptureLifecycleEvent(
        phase: 'completed',
        clientRowId: 'r',
        selToPanelMs: 1,
        panelToSaveMs: 2,
        totalMs: 3,
        source: 'clipboard',
        hasContext: false,
        langOverride: true,
      ),
    );
    recorder.onCaptureDrained([(clientRowId: 'r', wordId: 'rw')]); // join → emit
    await pumpEventQueue();
    final body = jsonDecode(transport.posts.single.body!) as Map<String, dynamic>;
    final event = (body['events'] as List).single as Map<String, dynamic>;
    final allowed = kMetricEventContract['capture_completed']!.fields.keys.toSet();
    expect((event['metadata'] as Map).keys.toSet(), allowed);
  });

  test('recordSyncAttempted / recordSyncAccepted emit one event per client_row_id', () async {
    recorder.recordSyncAttempted(['r1', 'r2']);
    await pumpEventQueue();
    final events =
        ((jsonDecode(transport.posts.single.body!) as Map<String, dynamic>)['events'] as List)
            .cast<Map<String, dynamic>>();
    expect(events.map((e) => e['eventType']).toList(), ['sync_attempted', 'sync_attempted']);
    expect(events.map((e) => e['clientRowId']).toList(), ['r1', 'r2']);

    transport.posts.clear();
    recorder.recordSyncAccepted(['r1']);
    await pumpEventQueue();
    final accepted =
        (jsonDecode(transport.posts.single.body!) as Map<String, dynamic>)['events'] as List;
    expect((accepted.single as Map)['eventType'], 'sync_accepted');
  });

  test('recordCaptureFailed emits capture_failed with the error kind', () async {
    recorder.recordCaptureFailed('unknown');
    await pumpEventQueue();
    final event =
        ((jsonDecode(transport.posts.single.body!) as Map<String, dynamic>)['events'] as List)
                .single
            as Map<String, dynamic>;
    expect(event['eventType'], 'capture_failed');
    expect((event['metadata'] as Map)['errorKind'], 'unknown');
  });

  test('an empty sync list emits nothing', () async {
    recorder.recordSyncAttempted(const []);
    await pumpEventQueue();
    expect(transport.posts, isEmpty);
  });

  test(
    'an event buffered DURING an in-flight flush is drained the same round (no lost wakeup, P1)',
    () async {
      // Simulate a capture landing while the first POST is in flight: its own flush() is dropped by the
      // _flushing guard, so the running flush must re-read and pick it up — not return on a short batch.
      var injected = false;
      transport.onSend = () {
        if (injected) return;
        injected = true;
        store.enqueueMetric(
          jsonEncode({
            'eventType': 'capture_abandoned',
            'clientTs': 1,
            'metadata': {'selToPanelMs': 70},
          }),
          now: 2,
        );
      };
      lifecycle.add(const CaptureLifecycleEvent(phase: 'abandoned', selToPanelMs: 50));
      await pumpEventQueue();
      expect(store.metricBatch(10), isEmpty); // the injected event was NOT stranded
      expect(transport.posts.length, 2); // abandoned, then the injected event
    },
  );

  test('a corrupt buffered payload is dropped, not wedged (review P2)', () async {
    store.enqueueMetric('this is not json', now: 1); // a poison row the recorder would never write
    lifecycle.add(const CaptureLifecycleEvent(phase: 'abandoned', selToPanelMs: 50));
    await pumpEventQueue();
    expect(store.metricBatch(10), isEmpty); // poison + valid both cleared — no wedge
    final posted =
        (jsonDecode(transport.posts.single.body!) as Map<String, dynamic>)['events'] as List;
    expect(
      (posted.single as Map)['eventType'],
      'capture_abandoned',
    ); // the valid event still got through
  });
}
