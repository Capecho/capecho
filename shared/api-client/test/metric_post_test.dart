import 'dart:convert';

import 'package:capecho_api/capecho_api.dart';
import 'package:test/test.dart';

class _FakeTransport implements HttpTransport {
  final List<TransportRequest> requests = [];
  TransportResponse next =
      const TransportResponse(statusCode: 200, body: '{"accepted":2,"dropped":1}');
  @override
  Future<TransportResponse> send(TransportRequest request) async {
    requests.add(request);
    return next;
  }
}

void main() {
  test('MetricEvent toJson omits a null clientRowId and round-trips', () {
    const e = MetricEvent(
        eventType: 'capture_presented',
        clientTs: 5,
        metadata: const {'selToPanelMs': 90, 'source': 'ocr'});
    final j = e.toJson();
    expect(j.containsKey('clientRowId'), isFalse);
    final back = MetricEvent.fromJson(j);
    expect(back.eventType, 'capture_presented');
    expect(back.clientTs, 5);
    expect(back.metadata['selToPanelMs'], 90);
  });

  test('postMetrics POSTs the batch envelope and parses accepted/dropped', () async {
    final t = _FakeTransport();
    final api = CapechoApi(baseUrl: 'https://api.capecho.test', transport: t);
    final res = await api.postMetrics(const MetricBatch(
      installId: 'inst-1',
      appVersion: '0.29',
      events: [
        MetricEvent(eventType: 'sync_attempted', clientRowId: 'r1', clientTs: 1, metadata: {})
      ],
    ));
    expect(res.accepted, 2);
    expect(res.dropped, 1);

    final req = t.requests.single;
    expect(req.method, 'POST');
    expect(req.url, endsWith('/metrics'));
    final body = jsonDecode(req.body!) as Map<String, dynamic>;
    expect(body['installId'], 'inst-1');
    expect(body['platform'], 'macos');
    expect(body['appVersion'], '0.29');
    expect(body['contractVersion'], kMetricContractVersion);
    expect((body['events'] as List).single['eventType'], 'sync_attempted');
  });

  test('postMetrics sends anonymously when no session is held (no Authorization header)', () async {
    final t = _FakeTransport();
    final api = CapechoApi(baseUrl: 'https://api.capecho.test', transport: t);
    await api.postMetrics(const MetricBatch(installId: 'inst', events: [
      MetricEvent(eventType: 'capture_abandoned', clientTs: 1, metadata: {'selToPanelMs': 10}),
    ]));
    expect(t.requests.single.headers.containsKey('authorization'), isFalse);
  });

  test('postMetrics attaches the bearer when a session is held', () async {
    final t = _FakeTransport();
    final api = CapechoApi(baseUrl: 'https://api.capecho.test', transport: t)
      ..restoreToken('tok-9');
    await api.postMetrics(const MetricBatch(installId: 'inst', events: [
      MetricEvent(eventType: 'capture_abandoned', clientTs: 1, metadata: {'selToPanelMs': 10}),
    ]));
    expect(t.requests.single.headers['authorization'], 'Bearer tok-9');
  });
}
