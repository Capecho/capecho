import 'package:capecho_app_core/capecho_app_core.dart' show ReminderNotifications;
import 'package:capture_native/capture_native.dart' show CaptureNative;

/// macOS implementation of the shared [ReminderNotifications] gateway: delegates to the native
/// `UNUserNotificationCenter` via the `capture_native` plugin, keeping the macOS app SwiftPM-pure (no
/// flutter_local_notifications — the documented invariant). The scheduling POLICY stays in
/// capecho_app_core's `ReminderScheduler`; this is only the OS bridge.
///
/// There's no Dart tap seam here: a tapped reminder is routed NATIVELY — it posts the same
/// `capecho.showSurface` "review" the menu-bar Review item posts, so the agent brings its window
/// forward and navigates to Review along the existing path.
class NativeRemindersGateway implements ReminderNotifications {
  NativeRemindersGateway(this._native);

  final CaptureNative _native;

  @override
  Future<bool> requestPermission() => _native.requestNotificationPermission();

  @override
  Future<void> scheduleDailyReminder({
    required int hour,
    required int minute,
    required String title,
    required String body,
  }) => _native.scheduleDailyReminder(hour: hour, minute: minute, title: title, body: body);

  @override
  Future<void> cancelReminder() => _native.cancelReminder();

  @override
  Future<void> showImmediate({required String title, required String body}) =>
      _native.showImmediateNotification(title: title, body: body);
}
