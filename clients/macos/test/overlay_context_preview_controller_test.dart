import 'dart:convert';

import 'package:capecho/overlay_context_preview_controller.dart';
import 'package:capecho_api/capecho_api.dart';
import 'package:capture_native/capture_native.dart';
import 'package:flutter_test/flutter_test.dart';

/// A `CaptureNative` that records the in-context preview pushes instead of crossing the method channel.
class _FakeCapture extends CaptureNative {
  final List<Map<String, Object?>> calls = [];
  @override
  Future<void> updateOverlayContextPreview({required String phase, String? meaning}) async {
    calls.add({'phase': phase, 'meaning': ?meaning});
  }
}

class _Net implements Exception {
  const _Net();
}

class _FakeTransport implements HttpTransport {
  _FakeTransport({
    this.statusCode = 200,
    this.body = const <String, Object?>{},
    this.delayMs = 0,
    this.throws = false,
  });
  final int statusCode;
  final Object body;
  final int delayMs; // delay so a later request can supersede an earlier one
  final bool throws;
  int sends = 0;
  final List<Map<String, Object?>> sentBodies = [];
  @override
  Future<TransportResponse> send(TransportRequest r) async {
    sends++;
    if (r.body != null) sentBodies.add((jsonDecode(r.body!) as Map).cast<String, Object?>());
    if (delayMs > 0) await Future<void>.delayed(Duration(milliseconds: delayMs));
    if (throws) throw const _Net();
    return TransportResponse(
      statusCode: statusCode,
      body: body is String ? body as String : jsonEncode(body),
    );
  }
}

OverlayContextPreviewController _controller(_FakeCapture cap, _FakeTransport t) =>
    OverlayContextPreviewController(
      api: CapechoApi(baseUrl: 'https://api.test', transport: t),
      capture: cap,
    );

Map<String, Object?> _ready(String meaning) => {
  'status': 'ready',
  'meaning': meaning,
  'previewHandle': 'h1',
  'charged': true,
};

