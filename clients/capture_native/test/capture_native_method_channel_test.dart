import 'package:capture_native/capture_native_method_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final MethodChannelCaptureNative platform = MethodChannelCaptureNative();
  const MethodChannel channel = MethodChannel('capture_native');

  final List<MethodCall> calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        calls.add(methodCall);
        switch (methodCall.method) {
          case 'hasScreenRecordingPermission':
          case 'requestScreenRecordingPermission':
          case 'requestNotificationPermission':
            return true;
          default:
            return null;
        }
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
  });

  test('triggerCapture invokes the triggerCapture method', () async {
    await platform.triggerCapture();
    expect(calls.single.method, 'triggerCapture');
  });

  test('hideWindow invokes the hideWindow method', () async {
    await platform.hideWindow();
    expect(calls.single.method, 'hideWindow');
  });

  test('requestOnboarding invokes the requestOnboarding method', () async {
    await platform.requestOnboarding();
    expect(calls.single.method, 'requestOnboarding');
  });

  test('permission queries invoke their methods and coerce to bool', () async {
    expect(await platform.hasScreenRecordingPermission(), isTrue);
    expect(await platform.requestScreenRecordingPermission(), isTrue);
    expect(
      calls.map((c) => c.method),
      containsAll(['hasScreenRecordingPermission', 'requestScreenRecordingPermission']),
    );
  });

  test('requestNotificationPermission invokes its method and coerces to bool', () async {
    expect(await platform.requestNotificationPermission(), isTrue);
    expect(calls.single.method, 'requestNotificationPermission');
  });

  test('scheduleDailyReminder forwards hour/minute/title/body', () async {
    await platform.scheduleDailyReminder(
      hour: 20,
      minute: 0,
      title: 'Time to review',
      body: 'A few of your words are ready.',
    );
    expect(calls.single.method, 'scheduleDailyReminder');
    expect(calls.single.arguments, {
      'hour': 20,
      'minute': 0,
      'title': 'Time to review',
      'body': 'A few of your words are ready.',
    });
  });

  test('cancelReminder invokes the cancelReminder method', () async {
    await platform.cancelReminder();
    expect(calls.single.method, 'cancelReminder');
  });

  test('showImmediateNotification forwards title/body', () async {
    await platform.showImmediateNotification(title: 'Reminders on', body: 'See you at 20:00');
    expect(calls.single.method, 'showImmediateNotification');
    expect(calls.single.arguments, {'title': 'Reminders on', 'body': 'See you at 20:00'});
  });

  test('an incoming showSurface call surfaces the requested surface name', () async {
    final future = platform.showSurfaceRequests.first;
    const codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'capture_native',
      codec.encodeMethodCall(const MethodCall('showSurface', 'wordBook')),
      (_) {},
    );
    expect(await future, 'wordBook');
  });

  test(
    'an empty / null / non-String showSurface payload is ignored (no stream event, no throw)',
    () async {
      var emitted = false;
      final sub = platform.showSurfaceRequests.listen((_) => emitted = true);
      const codec = StandardMethodCodec();
      for (final Object? bad in <Object?>['', null, 42]) {
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              'capture_native',
              codec.encodeMethodCall(MethodCall('showSurface', bad)),
              (_) {},
            );
      }
      await Future<void>.delayed(Duration.zero);
      expect(emitted, isFalse);
      await sub.cancel();
    },
  );

  test('an incoming onCaptureLifecycle (completed) surfaces a fully-populated event', () async {
    final future = platform.captureLifecycle.first;
    const codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'capture_native',
      codec.encodeMethodCall(
        const MethodCall('onCaptureLifecycle', {
          'phase': 'completed',
          'clientRowId': 'crid-9',
          'selToPanelMs': 120,
          'panelToSaveMs': 3400,
          'totalMs': 3520,
          'source': 'ocr',
          'hasContext': true,
          'langOverride': false,
        }),
      ),
      (_) {},
    );
    final e = await future;
    expect(e.phase, 'completed');
    expect(e.clientRowId, 'crid-9');
    expect(e.selToPanelMs, 120);
    expect(e.panelToSaveMs, 3400);
    expect(e.totalMs, 3520);
    expect(e.source, 'ocr');
    expect(e.hasContext, isTrue);
    expect(e.langOverride, isFalse);
  });

  test('a presented lifecycle carries only its phase fields (others null)', () async {
    final future = platform.captureLifecycle.first;
    const codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'capture_native',
      codec.encodeMethodCall(
        const MethodCall('onCaptureLifecycle', {
          'phase': 'presented',
          'selToPanelMs': 90,
          'source': 'clipboard',
        }),
      ),
      (_) {},
    );
    final e = await future;
    expect(e.phase, 'presented');
    expect(e.selToPanelMs, 90);
    expect(e.source, 'clipboard');
    expect(e.totalMs, isNull);
    expect(e.clientRowId, isNull);
    expect(e.hasContext, isNull);
  });

  test('a malformed onCaptureLifecycle payload is dropped (no event, no throw)', () async {
    var emitted = false;
    final sub = platform.captureLifecycle.listen((_) => emitted = true);
    const codec = StandardMethodCodec();
    for (final Object? bad in <Object?>[
      'not a map',
      null,
      <String, Object?>{'noPhase': 1},
    ]) {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        'capture_native',
        codec.encodeMethodCall(MethodCall('onCaptureLifecycle', bad)),
        (_) {},
      );
    }
    await Future<void>.delayed(Duration.zero);
    expect(emitted, isFalse);
    await sub.cancel();
  });

  test('updateOverlayExplanation forwards the Phase-1 senses payload to updateExplanation', () async {
    // The live bridge contract: per-reading blocks with display-ready pronunciation parts + per-POS
    // senses (all of them, laid out Dart-side). The platform layer forwards verbatim.
    await platform.updateOverlayExplanation({
      'phase': 'ready',
      'readings': [
        {
          'pronunciations': [
            {'label': 'US', 'display': '/ˌsɛrənˈdɪpɪti/'},
          ],
          'isIdiom': false,
          'pos': [
            {
              'partOfSpeech': 'noun',
              'senses': ['a happy accident'],
            },
          ],
        },
      ],
    });
    expect(calls.single.method, 'updateExplanation');
    final args = (calls.single.arguments as Map).cast<String, Object?>();
    expect(args['phase'], 'ready');
    expect(args['readings'], [
      {
        'pronunciations': [
          {'label': 'US', 'display': '/ˌsɛrənˈdɪpɪti/'},
        ],
        'isIdiom': false,
        'pos': [
          {
            'partOfSpeech': 'noun',
            'senses': ['a happy accident'],
          },
        ],
      },
    ]);
  });

  test('an incoming onOverlayExplainRequest surfaces unit + targetLanguage', () async {
    final future = platform.overlayExplainRequests.first;
    const codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'capture_native',
      codec.encodeMethodCall(
        const MethodCall('onOverlayExplainRequest', {
          'unit': 'serendipity',
          'targetLanguage': 'en',
        }),
      ),
      (_) {},
    );
    final req = await future;
    expect(req.unit, 'serendipity');
    expect(req.targetLanguage, 'en');
  });

  test('an incoming onOverlayContextPreviewRequest surfaces unit + sentence + target', () async {
    final future = platform.overlayContextPreviewRequests.first;
    const codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'capture_native',
      codec.encodeMethodCall(
        const MethodCall('onOverlayContextPreviewRequest', {
          'unit': 'cell',
          'contextText': 'The cell divides rapidly.',
          'targetLanguage': 'en',
        }),
      ),
      (_) {},
    );
    final req = await future;
    expect(req.unit, 'cell');
    expect(req.contextText, 'The cell divides rapidly.');
    expect(req.targetLanguage, 'en');
    // The optional axes are absent when native couldn't compute them — never defaulted.
    expect(req.contextLanguage, isNull);
    expect(req.spanStart, isNull);
    expect(req.spanEnd, isNull);
  });

  test(
    'onOverlayContextPreviewRequest carries the optional span + context-language axes',
    () async {
      final future = platform.overlayContextPreviewRequests.first;
      const codec = StandardMethodCodec();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        'capture_native',
        codec.encodeMethodCall(
          const MethodCall('onOverlayContextPreviewRequest', {
            'unit': '学习',
            'contextText': '我们今天学习新词。',
            'targetLanguage': 'zh-Hans',
            'explanationLanguage': 'en',
            'contextLanguage': 'zh-Hans',
            'spanStart': 4,
            'spanEnd': 6,
          }),
        ),
        (_) {},
      );
      final req = await future;
      expect(req.contextLanguage, 'zh-Hans');
      expect(req.spanStart, 4);
      expect(req.spanEnd, 6);
    },
  );

  test('a malformed onOverlayExplainRequest is dropped (no event, no throw)', () async {
    var emitted = false;
    final sub = platform.overlayExplainRequests.listen((_) => emitted = true);
    const codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'capture_native',
      codec.encodeMethodCall(const MethodCall('onOverlayExplainRequest', 'not a map')),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(emitted, isFalse);
    await sub.cancel();
  });
}
