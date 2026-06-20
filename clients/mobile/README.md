# Capecho — mobile client (Flutter, iOS + Android)

The **"echo" half** of the capture→echo loop: review the words you captured on your Mac with spaced
repetition, on the phone. Mobile is **review + reminders only** — capture is macOS. The product
invariant: card behaviour, states, and the server-authoritative FSRS schedule are **identical to
macOS**; only the entry point (a tab) and input model (tap vs keyboard) differ.

## Status

**Live on the App Store** (passed review). Built and verified (`flutter analyze` + `flutter test`
green); Sign-in, Review, Word Book, and Settings all ship. The home is the live Review with
corner-button popovers (a founder-directed divergence from a bottom tab bar), verified by widget tests,
offline golden renders, **and on-device**. Mobile is **review + reminders only — capture stays
macOS**, and Android + social sign-in on Android are still ahead.

- **Sign-in** — a brand-forward welcome (settled echo + "Capecho." wordmark + tagline) over the shared `SignInPanel`
  with the real provider logos (Apple emphasized on iOS · multi-color Google · email). Email OTP works
  today; **Google works on iOS** (see Sign-in setup); the token is stored in the iOS Keychain / Android
  EncryptedSharedPreferences (`SecureSessionStore`).
- **Review** — touch
  flashcards on the shared `ReviewController` (server FSRS): tap-to-flip, 4-tone rating grid (≥48px),
  context-front cards with the captured-span highlight, offline rating queue + "saved, will sync"
  badge, and every rest state with its illustration (IL-04 reviewed-stack for all-caught-up, IL-05
  closed-book for nothing-captured, settled echo for session-end / `language_unsupported` / error).
- **Word Book** ([`word_book/word_book_screen.dart`](lib/word_book/word_book_screen.dart)) — the synced
  personal dictionary: searchable saved-word list, word detail (readings + summary), recently-deleted +
  restore, and Anki/CSV export from the share sheet ([`word_book/export_sheet.dart`](lib/word_book/export_sheet.dart)).
- **Settings** —
  Reminders (daily on/off + time — now **load-bearing**: saving arms a real daily local notification,
  US-14.1), Language (explanation segmented · learning picker), Appearance (System · Light · Dark theme,
  device-local), Account (identity · sign out · delete account & data confirm), with per-field
  optimistic save + Queued / Not-saved + Retry pills. Driven by the shared `AccountSettingsController` +
  `AppearanceController`.
- **Daily review reminder** (US-14.1) — the saved reminder preference drives a real local notification
  via `flutter_local_notifications`, scheduled by the shared `ReminderScheduler` over a
  `LocalNotificationsGateway`: a daily repeat at the chosen local time, a due look-ahead that stays
  quiet when nothing's due, and a tap that opens Review. The phone also stamps its IANA timezone on the
  account at first sign-in (`flutter_timezone`).
- **Shell** ([`home/home_shell.dart`](lib/home/home_shell.dart)) — session restore on launch →
  signed-out → sign-in, signed-in → the **live Review as the home** (no tab bar). Settings and the Word
  Book are reached from two floating glass buttons in the top corners (top-left Settings · top-right Word
  Book) and open as near-full-screen **bottom popovers** ([`home/capecho_sheet.dart`](lib/home/capecho_sheet.dart),
  `showCapechoSheet`) over the dimmed Review. All three surfaces are functional. This is a deliberate,
  founder-directed divergence from a bottom tab bar.

### Sign-in setup (per provider)

The mobile app shares the **`com.capecho.app`** bundle id with the macOS build, so it reuses the
existing iOS Google OAuth client + redirect scheme (wired in `ios/Runner/Info.plist` + `backend.dart`)
and the Apple App ID.

- **Email** — works with no extra config.
- **Google (iOS)** — works out of the box (reuses the existing client; backend `GOOGLE_CLIENT_ID` is
  already set). On a device, accept the consent sheet.
