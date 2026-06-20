# Sign-in setup (macOS)

Why "Apple sign-in doesn't work" right now, and exactly what's needed to light up each provider.

**The client is already correct.** `Sign in with Apple` is wired (`lib/auth/social_credentials.dart`
→ `sign_in_with_apple`), the entitlement is present (`com.apple.developer.applesignin` in both
`macos/Runner/DebugProfile.entitlements` + `Release.entitlements`), and the app bundle id is
**`com.capecho.app`** (`macos/Runner/Configs/AppInfo.xcconfig`). The Settings + onboarding sign-in
UIs both drive the shared `SignInPanel` against the live `AuthController`. So what's missing is
**deploy/developer-account configuration**, not app code — and that's what this file documents.

A provider sign-in flows: native sheet → an OIDC **identity token** → `POST /auth/session` on the
backend → the backend **verifies the token's `aud`/`iss`/signature** against its configured client
ids. If the backend isn't configured (or the token's `aud` doesn't match), it returns `401
auth_failed` and the app shows "…couldn't be verified — use email for now."

## What works without any developer-account config

**Email one-time-code sign-in.** It needs only the backend's `RESEND_API_KEY` + `EMAIL_FROM`
(`POST /auth/email/start` → 6-digit code → `POST /auth/email/verify`). This is the recommended path
until Apple/Google are configured — the `SignInPanel` always offers "Continue with email", and it
signs in fully (session + local-capture claim).

## Backend secrets (Cloudflare Worker)

Set with `wrangler secret put <NAME>` in `backend/` (see `backend/src/index.ts` for the full env doc):

| Secret | Lights up | Value |
|---|---|---|
| `APPLE_CLIENT_ID` | Apple sign-in | Comma-separated accepted token `aud`s. For the native macOS/iOS app this is the **bundle id `com.capecho.app`**. (A web/Android Services ID would be added to the list too.) |
| `GOOGLE_CLIENT_ID` | Google sign-in | Comma-separated accepted `aud`s — whichever client id ends up as the ID-token `aud` (the Web "server" client when set, else the native client). |
| `RESEND_API_KEY` + `EMAIL_FROM` | Email sign-in | A Resend API key + the verified sender (`"Capecho <login@your-domain>"`). |
| `GEMINI_API_KEY` | Free word explanations | Google Generative Language API key. |
| `CONTEXT_KEK` | The paid context layer (T8) | base64 32-byte master key. |

With none of these set every sign-in fails closed (by design) — that's the current state.

## Apple — the remaining steps (Apple Developer account)

1. In the Apple Developer portal, enable the **"Sign in with Apple"** capability on the App ID
   `com.capecho.app` (the entitlement is already in the app; the App ID must grant it).
2. Sign the app with a provisioning profile that includes that capability.
3. Set the backend `APPLE_CLIENT_ID = com.capecho.app` so the token `aud` matches.

Until 1–3 are done, the native Apple sheet may appear but the backend can't verify the token →
the app steers the user to email.

## Google — the remaining steps (Google Cloud Console)

The client code is wired (`lib/auth/social_credentials.dart` → the official `google_sign_in` v7 flow;
the `FLTGoogleSignInPlugin` is registered and `GoogleSignIn-iOS` is pinned via Swift PM; the
`keychain-access-groups` entitlement the SDK needs is present in both entitlements files; and the
Info.plist `CFBundleURLTypes` redirect scheme is wired to the `GOOGLE_REVERSED_CLIENT_ID` build var).
So, like Apple, what's left is account config + supplying the ids:

1. Create OAuth client ids: an **iOS** client (Application type *iOS*, bundle id `com.capecho.app` —
   used for the native macOS app too) and, if you want the ID token's `aud` to be a stable server
   identity, an optional **Web** "server" client.
2. **Register the redirect scheme** — set `GOOGLE_REVERSED_CLIENT_ID` in
   `macos/Runner/Configs/AppInfo.xcconfig` to the iOS client's reversed id
   (`com.googleusercontent.apps.<the id prefix>` — the Console shows it verbatim as the iOS client's
   "iOS URL scheme"). Info.plist already references this var; empty → Google sign-in stays unavailable
   and the UI steers to email.
3. Client ids live in `lib/backend/backend.dart` as the `String.fromEnvironment` defaults
   (`kGoogleNativeClientId` / `kGoogleServerClientId`), so every build picks them up — no flags needed.
   Point at *different* clients by overriding per build:
   ```sh
   flutter run -d macos \
     --dart-define=GOOGLE_NATIVE_CLIENT_ID=<ios-client>.apps.googleusercontent.com \
     --dart-define=GOOGLE_SERVER_CLIENT_ID=<web-client>.apps.googleusercontent.com
   ```
4. Add whichever id becomes the token `aud` (the Web "server" client when `GOOGLE_SERVER_CLIENT_ID` is
   set, else the native iOS client) to the backend `GOOGLE_CLIENT_ID` list (else it fails
   `bad_audience`).

## Pointing the app at a backend

The app defaults to `https://api.capecho.com`. Override for local/staging:

```sh
flutter run -d macos --dart-define=CAPECHO_API_BASE=http://localhost:8787
```

Make sure that deployment actually has the secrets above set — a running backend with no
`APPLE_CLIENT_ID` will still reject Apple sign-in.
