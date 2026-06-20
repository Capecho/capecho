import 'dart:async';

import 'package:capecho_capture_core/capecho_capture_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'capture_native_platform_interface.dart';

/// Method/Event-channel implementation of [CaptureNativePlatform].
///
/// - MethodChannel `capture_native` — commands (trigger, permission, overlay),
///   and native→Dart callbacks (`onCaptureSaved`).
/// - EventChannel `capture_native/snapshots` — a broadcast stream of native
///   OCR snapshots (one per capture).
class MethodChannelCaptureNative extends CaptureNativePlatform {
  MethodChannelCaptureNative() {
    // Receive native→Dart calls (the overlay's durable-save signal).
    methodChannel.setMethodCallHandler(_handleNativeCall);
  }

  @visibleForTesting
  final methodChannel = const MethodChannel('capture_native');

  @visibleForTesting
  final eventChannel = const EventChannel('capture_native/snapshots');

  Stream<OcrSnapshot>? _snapshots;
  final StreamController<SavedRef> _savedController = StreamController<SavedRef>.broadcast();
  final StreamController<void> _showOnboardingController = StreamController<void>.broadcast();
  final StreamController<String> _showSurfaceController = StreamController<String>.broadcast();
  final StreamController<OverlayExplainRequest> _overlayExplainController =
      StreamController<OverlayExplainRequest>.broadcast();
  final StreamController<OverlayContextPreviewRequest> _overlayContextPreviewController =
      StreamController<OverlayContextPreviewRequest>.broadcast();
  final StreamController<CaptureLifecycleEvent> _lifecycleController =
      StreamController<CaptureLifecycleEvent>.broadcast();

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onCaptureSaved':
        final map = (call.arguments as Map).cast<dynamic, dynamic>();
        _savedController.add(SavedRef.fromMap(map));
        return null;
      case 'onCaptureLifecycle':
        // §14 capture-lifecycle metric (CEO-10). Defensive: a non-Map or a phase-less payload is
        // dropped rather than thrown — a malformed metric must never disrupt the capture path.
        if (call.arguments is Map) {
          final map = (call.arguments as Map).cast<dynamic, dynamic>();
          if (map['phase'] is String) {
            _lifecycleController.add(CaptureLifecycleEvent.fromMap(map));
          }
        }
        return null;
      case 'showOnboarding':
        _showOnboardingController.add(null);
        return null;
      case 'showSurface':
        // Defensive cast: a non-String payload is dropped rather than thrown.
        final surface = call.arguments is String ? call.arguments as String : null;
        if (surface != null && surface.isNotEmpty) {
          _showSurfaceController.add(surface);
        }
        return null;
      case 'onOverlayExplainRequest':
        // The overlay's `Explain in ▾` gloss change / unit edit / Retry asks for a fresh /explain.
        // Defensive: a non-Map payload is dropped rather than thrown.
        if (call.arguments is Map) {
          final map = (call.arguments as Map).cast<dynamic, dynamic>();
          _overlayExplainController.add(OverlayExplainRequest.fromMap(map));
        }
        return null;
      case 'onOverlayContextPreviewRequest':
        // The overlay's opt-in "Explain in this sentence" tap (E2). Defensive: a non-Map payload is
        // dropped rather than thrown.
        if (call.arguments is Map) {
          final map = (call.arguments as Map).cast<dynamic, dynamic>();
          _overlayContextPreviewController.add(OverlayContextPreviewRequest.fromMap(map));
        }
        return null;
      default:
        return null;
    }
  }

  @override
  Stream<void> get showOnboardingRequests => _showOnboardingController.stream;

  @override
  Stream<String> get showSurfaceRequests => _showSurfaceController.stream;

  @override
  Stream<OverlayExplainRequest> get overlayExplainRequests => _overlayExplainController.stream;

  @override
  Stream<OverlayContextPreviewRequest> get overlayContextPreviewRequests =>
      _overlayContextPreviewController.stream;

  @override
  Stream<OcrSnapshot> get snapshots {
    return _snapshots ??= eventChannel.receiveBroadcastStream().map(
      (event) => OcrSnapshot.fromMap(event as Map<dynamic, dynamic>),
    );
  }

  @override
  Future<void> triggerCapture() async {
    await methodChannel.invokeMethod<void>('triggerCapture');
  }

  @override
  Future<void> setAppearanceMode(String mode) async {
    await methodChannel.invokeMethod<void>('setAppearanceMode', {'mode': mode});
  }

  @override
  Future<void> showOverlay(Map<String, Object?> capture) async {
    await methodChannel.invokeMethod<void>('showOverlay', capture);
  }

  @override
  Future<void> updateOverlayExplanation(Map<String, Object?> explanation) async {
    await methodChannel.invokeMethod<void>('updateExplanation', explanation);
  }

  @override
  Future<void> updateOverlayContextPreview(Map<String, Object?> update) async {
    await methodChannel.invokeMethod<void>('updateContextPreview', update);
  }

  @override
  Stream<SavedRef> get saved => _savedController.stream;

  @override
  Stream<CaptureLifecycleEvent> get captureLifecycle => _lifecycleController.stream;

  @override
  Future<bool> hasScreenRecordingPermission() async {
    final granted = await methodChannel.invokeMethod<bool>('hasScreenRecordingPermission');
    return granted ?? false;
  }

  @override
  Future<bool> requestScreenRecordingPermission() async {
    final granted = await methodChannel.invokeMethod<bool>('requestScreenRecordingPermission');
    return granted ?? false;
  }

  @override
  Future<bool> onboardingComplete() async {
    final done = await methodChannel.invokeMethod<bool>('onboardingComplete');
    return done ?? false;
  }

  @override
  Future<void> completeOnboarding() async {
    await methodChannel.invokeMethod<void>('completeOnboarding');
  }

  @override
  Future<void> openScreenRecordingSettings() async {
    await methodChannel.invokeMethod<void>('openScreenRecordingSettings');
  }

  @override
  Future<List<CapechoShortcut>> shortcuts() async {
    final raw = await methodChannel.invokeListMethod<Object?>('getShortcuts');
    return (raw ?? const <Object?>[])
        .map((e) => CapechoShortcut.fromMap(e as Map))
        .toList(growable: false);
  }

  @override
  Future<CapechoShortcut> setShortcut({
    required String action,
    required String key,
    required List<String> modifiers,
  }) async {
    final raw = await methodChannel.invokeMapMethod<String, Object?>('setShortcut', {
      'action': action,
      'key': key,
      'modifiers': modifiers,
    });
    if (raw == null) {
      throw StateError('setShortcut returned no shortcut');
    }
    return CapechoShortcut.fromMap(raw);
  }

  @override
  Future<String?> saveExportFile({required String suggestedName, required Uint8List bytes}) {
    // Uint8List is encoded by the standard codec as FlutterStandardTypedData on the native side.
    return methodChannel.invokeMethod<String>('saveExportFile', {
      'suggestedName': suggestedName,
      'bytes': bytes,
    });
  }

  @override
  Future<void> hideWindow() async {
    await methodChannel.invokeMethod<void>('hideWindow');
  }

  @override
  Future<void> requestOnboarding() async {
    await methodChannel.invokeMethod<void>('requestOnboarding');
  }

  @override
  Future<SavedRef> saveCapture(Map<String, Object?> capture) async {
    final result = await methodChannel.invokeMapMethod<String, Object?>('saveCapture', capture);
    if (result == null) {
      throw StateError('saveCapture returned no receipt');
    }
    return SavedRef.fromMap(result);
  }

  @override
  Future<List<Map<String, Object?>>> journalEntries(int afterSeq) async {
    final raw = await methodChannel.invokeListMethod<Object?>('journalEntries', {
      'afterSeq': afterSeq,
    });
    return (raw ?? const <Object?>[])
        .map((e) => Map<String, Object?>.from(e as Map))
        .toList(growable: false);
  }

  @override
  Future<String> installId() async {
    final id = await methodChannel.invokeMethod<String>('installId');
    return id ?? '';
  }

  @override
  Future<bool> requestNotificationPermission() async {
    final granted = await methodChannel.invokeMethod<bool>('requestNotificationPermission');
    return granted ?? false;
  }

  @override
  Future<void> scheduleDailyReminder({
    required int hour,
    required int minute,
    required String title,
    required String body,
  }) async {
    await methodChannel.invokeMethod<void>('scheduleDailyReminder', {
      'hour': hour,
      'minute': minute,
      'title': title,
      'body': body,
    });
  }

  @override
  Future<void> cancelReminder() async {
    await methodChannel.invokeMethod<void>('cancelReminder');
  }

  @override
  Future<void> showImmediateNotification({required String title, required String body}) async {
    await methodChannel.invokeMethod<void>('showImmediateNotification', {
      'title': title,
      'body': body,
    });
  }
}