- **Apple (iOS)** — app-side wiring is in place (`ios/Runner/Runner.entitlements` +
  `CODE_SIGN_ENTITLEMENTS`). To make it verify end-to-end, two founder steps remain: enable **Sign in
  with Apple** on the `com.capecho.app` App ID (Xcode automatic signing usually offers to add it), and
  set the backend secret `APPLE_CLIENT_ID = com.capecho.app`. Until then it steers to email.
- **Android social sign-in** — deferred: Google needs an Android OAuth client (SHA-1) and Apple on
  Android is a web flow. Email works on Android today.

### Still ahead

- **Mobile capture** — share-sheet capture (iOS Share Extension; Android `ACTION_PROCESS_TEXT` /
  `ACTION_SEND`). Mobile stays review-only for now; capture is macOS.
- **Android** — the iOS build ships; Android still needs its store release and social sign-in (Google
  needs an Android OAuth client SHA-1; Apple on Android is a web flow). Email works on Android today.
- **First-run onboarding** — sign-in currently lands directly on Review. (Setting the reminder time *during*
  first-run, US-ON.3, lands with onboarding; the reminder itself is now wired and editable in Settings.)
- **Consolidation** — the macOS `SettingsController` is entangled with `capture_native`; it migrates
  onto the shared `AccountSettingsController` when the macOS Settings/Word Book surfaces are extracted.

## Shared code (no drift)

The platform-agnostic layer lives in [`shared/app-core`](../../shared/app-core) (`capecho_app_core`),
shared with macOS: `AuthController`, `ReviewController`, `AccountSettingsController`, the daily-reminder
policy (`ReminderScheduler` + the `ReminderNotifications` gateway — each client supplies the OS
plumbing), `SignInPanel`, the design system (`OnboardingPalette`, `ObEchoMark`, buttons, `SurfaceHeader`,
brand glyphs via `flutter_svg`), the `SessionStore` interface, and `HttpClientTransport`. The backend contract is
[`shared/api-client`](../../shared/api-client) (`capecho_api`). Mobile does **not** capture, so it needs
no client-side dedup key, and it does **not** depend on `capecho_local_store` (review reads from the
server; the offline rating queue is in-memory in `ReviewController`). The review
illustrations are mobile-local (`lib/review/illustrations.dart`).

**App icon** — unified with the macOS app-icon artwork (cream echo mark on the `#785D51` coffee tile),
but generated from mobile-specific full-bleed source PNGs in `assets/` so the macOS transparent padding
and rounded tile edge do not ship on iOS or Android. iOS is full-bleed opaque; Android is an adaptive
icon with the inverted padded foreground treatment (coffee echo over a cream tile, with transparent
padding). Regenerate after an artwork change:
`dart run flutter_launcher_icons`.

## Build / test / run

```sh
flutter pub get
flutter analyze
flutter test

# Run on a simulator/device:
flutter run                                   # email + (on iOS) Google sign-in work with no flags
flutter run --dart-define=CAPECHO_API_BASE=http://localhost:8787   # against a local backend
```

Against the **staging** backend, use the repo-root launcher (it injects `CAPECHO_API_BASE` for you):

```sh
pnpm run run:staging:ios          # or :android   (from the repo root)
# equivalently:  ../../scripts/run-staging.sh ios
```

Note: the iOS build is **Swift Package Manager-pure (no CocoaPods)** — like the macOS client; there's
no `Podfile`. This became possible once `flutter_secure_storage` 10 moved its iOS implementation to the
SPM-capable `flutter_secure_storage_darwin` (it was the last plugin that still required CocoaPods).

### Release (iOS → App Store Connect)

One command builds the App Store `.ipa` and uploads it to App Store Connect:

```sh
source scripts/ios/release.env     # App Store Connect API key (copy from scripts/ios/release.env.example)
scripts/ios/release.sh             # build → validate → upload
```

Setup + per-release details: `scripts/ios/README.md`.
