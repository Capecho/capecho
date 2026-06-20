import 'package:app_settings/app_settings.dart';
import 'package:capecho_app_core/capecho_app_core.dart' show ReminderNotifications;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'notification_permissions.dart';

/// The mobile (iOS + Android) implementation of the shared [ReminderNotifications] gateway, backed by
/// `flutter_local_notifications`. It owns the OS plumbing — the channel, the permission prompt, the
/// device-timezone-correct daily schedule, and the tap-through — so the scheduling POLICY stays in
/// capecho_app_core's `ReminderScheduler`.
///
/// US-14.1: the daily review reminder is a CLIENT-FIRED local notification. We arm a SINGLE repeating
/// notification (id [_reminderId]) at the chosen local time, replacing any previous one; the scheduler
/// cancels it on the days nothing is due. Tapping it carries [_reviewPayload] so the app opens Review.
class LocalNotificationsGateway implements ReminderNotifications, NotificationPermissions {
  LocalNotificationsGateway();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  /// One stable id — re-scheduling replaces it, so the daily reminder never stacks duplicates.
  static const int _reminderId = 1001;

  /// A distinct id for the one-time "reminders on" confirmation, so it never collides with / replaces
  /// the armed daily reminder ([_reminderId]).
  static const int _confirmationId = 1002;

  /// Carried on the notification; the tap-handler opens Review when it sees this.
  static const String _reviewPayload = 'review';

  static const String _channelId = 'daily_review_reminder';
  static const String _channelName = 'Daily review reminder';
  static const String _channelDescription =
      'A gentle daily nudge to review the words you captured.';

  bool _initialized = false;
  bool _timezoneReady = false;

  /// Invoked with a tapped notification's payload — the app wires this to open Review. Captured in
  /// [init]; a no-op until then.
  void Function(String payload)? _onSelect;

  /// Initialize the plugin (idempotent) and wire the tap handler. Must run before any schedule. We do
  /// NOT request permission here (`request*Permission: false`) — that prompt belongs to Settings when
  /// the user explicitly turns Daily reminder on, not a first-launch or background-sync surprise.
  Future<void> init({required void Function(String payload) onSelectNotification}) async {
    _onSelect = onSelectNotification;
    if (_initialized) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: _handleResponse,
    );
    _initialized = true;
  }

  void _handleResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload != null && payload.isNotEmpty) _onSelect?.call(payload);
  }

  /// Resolve the device's IANA zone so the repeating schedule lands at the user's LOCAL wall-clock
  /// time across DST. A failure leaves `tz.local` at its UTC default — the reminder still fires, just
  /// at UTC o'clock on the rare device we can't read — which beats not scheduling at all.
  Future<void> _ensureTimezone() async {
    if (_timezoneReady) return;
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // Keep the default location; see above.
    }
    _timezoneReady = true;
  }

  @override
  Future<bool> requestPermission() async {
    await _ensureInitialized();
    final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      final granted = await ios.requestPermissions(alert: true, badge: true, sound: true);
      return granted ?? false;
    }
    final android = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final granted = await android.requestNotificationsPermission();
      return granted ?? false;
    }
    return true;
  }

  @override
  Future<bool> hasPermission() async {
    await _ensureInitialized();
    final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      // Reads the CURRENT authorization (no prompt). `isEnabled` is false when the user denied at the
      // OS prompt or later switched notifications off in Settings.
      final options = await ios.checkPermissions();
      return options?.isEnabled ?? false;
    }
    final android = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      return await android.areNotificationsEnabled() ?? false;
    }
    // No platform implementation (a test / unsupported host) — assume allowed so no spurious warning.
    return true;
  }

  @override
  Future<void> openSystemSettings() =>
      AppSettings.openAppSettings(type: AppSettingsType.notification);

  @override
  Future<void> scheduleDailyReminder({
    required int hour,
    required int minute,
    required String title,
    required String body,
  }) async {
    await _ensureInitialized();
    await _ensureTimezone();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
      iOS: DarwinNotificationDetails(),
    );
    await _plugin.zonedSchedule(
      id: _reminderId,
      title: title,
      body: body,
      scheduledDate: _nextInstant(hour, minute),
      notificationDetails: details,
      // A daily review reminder doesn't need to-the-second precision; inexact scheduling avoids the
      // Android 13+ exact-alarm permission entirely.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      // Repeat every day at this local time.
      matchDateTimeComponents: DateTimeComponents.time,
      payload: _reviewPayload,
    );
  }

  tz.TZDateTime _nextInstant(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (!scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }

  @override
  Future<void> cancelReminder() async {
    await _ensureInitialized();
    await _plugin.cancel(id: _reminderId);
  }

  @override
  Future<void> showImmediate({required String title, required String body}) async {
    await _ensureInitialized();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
      iOS: DarwinNotificationDetails(),
    );
    await _plugin.show(
      id: _confirmationId,
      title: title,
      body: body,
      notificationDetails: details,
      payload: _reviewPayload,
    );
  }

  /// Ensure [init] ran (defends the gateway methods if the scheduler reaches one before the app's
  /// explicit init); preserves a tap handler set by a real [init].
  Future<void> _ensureInitialized() async {
    if (!_initialized) await init(onSelectNotification: _onSelect ?? (_) {});
  }
}
