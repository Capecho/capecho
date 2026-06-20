import 'dart:async';
import 'dart:typed_data';

import 'package:capture_native/capture_native.dart';
import 'package:capture_native/capture_native_method_channel.dart';
import 'package:capture_native/capture_native_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// A fake platform that lets us push OCR snapshots and observe command calls,
/// so we can test the Dart reconstruction layering without the native side.
class FakeCaptureNativePlatform with MockPlatformInterfaceMixin implements CaptureNativePlatform {
  final StreamController<OcrSnapshot> controller = StreamController<OcrSnapshot>.broadcast();
  bool triggered = false;
  bool permissionRequested = false;

  @override
  Stream<OcrSnapshot> get snapshots => controller.stream;

  @override
  Future<void> triggerCapture() async => triggered = true;

  final List<String> appearanceModeCalls = [];

  @override
  Future<void> setAppearanceMode(String mode) async => appearanceModeCalls.add(mode);

  @override
  Future<bool> hasScreenRecordingPermission() async => true;

  @override
  Future<bool> requestScreenRecordingPermission() async {
    permissionRequested = true;
    return true;
  }

  bool onboardingCompleteValue = false;
  bool completeOnboardingCalled = false;
  int openSettingsCalls = 0;

  @override
  Future<bool> onboardingComplete() async => onboardingCompleteValue;

  @override
  Future<void> completeOnboarding() async => completeOnboardingCalled = true;

  @override
  Future<void> openScreenRecordingSettings() async => openSettingsCalls++;

  String? savedExportName;
  Uint8List? savedExportBytes;

  @override
  Future<String?> saveExportFile({required String suggestedName, required Uint8List bytes}) async {
    savedExportName = suggestedName;
    savedExportBytes = bytes;
    return '/tmp/$suggestedName';
  }

  int requestNotificationPermissionCalls = 0;
  final List<Map<String, Object?>> scheduledReminders = [];
  int cancelReminderCalls = 0;

  @override
  Future<bool> requestNotificationPermission() async {
    requestNotificationPermissionCalls++;
    return true;
  }

  @override
  Future<void> scheduleDailyReminder({
    required int hour,
    required int minute,
    required String title,
    required String body,
  }) async =>
      scheduledReminders.add({'hour': hour, 'minute': minute, 'title': title, 'body': body});

  @override
  Future<void> cancelReminder() async => cancelReminderCalls++;

  final List<Map<String, Object?>> immediateNotifications = [];

  @override
  Future<void> showImmediateNotification({required String title, required String body}) async =>
      immediateNotifications.add({'title': title, 'body': body});

  List<CapechoShortcut> shortcutValues = const [
    CapechoShortcut(
      action: 'capture',
      title: 'Capture',
      key: 'E',
      modifiers: ['option'],
      display: '⌥E',
    ),
    CapechoShortcut(
      action: 'review',
      title: 'Review',
      key: 'R',
      modifiers: ['option'],
      display: '⌥R',
    ),
    CapechoShortcut(
      action: 'wordBook',
      title: 'Word Book',
      key: 'B',
      modifiers: ['option'],
      display: '⌥B',
    ),
  ];

  @override
  Future<List<CapechoShortcut>> shortcuts() async => shortcutValues;

  @override
  Future<CapechoShortcut> setShortcut({
    required String action,
    required String key,
    required List<String> modifiers,
  }) async {
    final current = shortcutValues.firstWhere((s) => s.action == action);
    final updated = current.copyWith(
      key: key,
      modifiers: modifiers,
      display: '${modifiers.contains('option') ? '⌥' : ''}$key',
    );
    shortcutValues = [
      for (final shortcut in shortcutValues) shortcut.action == action ? updated : shortcut,
    ];
    return updated;
  }

  int hideWindowCalls = 0;

  @override
  Future<void> hideWindow() async => hideWindowCalls++;

  int requestOnboardingCalls = 0;

  @override
  Future<void> requestOnboarding() async => requestOnboardingCalls++;

  final List<Map<String, Object?>> savedCalls = [];
  final List<Map<String, Object?>> overlayCalls = [];
  final List<Map<String, Object?>> explanationCalls = [];
  final StreamController<SavedRef> savedController = StreamController<SavedRef>.broadcast();

