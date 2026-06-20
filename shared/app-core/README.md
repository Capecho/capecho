# capecho_app_core

The **shared Flutter app core** both clients build on (macOS + mobile), so the auth and review
logic can't drift between them. One implementation of the platform-agnostic controllers, the shared
sign-in panel, the warm design system, and the HTTP transport. The platform-specific pieces (token
storage, capture, navigation chrome, native OAuth client ids) stay in each client and are
**injected**.

macOS consumes this package through thin re-export shims; mobile depends on it directly.

## What's here (`lib/src/`)

| Area | Pieces |
|---|---|
| `auth/` | `AuthController`, `SessionStore`, the shared `SignInPanel` (Apple · Google · email), `social_credentials.dart` — the one place touching the native sign-in plugins |
| `review/` | `ReviewController` — drives the FSRS review loop (scheduling is **server-authoritative**; clients never compute intervals) |
| `word_book/` | `WordBookController` + the signed-out local catalog adapter (reads `capecho_local_store`) |
| `settings/` | `AccountSettingsController` |
| `design/` | `chrome.dart` — the warm design system (palette, echo mark, buttons) |
| `backend/` | `HttpTransport` — the concrete network impl behind `capecho_api` |
| `surface_header.dart` | the shared brand / back-button surface header |

Barrel export: [`lib/capecho_app_core.dart`](lib/capecho_app_core.dart).

## Depends on

- [`capecho_api`](../api-client) — the typed backend client every controller drives.
- [`capecho_local_store`](../local-store) — row types for the signed-out Word Book (mobile passes
  `local: null` and never opens a store, so no native sqlite is pulled in).
- `sign_in_with_apple`, `google_sign_in`, `flutter_svg`, `http`.

## Test

```sh
cd shared/app-core
flutter pub get
flutter test
```
