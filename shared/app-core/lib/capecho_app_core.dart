/// capecho_app_core — the shared app layer both Capecho clients (macOS + mobile) build on, so the
/// auth + review logic, the sign-in UI, and the warm design system are ONE implementation rather than
/// two ports that can drift. Platform-specific pieces stay in each client and are injected: token
/// storage ([SessionStore] impls — a file on macOS, the Keychain/EncryptedSharedPreferences on
/// mobile), capture, navigation chrome, and the native sign-in OAuth client ids.
library;

// Shared web links (privacy/terms/website + support email), the bundle app-version reader, and a
// best-effort external-URL launcher — Settings → About (both clients) + onboarding's privacy link.
export 'src/app_info.dart';
export 'src/auth/auth_controller.dart';
// Auth: the session-token interface, the plugin-free sign-in controller, the shared sign-in panel,
// and the native credential wrappers (the only file that touches the Apple/Google plugins).
export 'src/auth/session_store.dart';
export 'src/auth/sign_in_panel.dart';
export 'src/auth/social_credentials.dart';
// Backend transport + the review session controller (both pure on capecho_api).
export 'src/backend/http_transport.dart';
// The Apple-IAP Pro purchase rail (App Store: iOS + macOS Mac App Store) — the product ids, the
// StoreKit-backed purchase controller (verify-then-finish, app-lifetime redelivery), and its testable
// PurchaseBackend seam. Shared so both clients drive ONE buy flow; each supplies its own buy surface.
export 'src/billing/pro_products.dart';
export 'src/billing/pro_purchase_controller.dart';
// capecho:// deep-link routing (T8) — the widget/notification open Review at a word through these.
export 'src/deep_link.dart';
// Design system (warm "Caffeine + Warm-Glass" palette, the )))-echo mark, buttons, key caps).
export 'src/design/capture_source.dart';
export 'src/design/chrome.dart';
// The empty-Word-Book illustration (open, blank book) — shared by both clients.
export 'src/design/word_book_empty_art.dart';
// Daily review reminder (US-14.1): the shared scheduling POLICY ([ReminderScheduler]) + the platform
// notification gateway each client implements ([ReminderNotifications]) — flutter_local_notifications
// on mobile, native UNUserNotificationCenter (via capture_native) on macOS. The account only stores the
// preference; the client fires the local notification.
export 'src/reminders/reminder_notifications.dart';
export 'src/reminders/reminder_scheduler.dart';
// The review flashcard's 3D flip (front↔back) animation — shared so macOS and mobile turn identically.
export 'src/review/flip_card.dart';
export 'src/review/review_controller.dart';
// Shared review-card chrome (the offline/sync badges + the card shell), so the two clients render them
// identically instead of as two copies.
export 'src/review/review_view.dart';
// The widget's Dart bridge: publish a snapshot to the App Group + drain the grades the widget enqueued
// on foreground (D9-C), over an injected platform seam (mobile: home_widget).
export 'src/review/widget_bridge.dart';
// The widget review surface (Phase 1): the pre-resolved snapshot the app hands the home-screen widget
// (App Group), its builder (DUE-only, shared resolve), the durable per-event offline queue, and the
// cursor-reconcile helpers. The SwiftUI widget decodes the same snapshot JSON (golden-fixture pinned).
export 'src/review/widget_review_snapshot.dart';
export 'src/review/widget_snapshot_builder.dart';
// The overlay/Word-Book per-POS senses display rules (cap, numbering, card-level hint), shared so the
// macOS native overlay mirror and the Flutter Word Book render identically.
export 'src/sense_layout.dart';
// The platform-agnostic Settings preference-save engine (account reminders + languages).
export 'src/settings/account_settings_controller.dart';
export 'src/settings/appearance_control.dart';
// Device-local appearance (Light / Dark / System): the ThemeMode controller + persistence seam, plus
// the shared Settings → Appearance segmented control. Each client injects a concrete store.
export 'src/settings/appearance_controller.dart';
// Device-local signed-out capture language defaults (target + gloss): the controller + persistence
// seam. Signed in these ride the account; signed out the capture path + Settings → Language fall back
// to this device-local choice. Each client injects a concrete store.
export 'src/settings/language_prefs_controller.dart';
export 'src/settings/native_language.dart';
export 'src/surface_header.dart';
// The one-click Anki `.apkg` deck builder — Word Book → Export, built on-device from the backend's
// structured rows. Shared so macOS (save panel) and mobile (share sheet) emit the same deck.
export 'src/word_book/anki_deck.dart';
// Target-profile pronunciation display rules (labels + decoration; the Dart mirror of shared/lang's
// TargetGenerationProfile.pronunciationLabels) — every renderer + the native overlay bridge consume
// these instead of hard-coding US/UK.
export 'src/word_book/pronunciation_display.dart';
// A heteronym's per-reading modules (pronunciation + POS per reading; the summary carries the meaning)
// — shared by the Word Book detail on both clients (and mirrored in the Swift overlay) so the meaning
// surfaces render a multi-reading word identically.
export 'src/word_book/reading_modules.dart';
// The per-POS bilingual senses renderer (overlay mirror) — the Word Book detail + Review card body.
export 'src/word_book/sense_modules.dart';
// The Word Book catalog/detail controller (server-authoritative; signed-out local catalog via the
// injected LocalWordBook).
export 'src/word_book/word_book_controller.dart';
// Shared Word Book presentational helpers — the memory meter (level/projection/echo), the POS chip,
// the "phrase" tag, the in-sentence highlight, and the terse date — so the catalog row, the detail
// header, and the review card render identically on both clients.
export 'src/word_book/word_book_view.dart';