  @override
  Future<SavedRef> saveCapture(Map<String, Object?> capture) async {
    savedCalls.add(capture);
    return SavedRef(clientRowId: 'fake-${savedCalls.length}', seq: savedCalls.length);
  }

  @override
  Future<void> showOverlay(Map<String, Object?> capture) async => overlayCalls.add(capture);

  @override
  Future<void> updateOverlayExplanation(Map<String, Object?> explanation) async =>
      explanationCalls.add(explanation);

  final List<Map<String, Object?>> contextPreviewCalls = [];

  @override
  Future<void> updateOverlayContextPreview(Map<String, Object?> update) async =>
      contextPreviewCalls.add(update);

  @override
  Stream<SavedRef> get saved => savedController.stream;

  final StreamController<CaptureLifecycleEvent> lifecycleController =
      StreamController<CaptureLifecycleEvent>.broadcast();

  @override
  Stream<CaptureLifecycleEvent> get captureLifecycle => lifecycleController.stream;

  final StreamController<void> showOnboardingController = StreamController<void>.broadcast();

  @override
  Stream<void> get showOnboardingRequests => showOnboardingController.stream;

  final StreamController<String> showSurfaceController = StreamController<String>.broadcast();

  @override
  Stream<String> get showSurfaceRequests => showSurfaceController.stream;

  final StreamController<OverlayExplainRequest> overlayExplainController =
      StreamController<OverlayExplainRequest>.broadcast();

  @override
  Stream<OverlayExplainRequest> get overlayExplainRequests => overlayExplainController.stream;

  final StreamController<OverlayContextPreviewRequest> overlayContextPreviewController =
      StreamController<OverlayContextPreviewRequest>.broadcast();

  @override
  Stream<OverlayContextPreviewRequest> get overlayContextPreviewRequests =>
      overlayContextPreviewController.stream;

  @override
  Future<List<Map<String, Object?>>> journalEntries(int afterSeq) async => const [];

