import Foundation
import UserNotifications

/// macOS local-notification scheduling for the daily review reminder (US-14.1), behind the
/// `capture_native` method channel. Going straight to `UNUserNotificationCenter` keeps the macOS app
/// SwiftPM-pure — no third-party notification plugin (the documented invariant; flutter_secure_storage
/// was avoided for the same reason). The Flutter side (capecho_app_core's `ReminderScheduler`) owns the
/// POLICY — when to arm, when to stay quiet; this is just the OS plumbing + the tap-through to Review.
///
/// One repeating calendar trigger (identifier [reminderIdentifier]) fires daily at the chosen local
/// time; re-scheduling replaces it (never stacks). A tap posts the SAME `capecho.showSurface` "review"
/// the menu-bar Review item posts, so the AppDelegate brings the window forward and the plugin relays
/// the surface to Flutter — one navigation path. Deployment target is macOS 14, so the modern
/// UserNotifications API needs no availability gating.
final class ReminderNotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
  /// The single daily-reminder request id — re-scheduling replaces it.
  static let reminderIdentifier = "capecho.dailyReview"

  private let center = UNUserNotificationCenter.current()

  override init() {
    super.init()
    // Set the delegate eagerly (at plugin registration) so a tap that wakes the agent routes to Review
    // and a foregrounded agent still shows the banner.
    center.delegate = self
  }

  /// Ask for notification authorization; `completion` is called on the main thread with the grant.
  func requestPermission(_ completion: @escaping (Bool) -> Void) {
    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      DispatchQueue.main.async { completion(granted) }
    }
  }

  /// (Re)arm the daily reminder at [hour]:[minute] local, repeating, replacing any previous one.
  func scheduleDaily(hour: Int, minute: Int, title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    // Carry the surface so a tap opens Review (mirrors the menu-bar item's notification userInfo).
    content.userInfo = ["surface": "review"]

    var components = DateComponents()
    components.hour = hour
    components.minute = minute
    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
    let request = UNNotificationRequest(
      identifier: Self.reminderIdentifier, content: content, trigger: trigger)

    // Replace any previously-armed reminder (re-scheduling, not stacking).
    center.removePendingNotificationRequests(withIdentifiers: [Self.reminderIdentifier])
    center.add(request, withCompletionHandler: nil)
  }

  /// Cancel the daily reminder if armed (a no-op otherwise).
  func cancel() {
    center.removePendingNotificationRequests(withIdentifiers: [Self.reminderIdentifier])
  }

  /// Post a SINGLE immediate notification — the "reminders on" confirmation shown the moment the user
  /// enables reminders, so the feature visibly fires right away. A nil trigger delivers it now; a
  /// DISTINCT identifier from the daily reminder means it never replaces an armed one. The willPresent
  /// delegate shows it even while the agent is foreground (the user is in Settings when this fires).
  func showImmediate(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.userInfo = ["surface": "review"]
    let request = UNNotificationRequest(
      identifier: "capecho.reminderConfirmation", content: content, trigger: nil)
    center.add(request, withCompletionHandler: nil)
  }

  // MARK: - UNUserNotificationCenterDelegate

  /// Show the banner even while the agent is "active" (a menu-bar agent often is).
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  /// A tap opens Review: post the SAME surface notification the menu-bar Review item posts. The
  /// AppDelegate observer brings the window forward and the plugin observer relays the surface to
  /// Flutter, so a tapped reminder and a menu click share one path.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let surface = (response.notification.request.content.userInfo["surface"] as? String) ?? "review"
    NotificationCenter.default.post(
      name: Notification.Name("capecho.showSurface"), object: nil,
      userInfo: ["surface": surface])
    completionHandler()
  }
}
