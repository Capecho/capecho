/// The platform notification gateway behind the shared [ReminderScheduler]. Each client implements it
/// with its own local-notification mechanism — `flutter_local_notifications` on mobile, the native
/// `UNUserNotificationCenter` (via `capture_native`) on macOS — so the SCHEDULING POLICY (when to
/// nudge, when to stay quiet) lives once in [ReminderScheduler] and only the OS plumbing differs.
///
/// The daily review reminder (US-14.1) is a CLIENT-FIRED local notification: the account only stores
/// the preference (so it syncs across devices — see `Account.reminderEnabled` / `reminderTime`), and
/// the client schedules the actual OS notification. Tapping it opens Review; each client wires that
/// tap-through in its own implementation (the shared policy doesn't see it).
library;

abstract class ReminderNotifications {
  /// Ask the OS for permission to post notifications, returning whether they are (now) permitted.
  /// Idempotent — safe to call repeatedly (a granted/denied state just returns again, no second
  /// prompt). Platforms can choose whether [ReminderScheduler] calls this before scheduling; mobile
  /// requests from Settings when the user explicitly turns Daily reminder on.
  Future<bool> requestPermission();

  /// (Re)arm the single daily review reminder at [hour]:[minute] device-LOCAL time, repeating each
  /// day, REPLACING any previously-armed one (so re-scheduling never stacks duplicates). [title] /
  /// [body] are the user-visible copy.
  Future<void> scheduleDailyReminder({
    required int hour,
    required int minute,
    required String title,
    required String body,
  });

  /// Cancel the daily review reminder if one is armed — reminders turned off, signed out, or nothing
  /// due at the next fire (US-14.1's "no nag when nothing is due"). A no-op when none is scheduled.
  Future<void> cancelReminder();

  /// Post a SINGLE immediate notification (not the daily repeat) — the "reminders on" confirmation shown
  /// the moment the user enables reminders, so the feature visibly fires right away (US-14.1) instead of
  /// silently waiting for the day's scheduled time. Best-effort; never throws on a missing plugin.
  Future<void> showImmediate({required String title, required String body});
}