  @override
  Future<String> installId() async => 'fake-install';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the default instance is the method-channel implementation', () {
    expect(CaptureNativePlatform.instance, isInstanceOf<MethodChannelCaptureNative>());
  });

  test('native snapshots flow through reconstruction to captures', () async {
    final fake = FakeCaptureNativePlatform();
    CaptureNativePlatform.instance = fake;
    final capture = CaptureNative();

    final future = capture.captures.first;
    fake.controller.add(
      const OcrSnapshot(
        lines: [OcrLine('hello world', NormRect(0.1, 0.5, 0.6, 0.04))],
        cursor: NormPoint(0.5, 0.52),
        screenName: 'TestScreen',
      ),
    );

    final result = await future;
    // The bridge ran the shared reconstructor: metadata passes through and a
    // result was produced. (Targeting specifics are covered by
    // shared/capture-core's own tests.)
    expect(result.recognizedLineCount, 1);
    expect(result.screenName, 'TestScreen');
    expect(result.contextSource, CaptureContextSource.ocr);

    await fake.controller.close();
  });

  test('commands delegate to the platform', () async {
    final fake = FakeCaptureNativePlatform();
    CaptureNativePlatform.instance = fake;
    final capture = CaptureNative();

    await capture.triggerCapture();
    expect(fake.triggered, isTrue);

    expect(await capture.requestScreenRecordingPermission(), isTrue);
    expect(fake.permissionRequested, isTrue);

    expect(await capture.hasScreenRecordingPermission(), isTrue);

    await capture.hideWindow();
    expect(fake.hideWindowCalls, 1);

    await capture.requestOnboarding();
    expect(fake.requestOnboardingCalls, 1);

    await capture.setAppearanceMode('dark');
    expect(fake.appearanceModeCalls.single, 'dark');
  });

  test('saveCapture forwards fields and returns a receipt', () async {
    final fake = FakeCaptureNativePlatform();
    CaptureNativePlatform.instance = fake;
    final capture = CaptureNative();

    final ref = await capture.saveCapture(
      surfaceUnit: 'hello',
      targetLanguage: 'en',
      contextText: 'hello world',
      source: 'ocr',
      sourceApp: 'Google Chrome',
      sourceTitle: 'A page title',
      detectedLanguage: 'en',
      detectedLanguageConfidence: 0.9,
    );

    expect(ref.clientRowId, isNotEmpty);
    expect(ref.seq, 1);
    expect(fake.savedCalls.single['surfaceUnit'], 'hello');
    expect(fake.savedCalls.single['targetLanguage'], 'en');
    expect(fake.savedCalls.single['source'], 'ocr');
    expect(fake.savedCalls.single['capturedAt'], isA<int>());
    // Capture-source metadata is forwarded to the native journal.
    expect(fake.savedCalls.single['sourceApp'], 'Google Chrome');
    expect(fake.savedCalls.single['sourceTitle'], 'A page title');
    expect(fake.savedCalls.single['detectedLanguage'], 'en');
    expect(fake.savedCalls.single['detectedLanguageConfidence'], 0.9);
  });

  test('showOverlay forwards the reconstructed capture + target language', () async {
    final fake = FakeCaptureNativePlatform();
    CaptureNativePlatform.instance = fake;
    final capture = CaptureNative();

    await capture.showOverlay(
      const CaptureResult(
        word: 'echo',
        line: 'a faint echo returned.',
        sentence: 'a faint echo returned.',
        context: 'a faint echo returned.',
        recognizedLineCount: 1,
        screenName: 'TestScreen',
        sourceApp: 'Google Chrome',
        sourceTitle: 'Echo — Wikipedia',
        contextSource: CaptureContextSource.ocr,
      ),
      targetLanguage: 'en',
      learningLanguage: 'en',
      explanationLanguage: 'zh-Hans',
      sourceApp: 'Google Chrome',
      sourceTitle: 'Echo — Wikipedia',
    );

    expect(fake.overlayCalls.single['unit'], 'echo');
    expect(fake.overlayCalls.single['context'], 'a faint echo returned.');
    expect(fake.overlayCalls.single['source'], 'ocr');
    expect(fake.overlayCalls.single['targetLanguage'], 'en');
    // The configured learning language is forwarded so the overlay can re-derive the target on a unit change.
    expect(fake.overlayCalls.single['learningLanguage'], 'en');
    // The gloss (explanation) language is forwarded distinct from the target.
    expect(fake.overlayCalls.single['explanationLanguage'], 'zh-Hans');
    // Capture-source provenance is forwarded so the overlay's native Save can journal it.
    expect(fake.overlayCalls.single['sourceApp'], 'Google Chrome');
    expect(fake.overlayCalls.single['sourceTitle'], 'Echo — Wikipedia');
  });

  test('showOverlay omits source provenance keys when the capture has none', () async {
    final fake = FakeCaptureNativePlatform();
    CaptureNativePlatform.instance = fake;
    final capture = CaptureNative();

    await capture.showOverlay(
      const CaptureResult(
        word: 'echo',
        line: 'an echo.',
        sentence: 'an echo.',
        context: 'an echo.',
        recognizedLineCount: 1,
        screenName: 'TestScreen',
        contextSource: CaptureContextSource.ocr,
      ),
      targetLanguage: 'en',
      learningLanguage: 'en',
      explanationLanguage: 'en',
    );

    expect(fake.overlayCalls.single.containsKey('sourceApp'), isFalse);
    expect(fake.overlayCalls.single.containsKey('sourceTitle'), isFalse);
  });

  test('showOverlay shows the single SENTENCE, not the wider multi-sentence context', () async {
    final fake = FakeCaptureNativePlatform();
    CaptureNativePlatform.instance = fake;
    final capture = CaptureNative();

    // The cursor word sits in a headline ending in "?"; the segmented sentence
    // stops there, while context expanded across the following body sentences.
    // The overlay must show the punctuation-delimited sentence.
    await capture.showOverlay(
      const CaptureResult(
        word: 'Messi',
        line: 'A higher ceiling than Messi? What next for Lamine Yamal?',
        sentence: 'A higher ceiling than Messi?',
        context:
            'A higher ceiling than Messi? What next for Lamine Yamal? Lamine Yamal is a key figure in...',
        recognizedLineCount: 3,
        screenName: 'TestScreen',
        contextSource: CaptureContextSource.ocr,
      ),
      targetLanguage: 'en',
      learningLanguage: 'en',
      explanationLanguage: 'en',
    );

    expect(fake.overlayCalls.single['context'], 'A higher ceiling than Messi?');
  });

  test('showOverlay blanks a context that just echoes the unit (no real sentence)', () async {
    final fake = FakeCaptureNativePlatform();
    CaptureNativePlatform.instance = fake;
    final capture = CaptureNative();

    // A bare-word selection: the word is its own "sentence". The Sentence
    // field must stay empty rather than echo the word back into it.
    await capture.showOverlay(
      const CaptureResult(
        word: 'slide',
        line: 'slide',
        sentence: 'slide',
        context: 'slide',
        recognizedLineCount: 1,
        screenName: 'TestScreen',
        contextSource: CaptureContextSource.selection,
      ),
      targetLanguage: 'zh-Hans',
      learningLanguage: 'en',
      explanationLanguage: 'en',
    );

    expect(fake.overlayCalls.single['unit'], 'slide');
    expect(fake.overlayCalls.single['context'], '');
  });

  test('saved stream surfaces the native overlay save signal', () async {
    final fake = FakeCaptureNativePlatform();
    CaptureNativePlatform.instance = fake;
    final capture = CaptureNative();

    final future = capture.saved.first;
    fake.savedController.add(const SavedRef(clientRowId: 'crid-1', seq: 7));
    final ref = await future;

    expect(ref.clientRowId, 'crid-1');
    expect(ref.seq, 7);

    await fake.savedController.close();
  });

  test('showOnboardingRequests surfaces the menu-bar re-show signal', () async {
    final fake = FakeCaptureNativePlatform();
    CaptureNativePlatform.instance = fake;
    final capture = CaptureNative();

    final future = capture.showOnboardingRequests.first;
    fake.showOnboardingController.add(null);
    await future; // completes => the request propagated

    await fake.showOnboardingController.close();
  });

  test('showSurfaceRequests surfaces the requested surface name', () async {
    final fake = FakeCaptureNativePlatform();
    CaptureNativePlatform.instance = fake;
    final capture = CaptureNative();

    final future = capture.showSurfaceRequests.first;
    fake.showSurfaceController.add('review');
    expect(await future, 'review');

    await fake.showSurfaceController.close();
  });

  test('an empty-OCR snapshot with a fresh clipboard cascades to a clipboard '
      'capture', () async {
    final fake = FakeCaptureNativePlatform();
    CaptureNativePlatform.instance = fake;
    final capture = CaptureNative();

    final future = capture.captures.first;
    fake.controller.add(
      const OcrSnapshot(
        lines: [],
        cursor: NormPoint(0.5, 0.5),
        clipboard: ClipboardCandidate(text: 'serendipity', fresh: true),
        screenName: 'TestScreen',
      ),
    );

    final result = await future;
    expect(result.contextSource, CaptureContextSource.clipboard);
    expect(result.word, 'serendipity');

    await fake.controller.close();
  });

  test('showOverlay tags a clipboard capture with source "clipboard"', () async {
    final fake = FakeCaptureNativePlatform();
    CaptureNativePlatform.instance = fake;
    final capture = CaptureNative();

    await capture.showOverlay(
      const CaptureResult(
        word: 'serendipity',
        line: null,
        sentence: null,
        context: '',
        recognizedLineCount: 0,
        screenName: 'TestScreen',
        contextSource: CaptureContextSource.clipboard,
      ),
      targetLanguage: 'en',
      learningLanguage: 'en',
      explanationLanguage: 'en',
    );

    expect(fake.overlayCalls.single['source'], 'clipboard');
    expect(fake.overlayCalls.single['unit'], 'serendipity');
  });

  test('updateOverlayExplanation forwards phase + (omits null) readings', () async {
    final fake = FakeCaptureNativePlatform();
    CaptureNativePlatform.instance = fake;
    final capture = CaptureNative();

    await capture.updateOverlayExplanation(phase: 'loading');
    expect(fake.explanationCalls.single, {'phase': 'loading'}); // null readings omitted

    // Phase-1 senses payload: each reading carries DISPLAY-READY pronunciation parts ({label, display})
    // + an isIdiom flag + `pos` rows ({partOfSpeech, senses, note}, laid out Dart-side). Every sense is
    // shown (no cap, no "more" hint). Forwarded verbatim.
    await capture.updateOverlayExplanation(
      phase: 'ready',
      readings: [
        {
          'pronunciations': [
            {'label': 'US', 'display': '/ˈɑbdʒɛkt/'},
            {'label': 'UK', 'display': '/ˈɒbdʒɪkt/'},
          ],
          'isIdiom': false,
          'pos': [
            {
              'partOfSpeech': 'noun',
              'senses': ['a thing you can see or touch', 'an aim'],
            },
          ],
        },
        {
          'pronunciations': [
            {'label': 'US', 'display': '/əbˈdʒɛkt/'},
          ],
          'isIdiom': false,
          'pos': [
            {
              'partOfSpeech': 'verb',
              'senses': ['to disagree'],
            },
          ],
        },
      ],
    );
    expect(fake.explanationCalls.last, {
      'phase': 'ready',
      'readings': [
        {
          'pronunciations': [
            {'label': 'US', 'display': '/ˈɑbdʒɛkt/'},
            {'label': 'UK', 'display': '/ˈɒbdʒɪkt/'},
          ],
          'isIdiom': false,
          'pos': [
            {
              'partOfSpeech': 'noun',
              'senses': ['a thing you can see or touch', 'an aim'],
            },
          ],
        },
        {
          'pronunciations': [
            {'label': 'US', 'display': '/əbˈdʒɛkt/'},
          ],
          'isIdiom': false,
          'pos': [
            {
              'partOfSpeech': 'verb',
              'senses': ['to disagree'],
            },
          ],
        },
      ],
    });
  });

  test('onboarding methods delegate to the platform', () async {
    final fake = FakeCaptureNativePlatform()..onboardingCompleteValue = true;
    CaptureNativePlatform.instance = fake;
    final capture = CaptureNative();

    expect(await capture.onboardingComplete(), isTrue);

    await capture.completeOnboarding();
    expect(fake.completeOnboardingCalled, isTrue);

    await capture.openScreenRecordingSettings();
    expect(fake.openSettingsCalls, 1);
  });

  test('shortcut methods delegate to the platform', () async {
    final fake = FakeCaptureNativePlatform();
    CaptureNativePlatform.instance = fake;
    final capture = CaptureNative();

    expect((await capture.shortcuts()).first.display, '⌥E');
    final updated = await capture.setShortcut(
      action: 'review',
      key: 'J',
      modifiers: const ['option'],
    );
    expect(updated.display, '⌥J');
    expect(fake.shortcutValues[1].key, 'J');
  });

  test('updateOverlayContextPreview forwards phase + (omits null) two-field gloss', () async {
    final fake = FakeCaptureNativePlatform();
    CaptureNativePlatform.instance = fake;
    final capture = CaptureNative();

    await capture.updateOverlayContextPreview(phase: 'loading');
    expect(fake.contextPreviewCalls.single, {'phase': 'loading'}); // null gloss fields omitted

    await capture.updateOverlayContextPreview(
      phase: 'ready',
      meaning: 'Here bow is the body part; she took a bow as the audience applauded.',
    );
    expect(fake.contextPreviewCalls.last, {
      'phase': 'ready',
      'meaning': 'Here bow is the body part; she took a bow as the audience applauded.',
    });

    await capture.updateOverlayContextPreview(phase: 'quota');
    expect(fake.contextPreviewCalls.last, {'phase': 'quota'});
  });

  test('overlayContextPreviewRequests surfaces the opt-in in-context request', () async {
    final fake = FakeCaptureNativePlatform();
    CaptureNativePlatform.instance = fake;
    final capture = CaptureNative();

    final future = capture.overlayContextPreviewRequests.first;
    fake.overlayContextPreviewController.add(
      const OverlayContextPreviewRequest(
        unit: 'cell',
        contextText: 'The cell divides rapidly.',
        targetLanguage: 'en',
        explanationLanguage: 'zh-Hans',
      ),
    );
    final req = await future;
    expect(req.unit, 'cell');
    expect(req.contextText, 'The cell divides rapidly.');
    expect(req.targetLanguage, 'en');
    expect(req.explanationLanguage, 'zh-Hans');

    await fake.overlayContextPreviewController.close();
  });
}
