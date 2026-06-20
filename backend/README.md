# @capecho/backend

Cloudflare Workers backend. **D1 is the single source of truth**; the shared public
explanation cache is **R2 + CDN**; **Durable Objects** handle only true cross-request
serialization (single-flight on cache-miss + the global daily AI-spend cap). Per
ENG-2 the per-user context quota is the D1 `context_quota_reservations` table, **not**
a DO.

## Status (M1 + M3 + M5 + T8 + auth — built)

The MVP backend surface from build-plan §5.2 is implemented and tested (403 backend+shared
tests; `wrangler deploy --dry-run` bundles, all bindings resolve):

- **Schema** (`migrations/`): `0001_init.sql` (accounts, words + dedup unique index on
  `(user_id, target_language, normalized_unit)`, word_contexts encrypted-at-rest + span offsets,
  **fsrs_events** source-of-truth + **fsrs_cards** projection, **context_quota_reservations**,
  global_budget), `0002_claim_records.sql` (pre-login claim), `0003_sessions.sql` (hashed bearer
  session tokens), `0004_email_codes.sql` (hashed email sign-in OTP codes),
  `0005_account_reminders.sql` (per-account reminder prefs), `0006_account_email.sql` (account email
  for the `/auth/me` identity surface).
- **Auth (M3)** — `POST /auth/session` (verify provider credential → account → bearer session),
  `POST /auth/signout`, `GET /auth/me` (carries `provider` + `email`), `DELETE /account`
  (mark-deleted + revoke session; the 30-day retention cron purges it, re-sign-in cancels);
  sessions stored as `SHA-256(token)` ([`src/auth.ts`](src/auth.ts));
  Apple/Google OIDC + a dev mock verifier ([`src/auth-verifier.ts`](src/auth-verifier.ts), fail-closed
  by default). Identity per request = `resolveUserId` (bearer session → dev-header fallback).
