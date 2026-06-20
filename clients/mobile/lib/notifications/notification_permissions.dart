/// The notification-permission surface the Settings → Reminders section needs, beyond the
/// scheduling-only [ReminderNotifications] gateway (capecho_app_core). Split out so Settings can be
/// handed just this — and a test can fake it — without depending on the concrete
/// `flutter_local_notifications` gateway.
///
/// Why this exists (the bug it fixes): enabling the daily reminder optimistically flips the toggle ON
/// and saves the preference, but if the OS notification permission is **denied** the scheduler silently
/// cancels — so nothing ever fires and the user gets no feedback. With this, Settings can detect the
/// denied state, show a warning, and offer a jump to the system settings to fix it.
abstract class NotificationPermissions {
  /// The CURRENT OS authorization, without prompting (iOS `checkPermissions`, Android
  /// `areNotificationsEnabled`). Used to decide whether to show the "notifications are off" warning.
  Future<bool> hasPermission();

  /// Ask for permission — shows the OS prompt the FIRST time, and just returns the (unchanged) decision
  /// on every call after (iOS only ever prompts once). Returns whether notifications are now allowed.
  Future<bool> requestPermission();

  /// Jump to Capecho's notification settings in the OS Settings app, so a user who denied (or later
  /// turned them off) can switch them back on.
  Future<void> openSystemSettings();
}
