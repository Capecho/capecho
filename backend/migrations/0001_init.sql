-- Capecho D1 schema — v1. D1 is the single source of truth.
-- One consolidated initial migration: accounts + units + contexts + the FSRS event log/projection +
-- context-quota reservations + global-budget mirror + auth (sessions / email OTP) + the pre-login
-- claim ledger + success-metric events + ephemeral context previews + the beta waitlist + Pro
-- subscription billing/entitlement. Encodes the locked decisions (multi-target dedup,
-- reservation-row quota, FSRS event log as source of truth, soft-delete/resurrect, span offsets,
-- encrypted context, account-timezone quota, server-authoritative entitlement).

-- Accounts — single-provider identity (cross-provider linking deferred).
CREATE TABLE accounts (
  id                           TEXT PRIMARY KEY,                 -- uuid
  auth_provider                TEXT NOT NULL CHECK (auth_provider IN ('apple','google','email')),
  provider_subject             TEXT NOT NULL,                    -- stable subject from the provider
  email                        TEXT,                             -- human-readable sign-in id (Settings "Account"); nullable (Apple private-relay / no email claim); filled-if-null on a later sign-in, never clobbered. Identity, NOT T8 context — return to its owner, never log.
  iana_timezone                TEXT NOT NULL DEFAULT 'UTC',      -- per-account daily quota reset (DST/travel correct)
  learning_language            TEXT,                             -- default target_language for the overlay (canonical BCP-47)
  explanation_language         TEXT NOT NULL DEFAULT 'en',       -- explicit gloss language: en | zh-Hans | es
  explanation_follows_learning INTEGER NOT NULL DEFAULT 0 CHECK (explanation_follows_learning IN (0,1)), -- 1 = gloss in the learning language (immersion default), resolved server-side; new accounts are created with 1 (auth.ts createAccount)
  reminder_enabled             INTEGER NOT NULL DEFAULT 0 CHECK (reminder_enabled IN (0,1)), -- review-reminder pref (mobile-owned; the phone fires the local notification), synced via PATCH /account
  reminder_time                TEXT,                             -- local "HH:MM" 24h string, or NULL when unset
  -- Denormalized Pro-entitlement cache: the entitlement HORIZON (epoch ms). isPro = pro_until > now.
  -- NULL = never subscribed / fully lapsed. The authoritative value is recomputed from `subscriptions`
  -- as MAX(current_period_end) over non-refunded/non-revoked subs (entitlement.ts recomputeProUntil);
  -- this column is just the fast read. A manually-set pro_until (founder comp, A6) is safe ONLY while
  -- that account has no `subscriptions` rows — any applied subscription event recomputes (overwrites) it.
  pro_until                    INTEGER,
  created_at                   INTEGER NOT NULL,                 -- epoch ms
  deleted_at                   INTEGER,                          -- account hard-delete window marker (T8); NULL = active
  UNIQUE (auth_provider, provider_subject)
);