void main() {
  test('a ready preview pushes the combined in-context gloss', () async {
    final cap = _FakeCapture();
    final c = _controller(
      cap,
      _FakeTransport(body: _ready('Here cell is the smallest unit of life; the cell divides.')),
    );
    await c.previewFor(unit: 'cell', contextText: 'The cell divides.', targetLanguage: 'en');
    expect(cap.calls, [
      {'phase': 'ready', 'meaning': 'Here cell is the smallest unit of life; the cell divides.'},
    ]);
  });

  test('forwards the native-computed span + context-language axes onto the wire', () async {
    final cap = _FakeCapture();
    final t = _FakeTransport(body: _ready('这里 学习 指学新知识；我们今天在学新词。'));
    final c = _controller(cap, t);
    await c.previewFor(
      unit: '学习',
      contextText: '我们今天学习新词。',
      targetLanguage: 'zh-Hans',
      explanationLanguage: 'en',
      contextLanguage: 'zh-Hans',
      spanStart: 4,
      spanEnd: 6,
    );
    expect(t.sentBodies.single['context_language'], 'zh-Hans');
    expect(t.sentBodies.single['span_start'], 4);
    expect(t.sentBodies.single['span_end'], 6);
  });

  test('absent axes stay absent on the wire (unknown is unknown — never defaulted)', () async {
    final cap = _FakeCapture();
    final t = _FakeTransport(body: _ready('m'));
    final c = _controller(cap, t);
    await c.previewFor(unit: 'cell', contextText: 'The cell divides.', targetLanguage: 'en');
    expect(t.sentBodies.single.containsKey('context_language'), isFalse);
    expect(t.sentBodies.single.containsKey('span_start'), isFalse);
    expect(t.sentBodies.single.containsKey('span_end'), isFalse);
  });

  test('a 429 maps to the distinct quota state (its own calm treatment)', () async {
    final cap = _FakeCapture();
    final c = _controller(cap, _FakeTransport(statusCode: 429, body: {'error': 'quota_exhausted'}));
    await c.previewFor(unit: 'cell', contextText: 'The cell divides.', targetLanguage: 'en');
    expect(cap.calls, [
      {'phase': 'quota'},
    ]);
  });

  test('a 401 (signed out — the account-only endpoint) maps to the login prompt', () async {
    final cap = _FakeCapture();
    final c = _controller(cap, _FakeTransport(statusCode: 401, body: {'error': 'unauthorized'}));
    await c.previewFor(unit: 'cell', contextText: 'The cell divides.', targetLanguage: 'en');
    expect(cap.calls, [
      {'phase': 'login'},
    ]);
  });

  test('a non-auth, non-quota error (503 global budget / 5xx) maps to failed', () async {
    final cap = _FakeCapture();
    final c = _controller(
      cap,
      _FakeTransport(statusCode: 503, body: {'error': 'budget_exhausted'}),
    );
    await c.previewFor(unit: 'cell', contextText: 'The cell divides.', targetLanguage: 'en');
    expect(cap.calls, [
      {'phase': 'failed'},
    ]);
  });

  test('a transport throw maps to failed', () async {
    final cap = _FakeCapture();
    final c = _controller(cap, _FakeTransport(throws: true));
    await c.previewFor(unit: 'cell', contextText: 'The cell divides.', targetLanguage: 'en');
    expect(cap.calls, [
      {'phase': 'failed'},
    ]);
  });

  test('an empty unit or empty context skips the fetch entirely', () async {
    final cap = _FakeCapture();
    final t = _FakeTransport(body: _ready('m'));
    final c = _controller(cap, t);
    await c.previewFor(unit: '   ', contextText: 'The cell divides.', targetLanguage: 'en');
    await c.previewFor(unit: 'cell', contextText: '   ', targetLanguage: 'en');
    expect(cap.calls, isEmpty);
    expect(t.sends, 0); // never even spends a metered call
  });

  test('a superseded preview drops its result (no cross-capture contamination)', () async {
    final cap = _FakeCapture();
    // One controller, one (delayed) transport: request B starts before A resolves, so B wins and A's
    // resolved-but-superseded push is dropped.
    final c = _controller(cap, _FakeTransport(body: _ready('first'), delayMs: 40));
    final a = c.previewFor(unit: 'cell', contextText: 'The cell divides.', targetLanguage: 'en');
    final b = c.previewFor(unit: 'cell', contextText: 'The cell divides.', targetLanguage: 'en');
    await Future.wait([a, b]);
    expect(cap.calls, hasLength(1)); // only B's push survived
  });

  // Adopt-on-save: a successful preview remembers its paid handle so the host's post-save claim can
  // carry it (no recharge), scoped to the exact unit+sentence it was generated for.
  test('after a ready preview, the handle is adoptable for the SAME unit+sentence only', () async {
    final cap = _FakeCapture();
    final c = _controller(
      cap,
      _FakeTransport(body: _ready('Here cell is the unit of life; the cell divides.')),
    );
    expect(
      c.adoptableHandleFor(unit: 'cell', contextText: 'The cell divides.'),
      isNull,
    ); // none generated yet
    await c.previewFor(unit: 'cell', contextText: 'The cell divides.', targetLanguage: 'en');
    expect(c.adoptableHandleFor(unit: 'cell', contextText: 'The cell divides.'), 'h1');
    expect(
      c.adoptableHandleFor(unit: '  cell  ', contextText: 'The cell divides.'),
      'h1',
    ); // unit trimmed
    expect(
      c.adoptableHandleFor(unit: 'atom', contextText: 'The cell divides.'),
      isNull,
    ); // different word
    expect(
      c.adoptableHandleFor(unit: 'cell', contextText: 'A different sentence.'),
      isNull,
    ); // edited sentence
  });

  test(
    'a failed preview leaves NO adoptable handle (Save re-explains; never adopts a stale gloss)',
    () async {
      final cap = _FakeCapture();
      final c = _controller(
        cap,
        _FakeTransport(statusCode: 503, body: {'error': 'budget_exhausted'}),
      );
      await c.previewFor(unit: 'cell', contextText: 'The cell divides.', targetLanguage: 'en');
      expect(c.adoptableHandleFor(unit: 'cell', contextText: 'The cell divides.'), isNull);
    },
  );

  test(
    'a fresh preview for a new word replaces the slot (the prior word is no longer adoptable)',
    () async {
      final cap = _FakeCapture();
      final c = _controller(cap, _FakeTransport(body: _ready('m')));
      await c.previewFor(unit: 'cell', contextText: 'The cell divides.', targetLanguage: 'en');
      expect(c.adoptableHandleFor(unit: 'cell', contextText: 'The cell divides.'), 'h1');
      await c.previewFor(unit: 'atom', contextText: 'An atom is tiny.', targetLanguage: 'en');
      expect(
        c.adoptableHandleFor(unit: 'cell', contextText: 'The cell divides.'),
        isNull,
      ); // slot moved on
      expect(c.adoptableHandleFor(unit: 'atom', contextText: 'An atom is tiny.'), 'h1');
    },
  );

  // adoptableGlossFor mirrors the handle: the gloss TEXT is cached locally on Save so the (signed-out)
  // Word Book shows it without re-generating — scoped to the exact unit+sentence, gone on a miss/failure.
  test(
    'after a ready preview, the gloss TEXT is adoptable for the SAME unit+sentence only',
    () async {
      final cap = _FakeCapture();
      final c = _controller(
        cap,
        _FakeTransport(body: _ready('Here cell is the unit of life; the cell divides.')),
      );
      expect(c.adoptableGlossFor(unit: 'cell', contextText: 'The cell divides.'), isNull);
      await c.previewFor(unit: 'cell', contextText: 'The cell divides.', targetLanguage: 'en');
      expect(
        c.adoptableGlossFor(unit: 'cell', contextText: 'The cell divides.'),
        'Here cell is the unit of life; the cell divides.',
      );
      expect(
        c.adoptableGlossFor(unit: '  cell  ', contextText: 'The cell divides.'),
        'Here cell is the unit of life; the cell divides.',
      ); // unit trimmed
      expect(
        c.adoptableGlossFor(unit: 'atom', contextText: 'The cell divides.'),
        isNull,
      ); // other word
      expect(
        c.adoptableGlossFor(unit: 'cell', contextText: 'A different sentence.'),
        isNull,
      ); // edited sentence
    },
  );

  test('a failed preview leaves NO adoptable gloss text either', () async {
    final cap = _FakeCapture();
    final c = _controller(
      cap,
      _FakeTransport(statusCode: 503, body: {'error': 'budget_exhausted'}),
    );
    await c.previewFor(unit: 'cell', contextText: 'The cell divides.', targetLanguage: 'en');
    expect(c.adoptableGlossFor(unit: 'cell', contextText: 'The cell divides.'), isNull);
  });
}