- **Email sign-in (M3)** — `POST /auth/email/start` → 6-digit code via **Resend** →
  `POST /auth/email/verify` → the same bearer session. Code-based (OTP), not magic-link (a desktop app
  can't catch a link redirect). The raw code is never stored (`SHA-256(email:code)`); guarded by a
  10-min expiry + 5-attempt cap + single-active-code + 60s resend throttle ([`src/email-otp.ts`](src/email-otp.ts),
  [`src/mailer.ts`](src/mailer.ts)). **Fails closed (503) with no `RESEND_API_KEY`.**
- **Explanation + cost spine (M1)** — `/explain` cache-first + allowlist + single-flight DO +
  global-cap DO (fail-closed) + anon HIT-only by default, opened to a **bounded anon-generation
  sub-cap** (`ANON_DAILY_GENERATION_UNITS`, one shared global daily bucket reserved before the global
  cap, so signed-out lookup works without a forged-id flood draining the main budget). Word-layer
  generation runs on **Google Gemini**
  (`gemini-3.1-flash-lite`, via the Vercel AI SDK) when `GEMINI_API_KEY` is set, else fails closed.
- **FSRS + sync (M3a/M3b)** — `/review`, `/review/due`, `/words/claim`, `/sync` (server-authoritative
  fold, merge-precedence truth-table). `GET /words` carries per-unit FSRS (the memory meter, joined at
  the unit's epoch); `POST /words/:id/restore` un-deletes a tombstone, preserving FSRS.
- **Context layer + export (M5, T8)** — `/contexts`, `/explain/context` (D1 reservation quota),
  `/export` (Anki/CSV); context text + glosses envelope-encrypted at rest, hard-delete + log-hygiene.
- **Scheduled maintenance** (`scheduled()`): T8 retention purge, expired-reservation refund, expired/
  revoked-session purge, expired email-code + send-counter purge.

**Env-bound to go live (Worker Secrets):** `APPLE_CLIENT_ID` / `GOOGLE_CLIENT_ID` (comma-separated
audiences for real sign-in), `RESEND_API_KEY` + `EMAIL_FROM` (email sign-in delivery), `GEMINI_API_KEY`
(word-layer explanation generation), `CONTEXT_KEK` (T8 envelope key). Leave `DEV_TRUST_USER_HEADER` /
`DEV_TRUST_MOCK_AUTH` / `DEV_USE_MOCK_PROVIDER` **unset** in production (each is a bypass). The private
context layer stays fail-closed (no zero-retention AI vendor wired yet — D-BE-2).
_(The Miniflare/workerd multi-client integration harness — previously deferred — now exists: see
`test-integration/` + `pnpm test:integration`.)_

## Develop

```sh
pnpm install
pnpm typecheck                 # tsc --noEmit
bun test                       # fast per-module unit/in-process tests (the inner loop)
pnpm test:integration          # integration tests INSIDE workerd (real D1 + R2 + DOs)
wrangler dev                   # local (miniflare); placeholder D1 id is fine
```

`bun test` covers the per-module logic in-process (bun:sqlite, DOs stubbed). `pnpm test:integration`
(`@cloudflare/vitest-pool-workers`) runs `test-integration/*.integration.ts` inside workerd with the
**real** `wrangler.jsonc` bindings — exercising the `SingleFlight`/`GlobalBudget` Durable Objects, the
real-D1 encrypted-context BLOB path, and the multi-client sync interleave (ENG-5).

## Provision (needs a Cloudflare account)

```sh
wrangler d1 create capecho                 # paste database_id into wrangler.jsonc
wrangler r2 bucket create capecho-explanations
pnpm migrate:remote                        # apply migrations/ to the live D1
```

## Staging (an isolated test box)

`wrangler.jsonc` defines an `env.staging` Worker — its **own** D1, R2 cache, Durable Objects, secrets,
and AI budget, on the free `capecho-backend-staging.<account>.workers.dev` URL. It's where a service
change is verified end-to-end (the v3 cache rekey, billing webhooks, a new migration, on-device flows)
**without touching prod** data, the shared explanation cache, or the live budget. It mirrors prod
behaviour — no auth/provider mock flags are baked in.

> `/explain` *generation quality* needs no deploy: `bun run eval:grounded` calls the provider directly
> and runs the real `validate.ts` gate. Staging is for the *integration* surface (auth/sync/claim/
> export, webhooks, real R2/D1 cache semantics) that only a deployed, reachable Worker exercises.

One-time provisioning:

```sh
wrangler d1 create capecho-staging          # paste the id into wrangler.jsonc → env.staging
wrangler r2 bucket create capecho-explanations-staging
bun run migrate:staging                     # apply migrations/ to the staging D1

# Set only the secrets for what you're testing (each `--env staging`); a route 503s / fails soft
# when its secret is unset:
wrangler secret put GEMINI_API_KEY        --env staging   # /explain generation (cache-miss path)
wrangler secret put CONTEXT_KEK           --env staging   # encrypted-context layer (+ CONTEXT_KEK_VERSION var)
wrangler secret put RESEND_API_KEY        --env staging   # email-OTP send (sign-in)
# Billing (optional): STRIPE_SECRET_KEY / STRIPE_WEBHOOK_SECRET (Stripe TEST mode) + test price-id vars;
# APPLE_IAP_PRIVATE_KEY + APPLE_* vars with APPLE_ENVIRONMENT="Sandbox".

bun run deploy:staging                      # → https://capecho-backend-staging.<account>.workers.dev
```

Then verify against it:

```sh
bun run tail:staging                        # live logs

# Point a debug client build at staging (no code change — the origin is a dart-define):
flutter run --dart-define CAPECHO_API_BASE=https://capecho-backend-staging.<account>.workers.dev
```

Subsequent deploys are just `bun run deploy:staging` (and `bun run migrate:staging` after adding a
migration). Prod stays a deliberate, separate `bun run deploy` + `pnpm migrate:remote`.