-- Units (saved word/phrase). Dedup key = (user_id, target_language, normalized_unit).
CREATE TABLE words (
  id                           TEXT PRIMARY KEY,
  user_id                      TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  target_language              TEXT NOT NULL,            -- canonical BCP-47 (script subtag where it disambiguates)
  surface_unit                 TEXT NOT NULL CHECK (length(surface_unit) > 0),  -- exactly what the user saved
  normalized_unit              TEXT NOT NULL CHECK (length(normalized_unit) > 0), -- dedup/cache key; never empty
  target_normalization_version TEXT NOT NULL,            -- the rule version that produced normalized_unit
  is_phrase                    INTEGER NOT NULL DEFAULT 0 CHECK (is_phrase IN (0,1)),
  -- explanation lifecycle (free word-level layer). Content lives in R2+CDN; D1 tracks state only.
  explanation_state            TEXT NOT NULL DEFAULT 'pending'
                                 CHECK (explanation_state IN ('pending','ready','language_unsupported','failed')),
  explanation_cache_key        TEXT,                     -- pointer into the shared R2 cache (NULL until ready)
  -- FSRS epoch: bumped on resurrect-on-resave so the event fold ignores pre-delete reviews (resets to new-card).
  fsrs_epoch                   INTEGER NOT NULL DEFAULT 0 CHECK (fsrs_epoch >= 0),
  created_at                   INTEGER NOT NULL,
  updated_at                   INTEGER NOT NULL,
  deleted_at                   INTEGER,                  -- soft-delete tombstone
  -- cache-key presence tracks lifecycle: a pointer exists only once the explanation is ready
  CHECK (explanation_cache_key IS NULL OR explanation_state = 'ready'),
  UNIQUE (id, user_id)                                   -- composite-FK target for child same-owner enforcement
);
-- Dedup: one unit per (user, target_language, normalized_unit). Tombstoned rows keep the key
-- (resurrect-on-resave updates the same row), so the unique index covers every row.
CREATE UNIQUE INDEX idx_words_dedup ON words (user_id, target_language, normalized_unit);
CREATE INDEX idx_words_user_active ON words (user_id) WHERE deleted_at IS NULL;

-- Contexts — 1:N per unit. Context text is sensitive (T8): encrypted at rest, never in logs.
CREATE TABLE word_contexts (
  id                  TEXT PRIMARY KEY,
  word_id             TEXT NOT NULL,
  user_id             TEXT NOT NULL,
  context_language    TEXT,                              -- per-context language (may differ from the unit's)
  -- encrypted-at-rest envelope (T8): ciphertext + per-record wrapped data key + nonce + key version.
  -- All three crypto fields are present together or absent together (context-less save).
  context_ciphertext  BLOB,
  context_wrapped_key BLOB,
  context_nonce       BLOB,
  context_key_version INTEGER,                           -- envelope key version (rotation)
  -- captured span over the (truncated) context, UTF-16 [start,end); render-clamped client-side.
  span_start          INTEGER,
  span_end            INTEGER,
  -- private context-gloss ("explain in this sentence") — also encrypted, never shared-cached.
  gloss_ciphertext    BLOB,
  gloss_wrapped_key   BLOB,
  gloss_nonce         BLOB,
  gloss_key_version   INTEGER,
  created_at          INTEGER NOT NULL,
  FOREIGN KEY (word_id, user_id) REFERENCES words(id, user_id) ON DELETE CASCADE,
  -- envelope integrity: a context (and a gloss) is either fully encrypted or fully absent
  CHECK ((context_ciphertext IS NULL AND context_wrapped_key IS NULL AND context_nonce IS NULL AND context_key_version IS NULL)
      OR (context_ciphertext IS NOT NULL AND context_wrapped_key IS NOT NULL AND context_nonce IS NOT NULL AND context_key_version IS NOT NULL)),
  CHECK ((gloss_ciphertext IS NULL AND gloss_wrapped_key IS NULL AND gloss_nonce IS NULL AND gloss_key_version IS NULL)
      OR (gloss_ciphertext IS NOT NULL AND gloss_wrapped_key IS NOT NULL AND gloss_nonce IS NOT NULL AND gloss_key_version IS NOT NULL)),
  -- captured span is paired (both set or both null) and well-formed over the half-open [start,end)
  CHECK ((span_start IS NULL AND span_end IS NULL)
      OR (span_start IS NOT NULL AND span_end IS NOT NULL AND span_start >= 0 AND span_end >= span_start)),
  -- composite-FK target: lets child rows (context_quota_reservations) enforce same-owner.
  UNIQUE (id, user_id)
);
CREATE INDEX idx_word_contexts_word ON word_contexts (word_id);

-- FSRS event log — the SOURCE OF TRUTH (ENG-5/7). Ordered replay by per-user server_seq;
-- the fold for a card uses only events whose card_epoch = words.fsrs_epoch (resurrect resets).
CREATE TABLE fsrs_events (
  id               TEXT PRIMARY KEY,                     -- client-generated uuid (idempotent ingest)
  user_id          TEXT NOT NULL,
  word_id          TEXT NOT NULL,
  card_epoch       INTEGER NOT NULL DEFAULT 0,           -- the unit's fsrs_epoch at ingest
  server_seq       INTEGER NOT NULL CHECK (server_seq > 0), -- per-user monotonic (server-assigned)
  rating           INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 4), -- again/hard/good/easy
  client_review_ts INTEGER NOT NULL,                     -- client timestamp (untrusted)
  clamped_elapsed  INTEGER NOT NULL CHECK (clamped_elapsed >= 0), -- server-clamped elapsed (no negative)
  -- Which surface produced the rating — 'app' (in-app review), 'widget' (the home-screen widget
  -- grade), or 'notification' (an actionable reminder, Phase 2). ATTRIBUTION ONLY: it is NOT folded
  -- into FSRS (the fold reads rating + clamped_elapsed in server_seq order — see refoldAndPersist),
  -- so it can't change any schedule. It exists to answer the widget RFC's core hypothesis — "does
  -- fragmented-time review actually happen?" — via /analytics. Lenient by design: stored verbatim
  -- (bounded client-side) rather than CHECK-constrained, so a future surface ('standby', 'control')
  -- needs no migration.
  source           TEXT NOT NULL DEFAULT 'app',
  created_at       INTEGER NOT NULL,
  FOREIGN KEY (word_id, user_id) REFERENCES words(id, user_id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX idx_fsrs_events_user_seq ON fsrs_events (user_id, server_seq);
CREATE INDEX idx_fsrs_events_word_epoch ON fsrs_events (word_id, card_epoch);

-- FSRS card state — a MATERIALIZED PROJECTION (cache of the fold over fsrs_events). NOT source of truth.
CREATE TABLE fsrs_cards (
  word_id          TEXT PRIMARY KEY,
  user_id          TEXT NOT NULL,
  card_epoch       INTEGER NOT NULL DEFAULT 0,           -- the epoch this projection reflects
  stability        REAL NOT NULL CHECK (stability > 0),
  difficulty       REAL NOT NULL CHECK (difficulty > 0),
  due_at           INTEGER NOT NULL,                     -- server-authoritative; clients render, never compute
  last_review_at   INTEGER,
  reps             INTEGER NOT NULL DEFAULT 0 CHECK (reps >= 0),
  lapses           INTEGER NOT NULL DEFAULT 0 CHECK (lapses >= 0),
  state            TEXT NOT NULL DEFAULT 'new'
                     CHECK (state IN ('new','learning','review','relearning')),
  last_applied_seq INTEGER NOT NULL DEFAULT 0 CHECK (last_applied_seq >= 0), -- highest fsrs_events.server_seq folded in
  FOREIGN KEY (word_id, user_id) REFERENCES words(id, user_id) ON DELETE CASCADE
);
CREATE INDEX idx_fsrs_cards_due ON fsrs_cards (user_id, due_at);

-- Context-explanation quota = D1 reservation rows (ENG-2): reserve-before-generate, refund-on-fail,
-- idempotent retry, TTL-expiry refund (T10). Daily cap counted per (user_id, quota_day), where
-- quota_day is the account-timezone date. The reservation is bound to its request so a reused
-- idempotency_key for a DIFFERENT request is rejected (M1 checks request_fingerprint).
CREATE TABLE context_quota_reservations (
  id                  TEXT PRIMARY KEY,
  user_id             TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  word_context_id     TEXT,                                -- what is being explained (composite FK below, same-owner)
  request_fingerprint TEXT NOT NULL,                     -- stable hash of the request; retry must match
  quota_day           TEXT NOT NULL,                     -- 'YYYY-MM-DD' in the account's IANA tz
  idempotency_key     TEXT NOT NULL,                     -- client-supplied; retry returns the same reservation
  state               TEXT NOT NULL DEFAULT 'reserved'
                        CHECK (state IN ('reserved','committed','refunded')),
  expires_at          INTEGER NOT NULL,                  -- TTL; a 'reserved' row past this is refundable
  created_at          INTEGER NOT NULL,
  committed_at        INTEGER,
  -- privacy boundary: the reserved context must belong to the reserving user. Composite FK is
  -- NULL-permissive — a reservation with no context skips the check (SQLite MATCH SIMPLE).
  FOREIGN KEY (word_context_id, user_id) REFERENCES word_contexts(id, user_id) ON DELETE CASCADE,
  UNIQUE (user_id, idempotency_key)
);
-- Daily cap check counts live (reserved-and-unexpired | committed) rows, so the index carries
-- state + expires_at; plus a partial index to sweep expired 'reserved' rows for refund.
CREATE INDEX idx_quota_day ON context_quota_reservations (user_id, quota_day, state, expires_at);
CREATE INDEX idx_quota_sweep ON context_quota_reservations (expires_at) WHERE state = 'reserved';

-- Global daily AI-spend cap mirror — the budget DO persists here, fail-closed. One row per UTC day.
CREATE TABLE global_budget (
  spend_day   TEXT PRIMARY KEY,                           -- 'YYYY-MM-DD' UTC
  spent_units INTEGER NOT NULL DEFAULT 0 CHECK (spent_units >= 0),
  updated_at  INTEGER NOT NULL
);

-- Pre-login claim ledger (US-SY.1). Row-level idempotent claim of a locally-captured unit into an
-- account: keyed by the stable client-row-id, SCOPED by account + a stable install id (not global),
-- so a partial-failure retry re-claims only un-drained rows and re-claiming a row is a no-op. The
-- word/context/claim-record writes are each idempotent (word dedup, deterministic context id, this
-- PK), with the claim-record written LAST as the completion marker — D1 has no interactive
-- transaction, so idempotent-retry is what guarantees no ghost rows.
CREATE TABLE claim_records (
  user_id       TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  install_id    TEXT NOT NULL,                 -- stable device/install id (scopes client_row_id)
  client_row_id TEXT NOT NULL,                 -- stable id of the local capture row
  word_id       TEXT NOT NULL,                 -- the account-side unit the row resolved to
  created_at    INTEGER NOT NULL,
  PRIMARY KEY (user_id, install_id, client_row_id),
  -- same-owner: the claimed unit must belong to the claiming account.
  FOREIGN KEY (word_id, user_id) REFERENCES words(id, user_id) ON DELETE CASCADE
);
CREATE INDEX idx_claim_records_word ON claim_records (word_id);

-- Session tokens for verified sign-in. An opaque bearer token issued after a provider
-- (Apple/Google/email) credential is verified. The RAW token is returned to the client exactly once
-- and is NEVER stored: the primary key is its SHA-256 hash, so a D1 dump can't be replayed as live
-- credentials (ENG-10). Lookups are by hash.
CREATE TABLE sessions (
  token_hash   TEXT PRIMARY KEY,                                 -- SHA-256(raw token), hex
  user_id      TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, -- account hard-delete (T8) drops sessions
  created_at   INTEGER NOT NULL,                                 -- epoch ms
  expires_at   INTEGER NOT NULL,                                 -- absolute expiry (epoch ms); resolve checks > now
  last_seen_at INTEGER NOT NULL,                                 -- set at issue (no per-request sliding write at MVP)
  revoked_at   INTEGER                                           -- sign-out marker; NULL = active
);
CREATE INDEX idx_sessions_user ON sessions (user_id);     -- list/revoke a user's sessions without scanning
CREATE INDEX idx_sessions_expiry ON sessions (expires_at); -- sweep expired/revoked rows in the maintenance cron

-- Email sign-in OTP. Code-based (not magic-link, which a menu-bar app can't reliably catch): request
-- a code (POST /auth/email/start), Capecho emails a 6-digit code via Resend, the client submits it
-- (POST /auth/email/verify) to mint the SAME bearer session as Apple/Google. ONE active code per
-- email (PRIMARY KEY): a new request REPLACES the prior one. The raw code is NEVER stored — the row
-- holds SHA-256(email:code). Brute force is bounded by a short expiry + a per-code attempt cap +
-- single-active-code + a per-email resend throttle.
CREATE TABLE email_codes (
  email      TEXT PRIMARY KEY,            -- normalized (trimmed + lowercased) recipient; one active code each
  code_hash  TEXT NOT NULL,              -- SHA-256(email:code), hex — never the raw code
  created_at INTEGER NOT NULL,           -- epoch ms; the resend throttle compares against this
  expires_at INTEGER NOT NULL,           -- absolute expiry (epoch ms); verify checks > now
  attempts   INTEGER NOT NULL DEFAULT 0  -- failed verify attempts on the CURRENT code; capped, then locked out
);
CREATE INDEX idx_email_codes_expiry ON email_codes (expires_at); -- swept by the maintenance cron once expired

-- Coarse abuse control for POST /auth/email/start (unauthenticated, triggers a real outbound send).
-- Counts code emails per IP and globally per UTC day; the route fails closed (429) once either cap
-- trips. Keyed by a coarse "bucket" string so one table covers both tiers; swept by the cron.
CREATE TABLE email_send_counters (
  bucket     TEXT PRIMARY KEY,            -- "global:<utcDay>" or "ip:<ip>:<utcDay>"
  count      INTEGER NOT NULL,            -- code emails attributed to this bucket today
  expires_at INTEGER NOT NULL             -- end-of-retention (epoch ms); cron deletes once passed
);
CREATE INDEX idx_email_send_counters_expiry ON email_send_counters (expires_at);

-- §14 success-metric events (CEO-10) feeding the After-M3 GATE. Append-only, low-volume: one row per
-- client-emitted metric event. Carries ONLY durations / counts / enums / booleans / opaque ids —
-- NEVER unit or context text (T8; enforced by the ingest validator AND the log-hygiene round-trip
-- test). `user_id` is NULL for pre-login (anonymous) events keyed only by `install_id`; ON DELETE SET
-- NULL so an account hard-delete de-identifies its events. install_id is forgeable → segment by it,
-- never trust it.
CREATE TABLE metric_events (
  id               TEXT PRIMARY KEY,                                  -- server-assigned uuid at ingest (never client-trusted)
  user_id          TEXT REFERENCES accounts(id) ON DELETE SET NULL,   -- NULL = anonymous (pre-login)
  install_id       TEXT NOT NULL,                                     -- client device id (forgeable; segment, don't trust)
  platform         TEXT NOT NULL,                                     -- 'macos' (the only emitter; segmentation axis)
  event_type       TEXT NOT NULL,                                     -- capture_completed | capture_presented | capture_abandoned | capture_failed | sync_attempted | sync_accepted
  client_row_id    TEXT,                                              -- links capture/sync events to a unit (chain-completeness); NULL where N/A
  client_ts        INTEGER NOT NULL,                                  -- client wall-clock ms at emit (BUCKETING only; durations are monotonic, inside metadata)
  received_at      INTEGER NOT NULL,                                  -- server receive ms (authoritative ordering / windowing)
  app_version      TEXT,                                              -- mixed-build readability in the readout
  contract_version INTEGER NOT NULL,                                  -- metric-event contract version (drift / forward-compat)
  metadata         TEXT NOT NULL                                      -- JSON: per-type numeric/enum/bool fields ONLY (validated; no free text)
);
CREATE INDEX idx_metric_events_window ON metric_events (platform, event_type, received_at); -- windowed scan by the gate readout
CREATE INDEX idx_metric_events_chain ON metric_events (event_type, client_row_id);          -- chain-completeness join

-- Fail-OPEN global daily insert ceiling — the abuse bound on the UNAUTHENTICATED ingest path. One row
-- per UTC day; when `accepted` reaches the cap, excess events are DROPPED (the client still gets 200,
-- capture is never affected) and tallied in `dropped` so the gate readout can tell "missing data"
-- from "real behavior". Deliberately overshoot-tolerant (read-then-insert, no DO).
CREATE TABLE metric_ingest_budget (
  day_key  TEXT PRIMARY KEY,            -- UTC 'YYYY-MM-DD'
  accepted INTEGER NOT NULL DEFAULT 0,
  dropped  INTEGER NOT NULL DEFAULT 0
);

-- Ephemeral context-explanation PREVIEW. The overlay can explain a word IN its captured sentence
-- BEFORE the word is saved (no word_context row exists yet). A preview is metered once (it draws the
-- same daily context quota), stored here transiently with a TTL, referenced by its id (the
-- `preview_handle`). On Save the gloss is ADOPTED onto the new word_context (no recharge); on dismiss
-- the row TTL-expires and is swept. PRIVACY (T8): the sentence + gloss are ENCRYPTED AT REST exactly
-- like word_contexts (envelope crypto, AAD-bound per field); only the headword + language tags are
-- plaintext.
CREATE TABLE context_previews (
  id                    TEXT PRIMARY KEY,            -- the preview_handle (opaque, user-scoped)
  user_id               TEXT NOT NULL,
  surface_unit          TEXT NOT NULL,               -- the headword (public dictionary data)
  target_language       TEXT NOT NULL,               -- canonical target of the unit
  context_language      TEXT,                        -- language of the sentence (defaults to target)
  span_start            INTEGER,                     -- optional unit span within the sentence
  span_end              INTEGER,

  -- the user's sentence, encrypted at rest (AAD 'preview-ctx:<id>')
  context_ciphertext    BLOB NOT NULL,
  context_wrapped_key   BLOB NOT NULL,
  context_nonce         BLOB NOT NULL,
  context_key_version   INTEGER NOT NULL,

  -- the metered gloss, encrypted at rest (AAD 'preview-gloss:<id>')
  gloss_ciphertext      BLOB NOT NULL,
  gloss_wrapped_key     BLOB NOT NULL,
  gloss_nonce           BLOB NOT NULL,
  gloss_key_version     INTEGER NOT NULL,
  explanation_language  TEXT NOT NULL,               -- canonical gloss language of the stored gloss
  prompt_version        TEXT NOT NULL,               -- which context prompt produced the gloss

  created_at            INTEGER NOT NULL,
  expires_at            INTEGER NOT NULL,            -- TTL; dismiss = let it expire (swept on cron)
  adopted_at            INTEGER,                     -- set once Save adopts the gloss (idempotent)

  -- span CHECK mirrors word_contexts: both null, or a non-negative start <= end pair.
  CHECK ((span_start IS NULL AND span_end IS NULL) OR (span_start >= 0 AND span_end >= span_start)),
  FOREIGN KEY (user_id) REFERENCES accounts (id) ON DELETE CASCADE
);
-- The expiry sweep. (Adoption looks the row up by its PRIMARY KEY id, so a user_id index would be dead.)
CREATE INDEX idx_context_previews_expiry ON context_previews (expires_at);

-- Marketing-site beta waitlist. The web "Join the Mac beta" form POSTs an email SAME-ORIGIN to
-- /api/beta-signup, which forwards it server-to-server (shared-secret header) to POST /beta-signup.
-- This is the ONLY place a pre-account email lands. `email` is the NORMALIZED address and the PRIMARY
-- KEY, so a repeat signup is idempotent (INSERT … ON CONFLICT DO NOTHING). Deliberately NOT a foreign
-- key to accounts(email): a waitlist signup happens BEFORE any account exists, and the two lifecycles
-- are independent.
CREATE TABLE beta_signups (
  email      TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL,
  source     TEXT,                          -- attribution only: the landing-page path (e.g. "/"), bounded + nullable, never gating
  country    TEXT                           -- visitor country (cf-ipcountry, 2-letter upper) when the edge provided one; NULL in local dev
);

-- Pro subscription billing + entitlement. Account-scoped, server-authoritative. Two rails: Stripe
-- (web + macOS-direct build) and Apple IAP (iOS + macOS Mac App Store build);
-- buy-once-unlock-everywhere. The live entitlement is the DENORMALIZED accounts.pro_until cache,
-- fully RECOMPUTABLE from `subscriptions`; `subscription_events` is the immutable idempotency +
-- audit log. Provider delivery is at-least-once AND out-of-order, so every state mutation is
-- idempotent (UNIQUE provider_event_id) and monotonic (subscriptions.last_event_ts guards a stale
-- event from downgrading a payer — eng-review C1).

-- One row per provider subscription (a Stripe subscription / an Apple original-transaction).
CREATE TABLE subscriptions (
  id                       TEXT PRIMARY KEY,                  -- our uuid
  user_id                  TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  provider                 TEXT NOT NULL CHECK (provider IN ('stripe','apple')),
  provider_subscription_id TEXT NOT NULL,                     -- Stripe subscription id / Apple originalTransactionId
  status                   TEXT NOT NULL
                             CHECK (status IN ('active','trialing','grace_period','canceled','expired','revoked','refunded')),
  current_period_end       INTEGER,                           -- entitlement horizon (epoch ms); NULL until known
  cancel_at_period_end     INTEGER NOT NULL DEFAULT 0 CHECK (cancel_at_period_end IN (0,1)),
  -- monotonic guard: the provider event time of the last APPLIED state change. A delivery whose event
  -- time is <= this is stale (out-of-order / replay) and must not mutate status/period (C1). The
  -- webhook handlers pair this with a canonical provider-API fetch on key events (OV3), so even
  -- same-second events converge to the live truth.
  last_event_ts            INTEGER NOT NULL DEFAULT 0,
  created_at               INTEGER NOT NULL,
  updated_at               INTEGER NOT NULL,
  -- one subscription per provider id ⇒ the same Apple original-transaction (or Stripe sub) maps to
  -- exactly ONE account; restoring it into a 2nd Capecho account is rejected by this constraint
  -- (test-plan "unique sub per account").
  UNIQUE (provider, provider_subscription_id)
);
CREATE INDEX idx_subscriptions_user ON subscriptions (user_id);

-- Immutable billing-event log: idempotency (UNIQUE provider_event_id ⇒ a replayed webhook is a no-op)
-- + an audit trail. NEVER updated. Carries the provider's sub id (JOIN key to `subscriptions`) rather
-- than an FK, so an event for a not-yet-created sub still records cleanly. user_id is de-identified on
-- account hard-delete (T8). `payload` holds a COMPACT billing summary only — never card data, billing
-- address, or any user content (no captured sentences ever touch this rail).
CREATE TABLE subscription_events (
  id                       TEXT PRIMARY KEY,                  -- our uuid
  provider                 TEXT NOT NULL CHECK (provider IN ('stripe','apple')),
  provider_event_id        TEXT NOT NULL,                     -- Stripe event.id / Apple notificationUUID
  provider_subscription_id TEXT,                              -- the sub this event concerns (JOIN to subscriptions); NULL for account-level events
  user_id                  TEXT REFERENCES accounts(id) ON DELETE SET NULL, -- denormalized; NULL after account delete
  type                     TEXT NOT NULL,                     -- raw provider event/notification type (audit)
  event_ts                 INTEGER NOT NULL,                  -- provider event time (the monotonic ordering source)
  payload                  TEXT,                              -- compact JSON billing summary (no PII / no user content)
  received_at              INTEGER NOT NULL,                  -- server receive time
  UNIQUE (provider, provider_event_id)
);
CREATE INDEX idx_subscription_events_sub ON subscription_events (provider, provider_subscription_id);
