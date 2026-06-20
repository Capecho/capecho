/// <reference types="@cloudflare/workers-types" />
import { fromD1 } from "./sql.ts";
import { fromR2 } from "./cache.ts";
import { BudgetLedger, type BudgetStore } from "./budget-logic.ts";
import { budgetClient, type BudgetWire } from "./budget-do-client.ts";
import { Coalescer } from "./single-flight.ts";
import { MockExplanationProvider } from "./providers/mock.ts";
import { UnconfiguredProvider } from "./providers/null.ts";
import { makeGeminiProvider, makeGeminiContextProvider } from "./providers/gemini-model.ts";
import {
  getWordExplanation,
  explainKey,
  type ExplainDeps,
  type ExplainRequest,
  type ExplainResult,
} from "./explain.ts";
import {
  saveWord,
  listWords,
  softDeleteWord,
  restoreWord,
  getWordById,
  markExplanationReady,
  markExplanationState,
} from "./words.ts";
import { canonicalizeBcp47, resolveExplanationLanguage, effectiveExplanationLanguage } from "@capecho/lang";
import { dedupKey } from "./dedup-key.ts";
import { costConfigFromEnv, freeWordCapFromEnv } from "./config.ts";
import { isPro, applySubscriptionUpdate } from "./entitlement.ts";
import { verifyStripeSignature, mapStripeEvent, buildCheckoutForm, createStripeCheckout, resolvePriceId } from "./billing/stripe.ts";
import {
  decodeJwsPayload,
  makeAppleApiClient,
  reconcileAppleSubscription,
  appleConfigFromEnv,
  appleExpectedEnvironment,
  type AppleNotificationPayload,
  type AppleTransactionInfo,
} from "./billing/apple.ts";
import { verifyAppleSignedJws } from "./billing/apple-jws.ts";
import {
  reconcileSubscriptions,
  reconcileDepsFromEnv,
  cancelSubscriptionsForAccount,
  stripeClientFromEnv,
} from "./billing/reconcile.ts";
import { utcDayKey, accountDayKey } from "./time.ts";
import { json, problem, attachment, userIdFrom, readJson } from "./http.ts";
import { collectExportRows, renderExport, type ExportFormat } from "./export.ts";
import { runScheduledSweeps, parseRetentionMs } from "./maintenance.ts";
import { envelopeCryptoFromEnv } from "./crypto.ts";
import { createContext, listContextsForWord, editContextText, deleteContext } from "./contexts.ts";
import { explainContext } from "./explain-context.ts";
import { explainContextPreview, adoptPreview } from "./context-preview.ts";
import { MockContextProvider } from "./providers/mock-context.ts";
import { UnconfiguredContextProvider } from "./providers/null-context.ts";
import { getAccount, updateAccountPrefs, parseAccountPatch, markAccountDeleted } from "./accounts.ts";
import { ingestReview, listDueReviews, replayReviews, parseSyncEvent, normalizeSource, DEFAULT_NEW_CARD_CAP } from "./review.ts";
import { claimRows, type ClaimRowInput } from "./claim.ts";
import { parseMetricBatch, ingestMetricEvents, metricsConfigFromEnv, computeGateReport, isMetricsAdmin, MAX_BODY_BYTES } from "./metrics.ts";
import { computeAnalyticsReport } from "./analytics.ts";
import { ANALYTICS_DASHBOARD_HTML } from "./analytics-dashboard.ts";
import type { RatingValue } from "./fsrs.ts";
import {
  getOrCreateAccount,
  issueSession,
  resolveSession,
  revokeSession,
  parseSessionTtlMs,
  isValidIanaTimeZone,
  type AuthProvider,
} from "./auth.ts";
import { selectVerifier } from "./auth-verifier.ts";
import {
  normalizeEmail,
  isValidEmail,
  generateOtpCode,
  startEmailCode,
  verifyEmailCode,
  clearEmailCode,
  reserveEmailSend,
  parseSendCap,
  DEFAULT_EMAIL_PER_IP_DAILY_CAP,
  DEFAULT_EMAIL_GLOBAL_DAILY_CAP,
} from "./email-otp.ts";
import { selectMailer } from "./mailer.ts";
import { recordBetaSignup } from "./beta-signup.ts";

export interface Env {
  DB: D1Database;
  EXPLANATION_CACHE: R2Bucket;
  GLOBAL_BUDGET: DurableObjectNamespace;
  SINGLE_FLIGHT: DurableObjectNamespace;
  // Cost-spine config (Worker vars / secrets; all optional — see config.ts defaults).
  CONTEXT_DAILY_CAP?: string;
  GLOBAL_DAILY_BUDGET_UNITS?: string;
  ANON_DAILY_GENERATION_UNITS?: string;
  RESERVATION_TTL_MS?: string;
  // Free saved-word cap N (the Pro lever; config.ts default 200 — a LAUNCH PLACEHOLDER, calibrate
  // before public launch). Positive int; malformed → default. Pro accounts bypass it.
  FREE_WORD_CAP?: string;
  // Billing — Stripe rail (web + macOS-direct build). The webhook SIGNING secret (whsec_…); a SECRET,
  // set via `wrangler secret put STRIPE_WEBHOOK_SECRET`, never a plaintext var. Unset ⇒ POST
  // /billing/stripe/webhook fails closed (503): an unconfigured deployment can't be tricked into
  // applying forged entitlement events.
  STRIPE_WEBHOOK_SECRET?: string;
  // Stripe buy path (POST /billing/stripe/checkout). The API SECRET key (sk_…; `wrangler secret put`)
  // + the two recurring Price ids (founder-created — vars, not secrets). Optional success/cancel
  // redirect URLs (default to capecho.com). Any missing piece ⇒ the buy path is 503 (fail closed).
  STRIPE_SECRET_KEY?: string;
  STRIPE_PRICE_ID_MONTHLY?: string;
  STRIPE_PRICE_ID_ANNUAL?: string;
  STRIPE_SUCCESS_URL?: string;
  STRIPE_CANCEL_URL?: string;
  // Billing — Apple IAP rail (iOS + macOS Mac App Store build). The App Store Server API credentials:
  // the .p8 private key (SECRET; `wrangler secret put APPLE_IAP_PRIVATE_KEY`) + its Key ID + the
  // Issuer ID + the app bundle id (vars). Any missing piece ⇒ the Apple routes 503 (fail closed).
  // APPLE_ENVIRONMENT ("Production" default | "Sandbox") gates which environment's triggers are honored,
  // so a sandbox notification can't grant production Pro.
  APPLE_IAP_PRIVATE_KEY?: string;
  APPLE_IAP_KEY_ID?: string;
  APPLE_IAP_ISSUER_ID?: string;
  APPLE_IAP_BUNDLE_ID?: string;
  APPLE_ENVIRONMENT?: string;
  // §14 metric ingest (CEO-10). METRICS_DAILY_INSERT_CAP = fail-open daily insert ceiling on the
  // unauthenticated POST /metrics path (default 1,000,000; positive int, malformed → default).
  // METRICS_ADMIN_TOKEN = bearer for the GET /metrics/gate readout (unset ⇒ the readout 401s for
  // everyone — there is no admin role in the schema, so the token IS the gate).
  METRICS_DAILY_INSERT_CAP?: string;
  METRICS_ADMIN_TOKEN?: string;
  // Dev/staging ONLY: trust the forgeable x-capecho-user-id header as the account id. Unset in
  // production — real callers authenticate with a Bearer session token (M3 auth) instead.
  DEV_TRUST_USER_HEADER?: string;
  // Dev/staging ONLY: accept the deterministic MockIdentityVerifier for POST /auth/session
  // (JSON {sub,email} credential, no signature) so the sign-in→session→authed-route flow is
  // exercisable without real OAuth apps. Unset in production ⇒ auth FAILS CLOSED unless a real
  // provider client id is configured below.
  DEV_TRUST_MOCK_AUTH?: string;
  // Real OIDC audiences (the only env-bound part of provider verification — the JWKS + issuers
  // are fixed). COMMA-SEPARATED list of accepted token `aud`s per provider, because a multi-platform
  // app issues different audiences (Apple: app Bundle ID for native iOS/macOS, a Services ID for
  // web/Android; Google: per-platform client ids, or one web "server" client id used everywhere).
  // Unset ⇒ that provider is not configured (its sign-in fails). Neither set (and no mock) ⇒ all
  // sign-in fails closed.
  APPLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_ID?: string;
  // Session lifetime in ms (default 90 days). Plain positive integer; malformed ⇒ default.
  SESSION_TTL_MS?: string;
  // Email sign-in (OTP code) delivery via Resend. RESEND_API_KEY = a Resend API key (Worker
  // Secret); EMAIL_FROM = the verified sender ("Capecho <login@your-domain>"). Unset ⇒ email
  // sign-in is unconfigured and FAILS CLOSED (503), except in local dev where DEV_TRUST_MOCK_AUTH
  // routes codes to the Worker console instead of sending. The public WORD/Apple/Google paths are
  // unaffected.
  RESEND_API_KEY?: string;
  EMAIL_FROM?: string;
  // Abuse caps for /auth/email/start (positive integers; defaults 50 per-IP / 1000 global per UTC
  // day). Bound outbound code emails so the unauthenticated endpoint can't email-bomb third parties
  // or run up Resend cost; tune the global cap to your Resend plan.
  EMAIL_PER_IP_DAILY_CAP?: string;
  EMAIL_GLOBAL_DAILY_CAP?: string;
  // Dev ONLY: use the deterministic mock explanation provider (takes precedence over a real key).
  // In production leave this unset: with GEMINI_API_KEY set, the real Gemini provider runs; with
  // neither, generation FAILS CLOSED (UnconfiguredProvider) so a mock can't silently poison the
  // shared public cache with fake definitions.
  DEV_USE_MOCK_PROVIDER?: string;
  // Word-layer explanation generation (free layer). GEMINI_API_KEY = a Google Generative Language
  // API key (Worker Secret); unset ⇒ word-layer generation fails closed. GEMINI_MODEL overrides the
  // WORD layer's default model; GEMINI_CONTEXT_MODEL overrides the CONTEXT layer's — the two layers
  // have separate eval-chosen defaults (gemini.ts). NOTE: the private context layer stays
  // fail-closed until a zero-retention contract is confirmed (T8).
  GEMINI_API_KEY?: string;
  GEMINI_MODEL?: string;
  GEMINI_CONTEXT_MODEL?: string;
  // T8 envelope encryption (ENG-9). CONTEXT_KEK = base64 32-byte master key (Worker
  // Secret); CONTEXT_KEK_VERSION = its integer version (default 1). Unset in a fresh
  // env ⇒ context endpoints FAIL CLOSED (503) rather than store plaintext.
  CONTEXT_KEK?: string;
  CONTEXT_KEK_VERSION?: string;
  // Account hard-delete retention window in ms (T8 purge sweep). Unset → 30-day default.
  DELETE_RETENTION_MS?: string;
  // Marketing-site beta waitlist (POST /beta-signup). A shared secret that the web app's SAME-ORIGIN
  // /api/beta-signup proxy presents as `x-capecho-beta-token`; the browser never sees it. This is the
  // ONLY auth on that endpoint (there is no account yet at signup), so it is NOT a public route. Unset
  // ⇒ /beta-signup FAILS CLOSED (503), matching the email/encryption posture — never silently accept.
  BETA_SIGNUP_TOKEN?: string;
}

const trustsUserHeader = (env: Env): boolean => env.DEV_TRUST_USER_HEADER === "true";

const uuid = (): string => crypto.randomUUID();

/**
 * Resolve the account id for a request. The real path is a Bearer session token (M3 auth):
 * `Authorization: Bearer <token>` → hash → sessions lookup (expiry + revoke + account-not-deleted).
 * A presented-but-invalid Bearer token resolves to null (→ 401) — it is NOT silently downgraded to
 * anonymous. With NO Bearer header, fall back to the dev/staging `x-capecho-user-id` trust header
 * (so the existing header-auth tests + local dev keep working). In production both the dev header
 * and mock auth are unset, so identity comes only from a verified session.
 */
async function resolveUserId(request: Request, env: Env): Promise<string | null> {
  const authz = request.headers.get("authorization");
  if (authz && /^Bearer\s+/i.test(authz)) {
    const token = authz.replace(/^Bearer\s+/i, "").trim();
    if (!token) return null;
    return resolveSession(fromD1(env.DB), token, Date.now());
  }
  return userIdFrom(request, trustsUserHeader(env));
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const route = `${request.method} ${url.pathname}`;

    if (url.pathname === "/health") return json({ ok: true, service: "capecho-backend" });

    try {
      // Auth (M3): verify a provider credential → account → bearer session.
      if (route === "POST /auth/session") return await handleAuthSession(request, env);
      if (route === "POST /auth/email/start") return await handleEmailStart(request, env);
      if (route === "POST /auth/email/verify") return await handleEmailVerify(request, env);
      if (route === "POST /auth/signout") return await handleSignout(request, env);
      if (route === "GET /auth/me") return await handleAuthMe(request, env);
      if (route === "PATCH /account") return await handlePatchAccount(request, env);
      if (route === "DELETE /account") return await handleDeleteAccount(request, env);

      // Marketing-site beta waitlist (shared-secret, server-to-server from the web proxy only).
      if (route === "POST /beta-signup") return await handleBetaSignup(request, env);

      // Billing webhooks (server-authoritative entitlement). Signature-verified, idempotent, monotonic.
      if (route === "POST /billing/stripe/webhook") return await handleStripeWebhook(request, env);
      // Stripe buy path — an authed user starts a Checkout Session; returns the redirect URL.
      if (route === "POST /billing/stripe/checkout") return await handleStripeCheckout(request, env);
      // Apple App Store Server Notifications V2 (server-to-server) + StoreKit2 client instant-unlock.
      if (route === "POST /billing/apple/notifications") return await handleAppleNotifications(request, env);
      if (route === "POST /billing/apple/verify") return await handleAppleVerify(request, env);

      if (route === "POST /words") return await handleCreateWord(request, env);
      if (route === "GET /words") return await handleListWords(request, env);
      if (route === "GET /explain") return await handleExplain(request, env, url);

      if (request.method === "DELETE" && /^\/words\/[^/]+$/.test(url.pathname)) {
        return await handleDeleteWord(request, env, url);
      }
      // POST /words/:id/restore — un-delete a tombstoned unit (preserves its FSRS; see restoreWord).
      if (request.method === "POST" && /^\/words\/[^/]+\/restore$/.test(url.pathname)) {
        return await handleRestoreWord(request, env, url);
      }

      // Context layer (private, encrypted at rest — T8).
      if (route === "POST /contexts") return await handleCreateContext(request, env);
      if (route === "GET /contexts") return await handleListContexts(request, env, url);
      if (route === "POST /explain/context") return await handleExplainContext(request, env);
      if (route === "POST /explain/context/preview") return await handleExplainContextPreview(request, env);
      if (/^\/contexts\/[^/]+$/.test(url.pathname)) {
        if (request.method === "PATCH") return await handleEditContext(request, env, url);
        if (request.method === "DELETE") return await handleDeleteContext(request, env, url);
      }

      // Server-authoritative FSRS review (M3a).
      if (route === "POST /review") return await handleReview(request, env);
      if (route === "GET /review/due") return await handleReviewDue(request, env, url);

      // Cross-device sync + pre-login claim (M3b).
      if (route === "POST /words/claim") return await handleClaim(request, env);
      if (route === "POST /sync") return await handleSync(request, env);

      // Anki/CSV export (M5, demand #6 + distribution wedge).
      if (route === "GET /export") return await handleExport(request, env, url);

      // §14 success-metric ingest (CEO-10) — feeds the After-M3 GATE. ANONYMOUS (install_id) accepted.
      if (route === "POST /metrics") return await handleMetrics(request, env);
      // The After-M3 GATE readout (CEO-7) — admin-token gated.
      if (route === "GET /metrics/gate") return await handleMetricsGate(request, env, url);
      // First-party retention/engagement readout (§14/§16) — admin-token gated, no third-party SDK.
      if (route === "GET /analytics/summary") return await handleAnalyticsSummary(request, env, url);
      // Self-contained admin dashboard (shell only — the data fetch it makes is token-gated).
      if (route === "GET /analytics/dashboard") {
        return new Response(ANALYTICS_DASHBOARD_HTML, { headers: { "content-type": "text/html; charset=utf-8" } });
      }

      return problem("not_found", 404);
    } catch (err) {
      // Never leak internals (or any context text — T8) into the response.
      console.error("unhandled", { route, name: (err as Error)?.name });
      return problem("internal_error", 500);
    }
  },

  // Cron-triggered maintenance (see wrangler.jsonc `triggers.crons`): T8 retention purge +
  // expired-reservation refund. Idempotent and pure-D1; logs counts (no PII) for observability.
  async scheduled(_controller: ScheduledController, env: Env, _ctx: ExecutionContext): Promise<void> {
    // STRICT parse — a malformed DELETE_RETENTION_MS must fail safe to the 30-day default, never
    // collapse the hard-delete window (parseRetentionMs rejects "30d"/"2.6e9"/"0"/garbage).
    const retentionMs = parseRetentionMs(env.DELETE_RETENTION_MS);
    const now = Date.now();
    // No try/catch by design: a throw surfaces to Cron Trigger metrics rather than masking a
    // failed purge/refund as a healthy run.
    const result = await runScheduledSweeps(fromD1(env.DB), now, retentionMs);
    console.log("scheduled_sweep", result);
    // Billing reconciliation (T6): re-fetch authoritative provider state for live subs — the backstop
    // for missed / out-of-order webhooks. No-op when no provider is configured (no network calls); each
    // sub's own errors are caught + counted, so a transient provider blip never fails the whole run.
    const reconciled = await reconcileSubscriptions(fromD1(env.DB), reconcileDepsFromEnv(env, uuid), now);
    console.log("billing_reconcile", reconciled);
  },
} satisfies ExportedHandler<Env>;

// --- /auth (M3) --------------------------------------------------------------
// POST /auth/session verifies a provider credential → finds/creates the account → issues a bearer
// session (raw token returned once). POST /auth/signout revokes the presented session (idempotent).
// GET /auth/me returns the signed-in account. After sign-in the client claims its pre-login local
// captures via the existing POST /words/claim (install_id + rows) — auth doesn't claim them itself.

interface AuthSessionBody {
  provider?: unknown;
  credential?: unknown;
  timezone?: unknown;
  learning_language?: unknown;
}

function accountView(
  userId: string,
  account: {
    auth_provider: string;
    email: string | null;
    iana_timezone: string;
    explanation_language: string;
    explanation_follows_learning: number;
    learning_language: string | null;
    reminder_enabled: number;
    reminder_time: string | null;
    pro_until: number | null;
  },
  now: number,
) {
  const followsLearning = account.explanation_follows_learning === 1;
  return {
    id: userId,
    // Pro entitlement (server-authoritative). Clients render the paywall/cap state off `pro`; a forged
    // client value never grants access (every Pro-gated server path re-checks pro_until). `pro_until`
    // (epoch ms, null = free) lets Settings show the renewal/expiry horizon.
    pro: isPro(account, now),
    pro_until: account.pro_until,
    // Identity for the Settings "Account" row: which provider this account signed in with, and the
    // email it carries (null when the provider shared none — e.g. Apple private relay).
    provider: account.auth_provider,
    email: account.email,
    iana_timezone: account.iana_timezone,
    // `explanation_language` is the EFFECTIVE gloss language (resolved server-side) so every client
    // just reads it for glosses; `explanation_follows_learning` lets Settings render the "Same as
    // learning language" state (when on, the effective value equals the resolved learning language).
    explanation_language: effectiveExplanationLanguage(
      followsLearning,
      account.explanation_language,
      account.learning_language,
    ),
    explanation_follows_learning: followsLearning,
    learning_language: account.learning_language,
    reminder_enabled: account.reminder_enabled === 1,
    reminder_time: account.reminder_time,
  };
}

async function handleAuthSession(request: Request, env: Env): Promise<Response> {
  const body = await readJson<AuthSessionBody>(request);
  // Email has its own verified routes (POST /auth/email/start + /auth/email/verify); /auth/session is
  // OIDC-only. Rejecting "email" here closes the dev-mock bypass where a forgeable {sub:"victim@…"}
  // credential could otherwise mint an email-provider account WITHOUT a delivered code (CR P2-3).
  if (!body || (body.provider !== "apple" && body.provider !== "google")) {
    return problem("bad_request", 400, "provider must be 'apple' or 'google' (use /auth/email/* for email sign-in)");
  }
  if (typeof body.credential !== "string" || body.credential.length === 0) {
    return problem("bad_request", 400, "credential is required");
  }
  const provider = body.provider as AuthProvider;

  const verified = await selectVerifier(env).verify(provider, body.credential);
  if ("error" in verified) {
    // Never echo the verifier's internal reason to the client (it can leak token internals);
    // log a non-PII tag for debugging instead.
    console.error("auth_verify_failed", { provider, reason: verified.error });
    return problem("auth_failed", 401, "could not verify sign-in");
  }

  const sql = fromD1(env.DB);
  const now = Date.now();
  // First-create only: the client's IANA tz (for the per-account quota day) + an optional default
  // learning language. An existing account keeps its stored values (getOrCreateAccount).
  const timezone =
    typeof body.timezone === "string" && isValidIanaTimeZone(body.timezone) ? body.timezone : "UTC";
  const learningLanguage =
    typeof body.learning_language === "string" ? canonicalizeBcp47(body.learning_language) : null;

  const userId = await getOrCreateAccount(
    sql,
    { provider: verified.provider, subject: verified.subject, timezone, learningLanguage, email: verified.email ?? null },
    now,
    uuid,
  );
  const session = await issueSession(sql, userId, now, parseSessionTtlMs(env.SESSION_TTL_MS));
  const account = await getAccount(sql, userId);
  if (!account) return problem("internal_error", 500); // just upserted — unreachable in practice
  return json({ token: session.token, expires_at: session.expiresAt, user: accountView(userId, account, now) });
}

async function handleSignout(request: Request, env: Env): Promise<Response> {
  // Idempotent: signing out with no token, or an already-revoked one, still returns ok.
  const authz = request.headers.get("authorization");
  if (authz && /^Bearer\s+/i.test(authz)) {
    const token = authz.replace(/^Bearer\s+/i, "").trim();
    if (token) await revokeSession(fromD1(env.DB), token, Date.now());
  }
  return json({ status: "signed_out" });
}

async function handleAuthMe(request: Request, env: Env): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401);
  const account = await getAccount(fromD1(env.DB), userId);
  if (!account) return problem("unauthorized", 401);
  return json({ user: accountView(userId, account, Date.now()) });
}

// --- POST /beta-signup (marketing-site waitlist) -----------------------------
// Record a "Join the Mac beta" email into the beta_signups table. NOT a public
// endpoint: the web app's same-origin /api/beta-signup proxy forwards here server-to-server with the
// shared BETA_SIGNUP_TOKEN, so there's no CORS surface and no open cross-origin write. Unset token ⇒
// fail closed (503). The response is a flat ok for both a fresh add and a repeat (never an oracle for
// which addresses are already on the list); a malformed/invalid email is the only 4xx beyond auth.

interface BetaSignupBody {
  email?: unknown;
  source?: unknown;
  country?: unknown;
}

async function handleBetaSignup(request: Request, env: Env): Promise<Response> {
  const expected = env.BETA_SIGNUP_TOKEN;
  if (!expected) return problem("beta_signup_unavailable", 503, "beta signup is not configured");
  // Constant-ish secret compare: a plain mismatch is fine here — the token is a high-entropy server
  // secret, not a short user code, so this isn't a meaningful timing oracle.
  const presented = request.headers.get("x-capecho-beta-token") ?? "";
  if (presented.length === 0 || presented !== expected) return problem("unauthorized", 401);

  const body = await readJson<BetaSignupBody>(request);
  if (!body || typeof body.email !== "string") return problem("bad_request", 400, "email is required");

  const result = await recordBetaSignup(fromD1(env.DB), {
    email: body.email,
    now: Date.now(),
    source: typeof body.source === "string" ? body.source : null,
    country: typeof body.country === "string" ? body.country : null,
  });
  if (result.status === "invalid_email") return problem("bad_request", 400, "a valid email is required");
  return json({ status: "ok" });
}

// --- POST /billing/stripe/webhook (Stripe rail: web + macOS-direct) ----------
// Fulfillment of a Stripe subscription into server-authoritative entitlement. The signature is
// verified over the RAW body BEFORE any field is trusted; a verified event maps to a SubscriptionUpdate
// that applySubscriptionUpdate applies idempotently (UNIQUE provider_event_id) + monotonically. We
// always ACK (200) once the signature is valid — even for ignored/unlinked events — so Stripe doesn't
// retry a well-formed but non-actionable event forever; only a bad/missing signature is a 4xx, and an
// unconfigured secret is 503 (fail closed). The Capecho account is carried in the subscription's
// metadata.capecho_user_id (set on the Checkout Session at buy time).
async function handleStripeWebhook(request: Request, env: Env): Promise<Response> {
  const secret = env.STRIPE_WEBHOOK_SECRET;
  if (!secret) return problem("billing_unconfigured", 503, "stripe webhook is not configured");

  const rawBody = await request.text(); // RAW bytes — the signature is over these, not re-serialized JSON
  const verified = await verifyStripeSignature(rawBody, request.headers.get("stripe-signature"), secret, Date.now());
  if (!verified.ok) {
    console.error("stripe_sig_invalid", { reason: verified.reason });
    return problem("invalid_signature", 400);
  }

  let event: unknown;
  try {
    event = JSON.parse(rawBody);
  } catch {
    return problem("bad_request", 400, "event body is not JSON");
  }

  const mapped = mapStripeEvent(event);
  if (mapped.kind === "ignored") return json({ received: true, ignored: mapped.reason });
  if (mapped.kind === "unlinked") {
    // A real subscription event we can't attribute to an account (no capecho_user_id). Ack so Stripe
    // stops retrying; log for investigation (the buy path must always stamp metadata.capecho_user_id).
    console.error("stripe_event_unlinked", { reason: mapped.reason });
    return json({ received: true, unlinked: true });
  }

  const out = await applySubscriptionUpdate(fromD1(env.DB), { ...mapped.update, now: Date.now(), newId: uuid });
  if (!out.applied && out.reason === "account_missing") {
    // The capecho_user_id no longer resolves to a live account (e.g. hard-purged between checkout and a
    // late event). Ack so Stripe stops retrying; log for investigation.
    console.error("stripe_event_account_missing", { sub: mapped.update.providerSubscriptionId });
  }
  return json({ received: true, applied: out.applied });
}

// --- POST /billing/stripe/checkout (Stripe buy path) -------------------------
// An authed user starts a subscription purchase. We create a Stripe Checkout Session stamped with the
// account id (so the fulfillment webhook can attribute it) and return its redirect URL; the client
// opens it. The session, not the client, is the source of truth — fulfillment happens via the webhook.
// `plan` selects monthly vs annual. Fails closed (503) if the secret key or the chosen price is unset.
async function handleStripeCheckout(request: Request, env: Env): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401, "sign-in required to subscribe");
  const secret = env.STRIPE_SECRET_KEY;
  if (!secret) return problem("billing_unconfigured", 503, "stripe is not configured");

  const body = await readJson<{ plan?: unknown }>(request);
  const plan = body?.plan === "annual" ? "annual" : "monthly";
  const priceRef = plan === "annual" ? env.STRIPE_PRICE_ID_ANNUAL : env.STRIPE_PRICE_ID_MONTHLY;
  if (!priceRef) return problem("billing_unconfigured", 503, `no ${plan} price configured`);
  // The configured value may be a Price id (price_…) OR a lookup_key (a readable alias set in Stripe).
  // Checkout needs the real Price id, so resolve it; a price_… passes through unchanged.
  const priceId = await resolvePriceId(secret, priceRef);
  if (!priceId) return problem("billing_unconfigured", 503, `no active price for the ${plan} plan`);

  const account = await getAccount(fromD1(env.DB), userId);
  const form = buildCheckoutForm({
    userId,
    email: account?.email ?? null,
    priceId,
    successUrl: env.STRIPE_SUCCESS_URL ?? "https://capecho.com/pro/success",
    cancelUrl: env.STRIPE_CANCEL_URL ?? "https://capecho.com/pro",
  });
  const result = await createStripeCheckout(secret, form);
  if (!result.ok) {
    console.error("stripe_checkout_failed", { status: result.status, reason: result.reason });
    return problem("checkout_failed", 502, "could not start checkout");
  }
  return json({ url: result.url });
}

// --- POST /billing/apple/notifications + /verify (Apple IAP rail) -------------
// API-AUTHORITY design (see billing/apple.ts): the inbound notification / StoreKit2 transaction is an
// UNTRUSTED trigger — we decode it only to read originalTransactionId, then refetch the authoritative
// state from the App Store Server API and apply THAT. A forged trigger can't grant entitlement (the
// authoritative response's appAccountToken is the linkage). notificationUUID = the idempotency key.
async function handleAppleNotifications(request: Request, env: Env): Promise<Response> {
  const cfg = appleConfigFromEnv(env);
  if (!cfg) return problem("billing_unconfigured", 503, "apple billing is not configured");

  const body = await readJson<{ signedPayload?: unknown }>(request);
  if (!body || typeof body.signedPayload !== "string") return problem("bad_request", 400, "signedPayload is required");
  const payload = decodeJwsPayload<AppleNotificationPayload>(body.signedPayload);
  if (!payload || typeof payload.notificationUUID !== "string" || !payload.data) {
    return problem("bad_request", 400, "malformed notification");
  }
  const txInfo = payload.data.signedTransactionInfo
    ? decodeJwsPayload<AppleTransactionInfo>(payload.data.signedTransactionInfo)
    : null;
  const originalTransactionId = txInfo?.originalTransactionId;
  // Some notification types carry no transaction (e.g. TEST) — ack without acting.
  if (!originalTransactionId) return json({ received: true, ignored: "no_transaction" });

  const result = await reconcileAppleSubscription(fromD1(env.DB), makeAppleApiClient(cfg), {
    originalTransactionId,
    environment: payload.data.environment ?? "Production",
    expectedEnvironment: appleExpectedEnvironment(env),
    providerEventId: payload.notificationUUID,
    eventType: payload.notificationType ?? "notification",
    now: Date.now(),
    newId: uuid,
  });
  if (result.status === "unavailable") {
    // Couldn't reach authoritative state — 502 so Apple retries; the reconciliation cron backstops.
    return problem("upstream_unavailable", 502, "could not fetch subscription status");
  }
  if (result.status === "unattributable") {
    console.error("apple_notification_unattributable", { reason: result.reason, type: payload.notificationType });
  }
  return json({ received: true, status: result.status });
}

// POST /billing/apple/verify — a StoreKit2 client posts its signed transaction right after purchase for
// an INSTANT unlock. Same API-authority flow; returns the resulting entitlement so the client flips to
// Pro without waiting for the server-to-server notification.
async function handleAppleVerify(request: Request, env: Env): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401, "sign-in required to verify a purchase");
  const cfg = appleConfigFromEnv(env);
  if (!cfg) return problem("billing_unconfigured", 503, "apple billing is not configured");

  const body = await readJson<{ signed_transaction?: unknown }>(request);
  if (!body || typeof body.signed_transaction !== "string") {
    return problem("bad_request", 400, "signed_transaction is required");
  }
  const now = Date.now();
  // Only a GENUINELY Apple-signed transaction may TRANSFER the subscription to this caller (an Apple ID's
  // active sub must unlock for whoever is signed in — Guideline 2.1(a) — the rejection this fixes). We
  // verify the full StoreKit2 JWS (cert chain → pinned Apple root + payload signature). On success we use
  // the SIGNATURE-VERIFIED payload for both the lookup key and the environment, so nothing driving a
  // transfer comes from an unverified decode. A forged/unsigned post → verified is null → fall back to the
  // (still-unverified) decode for the lookup key only and DON'T transfer: strict appAccountToken
  // attribution (safe — the caller gets Pro only if the sub is already theirs).
  const verified = await verifyAppleSignedJws<AppleTransactionInfo>(body.signed_transaction, { now });
  const tx = verified ?? decodeJwsPayload<AppleTransactionInfo>(body.signed_transaction);
  const originalTransactionId = tx?.originalTransactionId;
  if (!originalTransactionId) return problem("bad_request", 400, "malformed transaction");

  const sql = fromD1(env.DB);
  const result = await reconcileAppleSubscription(sql, makeAppleApiClient(cfg), {
    originalTransactionId,
    transferToUserId: verified ? userId : undefined,
    environment: tx?.environment ?? "Production",
    // Trust the transaction's OWN Apple-signed environment (and route the App Store Server API call to
    // it) rather than gating on the deployment's honored environment. The SAME production binary is
    // tested by App Review in Sandbox and run by real users in Production, so a Production deployment
    // must accept a Sandbox verify or the IAP can never unlock under review (Apple always tests IAP in
    // Sandbox). This is the client-initiated, authenticated re-sync path; the server-to-server
    // NOTIFICATION path keeps the deployment-environment gate (a prod box ignores sandbox notifications).
    // Abuse is bounded: a sandbox subscription's period is minutes, so it auto-expires almost immediately.
    expectedEnvironment: tx?.environment ?? "Production",
    // a client verify is a re-sync, not an Apple event — a unique id so it always processes the CURRENT
    // authoritative state (the monotonic signedDate guard still prevents applying anything stale).
    providerEventId: `verify:${uuid()}`,
    eventType: "verify",
    now,
    newId: uuid,
  });
  if (result.status === "unavailable") return problem("upstream_unavailable", 502, "could not verify with the App Store");

  // Cross-account, from the AUTHORITATIVE attribution: the sub was applied to a DIFFERENT existing Capecho
  // account than the caller, or is locked to another account in our records (account_mismatch). A truly
  // orphaned sub (its account is gone) stays `account_missing` → NOT flagged → a calm "not active", so the
  // client only says "already linked to another account" when it's genuinely true (a live other account).
  const attributedToOtherAccount =
    result.status === "applied" || result.status === "noop"
      ? result.attributedUserId !== userId
      : result.status === "unattributable" && result.reason === "account_mismatch";

  // Reflect the (possibly just-updated) server-authoritative entitlement back for instant unlock.
  const account = await getAccount(sql, userId);
  return json({
    pro: account ? isPro(account, now) : false,
    pro_until: account?.pro_until ?? null,
    status: result.status,
    attributed_to_other_account: attributedToOtherAccount,
  });
}

// --- POST /metrics (§14 instrumentation, CEO-10) -----------------------------
// Ingest a batch of client-emitted success-metric events feeding the After-M3 GATE. ANONYMOUS is
// allowed (install_id only, no session) so the pre-login first-capture latency — the single most
// important UX metric — is measured; a Bearer session, if present, attributes the events (an invalid
// token degrades to anonymous rather than 401 — never reject a metric for a stale session). Bounded:
// body ≤ 16KB, batch ≤ 50, fail-open daily insert ceiling. Events carry NO unit/context text
// (validated in metrics.ts; guarded by the log-hygiene round-trip test).

async function handleMetrics(request: Request, env: Env): Promise<Response> {
  const text = await request.text();
  if (new TextEncoder().encode(text).length > MAX_BODY_BYTES) return problem("payload_too_large", 413);
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    return problem("bad_json", 400);
  }
  const parsed = parseMetricBatch(raw);
  if (!parsed.ok) return problem(parsed.error, 400, parsed.detail);
  const userId = await resolveUserId(request, env); // null = anonymous; allowed here
  const result = await ingestMetricEvents(fromD1(env.DB), {
    userId,
    batch: parsed.value,
    now: Date.now(),
    dailyCap: metricsConfigFromEnv(env).dailyInsertCap,
    newId: uuid,
  });
  return json(result);
}

// GET /metrics/gate — the After-M3 GATE readout (CEO-7). Admin-gated by METRICS_ADMIN_TOKEN: there is
// no admin role in the schema, so the env token IS the gate (unset ⇒ 401 for everyone). Optional
// ?from&to (ms, received_at) window; defaults to all-time. Recomputable from the immutable events.
async function handleMetricsGate(request: Request, env: Env, url: URL): Promise<Response> {
  const authz = request.headers.get("authorization") ?? "";
  const m = /^Bearer\s+(.+)$/i.exec(authz);
  if (!isMetricsAdmin(m ? m[1]!.trim() : null, env.METRICS_ADMIN_TOKEN)) return problem("unauthorized", 401);
  const now = Date.now();
  const intParam = (name: string, fallback: number): number => {
    const raw = url.searchParams.get(name);
    if (raw === null) return fallback;
    const n = Number.parseInt(raw, 10);
    return Number.isFinite(n) && n >= 0 ? n : fallback;
  };
  const report = await computeGateReport(fromD1(env.DB), { from: intParam("from", 0), to: intParam("to", now), now });
  return json(report);
}

// GET /analytics/summary — first-party retention & engagement readout (§14 metrics / §16 kill-criteria).
// Computed from existing rows (accounts/sessions/words/fsrs_events/context_quota_reservations) — no new
// tracking, no new tables, no third-party SDK. Admin-gated by METRICS_ADMIN_TOKEN (the token IS the gate;
// unset ⇒ 401 for everyone), same as the GATE readout. Optional ?quotaCap (default 10) sizes the free
// context-explanation cap for the willingness-to-pay signal.
async function handleAnalyticsSummary(request: Request, env: Env, url: URL): Promise<Response> {
  const authz = request.headers.get("authorization") ?? "";
  const m = /^Bearer\s+(.+)$/i.exec(authz);
  if (!isMetricsAdmin(m ? m[1]!.trim() : null, env.METRICS_ADMIN_TOKEN)) return problem("unauthorized", 401);
  const capRaw = url.searchParams.get("quotaCap");
  const capN = capRaw === null ? NaN : Number.parseInt(capRaw, 10);
  const quotaCap = Number.isFinite(capN) && capN > 0 ? capN : undefined;
  const report = await computeAnalyticsReport(fromD1(env.DB), { now: Date.now(), quotaCap });
  return json(report);
}

// --- PATCH /account (Settings preferences) -----------------------------------
// Mutate the signed-in account's preferences: explanation_language (an explanation-language-set member),
// learning_language (canonical BCP-47, or null to clear), reminder_enabled, reminder_time ("HH:MM").
// Only the fields present in the body are changed; the response echoes the updated account. Each user
// only ever mutates THEIR own account (resolveUserId from the bearer session). Body validation is the
// pure `parseAccountPatch` (accounts.ts) — unit-tested there.

async function handlePatchAccount(request: Request, env: Env): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401);
  const parsed = parseAccountPatch(await readJson<unknown>(request));
  if (!parsed.ok) return problem("bad_request", 400, parsed.detail);

  const sql = fromD1(env.DB);
  if (Object.keys(parsed.patch).length > 0) await updateAccountPrefs(sql, userId, parsed.patch);
  const account = await getAccount(sql, userId);
  if (!account) return problem("unauthorized", 401);
  return json({ user: accountView(userId, account, Date.now()) });
}

// --- DELETE /account (account deletion, T8) ----------------------------------
// Mark the account for hard deletion (starts the retention window) and revoke the presenting
// session. The account is immediately inert for ALL sessions (resolveSession requires
// `deleted_at IS NULL`); its data — words → contexts (ciphertext) → reservations → fsrs — is purged
// after DELETE_RETENTION_MS by the scheduled sweep (the ON DELETE CASCADE chain). Re-signing in
// within the window CANCELS the deletion (getOrCreateAccount clears deleted_at). markAccountDeleted
// is idempotent; a repeat call with the now-inert token resolves to 401, which the client treats
// the same as "deleted". The re-auth confirmation is a CLIENT gate — the bearer session is the auth.

async function handleDeleteAccount(request: Request, env: Env): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401);
  const sql = fromD1(env.DB);
  const now = Date.now();
  // T7: stop orphaned charges BEFORE the account goes inert. Cancel any chargeable Stripe subs (we hold
  // the secret key); Apple subs can only be canceled by the user in App Store settings, so we flag them
  // and the client surfaces cancel guidance. Best-effort — a cancel failure is logged, never blocks the
  // delete (the reconciliation cron + provider dashboards backstop). NOTE: cancellation is immediate, so
  // re-signing in within the retention window restores the account DATA but not a canceled subscription.
  const subs = await cancelSubscriptionsForAccount(sql, { stripe: stripeClientFromEnv(env) }, userId);
  if (subs.stripeCancelFailures > 0) {
    console.error("account_delete_stripe_cancel_failed", { count: subs.stripeCancelFailures });
  }
  await markAccountDeleted(sql, userId, now);
  // Sign the caller out (deleting = "log me out now"). Best-effort revoke of the presented token;
  // a fresh sign-in mints a new session and cancels the pending deletion.
  const authz = request.headers.get("authorization");
  if (authz && /^Bearer\s+/i.test(authz)) {
    const token = authz.replace(/^Bearer\s+/i, "").trim();
    if (token) await revokeSession(sql, token, now);
  }
  return json({
    status: "deletion_scheduled",
    // The client shows "cancel your App Store subscription in Settings or it will keep charging".
    ...(subs.appleNeedsManualCancel > 0 ? { apple_subscription_cancel_required: true } : {}),
  });
}

// --- /auth/email (M3 email sign-in via OTP code) -----------------------------
// POST /auth/email/start emails a 6-digit code (Resend); POST /auth/email/verify checks it and
// mints the SAME bearer session as Apple/Google. Email sign-in FAILS CLOSED when no mailer is
// configured (503) so codes are never minted-but-undeliverable. The code lifecycle (resend
// throttle, expiry, attempt cap, single-active-code) lives in email-otp.ts.

interface EmailStartBody {
  email?: unknown;
}

async function handleEmailStart(request: Request, env: Env): Promise<Response> {
  const body = await readJson<EmailStartBody>(request);
  if (!body || typeof body.email !== "string") return problem("bad_request", 400, "email is required");
  const email = normalizeEmail(body.email);
  if (!isValidEmail(email)) return problem("bad_request", 400, "a valid email is required");

  // Fail closed when email sign-in isn't configured, rather than minting a code no one receives.
  const mailer = selectMailer(env);
  if (!mailer) return problem("email_unavailable", 503, "email sign-in is not configured");

  const sql = fromD1(env.DB);
  const now = Date.now();

  // Abuse control BEFORE any send: bound code emails per IP + globally per day. The per-email
  // throttle (below) only stops repeats to ONE address; this stops an unauthenticated caller from
  // bombing many addresses / running up Resend cost. cf-connecting-ip is absent in local dev ⇒ only
  // the global cap applies there.
  const limit = await reserveEmailSend(sql, {
    ip: request.headers.get("cf-connecting-ip"),
    dayKey: utcDayKey(now),
    now,
    perIpCap: parseSendCap(env.EMAIL_PER_IP_DAILY_CAP, DEFAULT_EMAIL_PER_IP_DAILY_CAP),
    globalCap: parseSendCap(env.EMAIL_GLOBAL_DAILY_CAP, DEFAULT_EMAIL_GLOBAL_DAILY_CAP),
  });
  if (!limit.ok) return problem("too_many_requests", 429, "too many sign-in emails — try again later");

  const code = generateOtpCode();
  const started = await startEmailCode(sql, { email, code, now });
  if (!started.ok) {
    // A code was issued moments ago — don't email another (anti-bombing). The client should wait.
    return problem("too_many_requests", 429, "a code was just sent — check your email or try again shortly");
  }
  try {
    await mailer.sendLoginCode(email, code);
  } catch (err) {
    // The send failed — clear the pending code so the user can retry immediately (not throttled),
    // and never echo the vendor error (it can contain the address). Log only a non-PII tag.
    await clearEmailCode(sql, email).catch(() => {});
    console.error("email_send_failed", { name: (err as Error)?.name });
    return problem("email_send_failed", 502, "could not send the sign-in email — please try again");
  }
  return json({ status: "sent" });
}

interface EmailVerifyBody {
  email?: unknown;
  code?: unknown;
  timezone?: unknown;
  learning_language?: unknown;
}

async function handleEmailVerify(request: Request, env: Env): Promise<Response> {
  const body = await readJson<EmailVerifyBody>(request);
  if (!body || typeof body.email !== "string" || typeof body.code !== "string") {
    return problem("bad_request", 400, "email and code are required");
  }
  const email = normalizeEmail(body.email);
  const code = body.code.trim();
  if (!isValidEmail(email) || !/^\d{6}$/.test(code)) {
    return problem("bad_request", 400, "a valid email and 6-digit code are required");
  }

  const sql = fromD1(env.DB);
  const now = Date.now();
  const result = await verifyEmailCode(sql, { email, code, now });
  if (!result.ok) {
    // "expired" / "too_many_attempts" tell the client to request a fresh code; "mismatch" / "no_code"
    // fold into one generic answer so the endpoint isn't an oracle for which addresses have a code.
    if (result.reason === "expired") return problem("code_expired", 401, "that code expired — request a new one");
    if (result.reason === "too_many_attempts") {
      return problem("too_many_attempts", 429, "too many tries — request a new code");
    }
    return problem("auth_failed", 401, "invalid or expired code");
  }

  // Verified ⇒ the same account + session path as the OIDC providers. First-create only: the
  // client's IANA tz + an optional default learning language (an existing account keeps its stored
  // values). The account subject IS the normalized email (the dedup key under provider "email").
  const timezone =
    typeof body.timezone === "string" && isValidIanaTimeZone(body.timezone) ? body.timezone : "UTC";
  const learningLanguage =
    typeof body.learning_language === "string" ? canonicalizeBcp47(body.learning_language) : null;

  const userId = await getOrCreateAccount(
    sql,
    { provider: "email", subject: email, timezone, learningLanguage, email },
    now,
    uuid,
  );
  const session = await issueSession(sql, userId, now, parseSessionTtlMs(env.SESSION_TTL_MS));
  const account = await getAccount(sql, userId);
  if (!account) return problem("internal_error", 500); // just upserted — unreachable in practice
  return json({ token: session.token, expires_at: session.expiresAt, user: accountView(userId, account, now) });
}

// --- /words ------------------------------------------------------------------

interface CreateWordBody {
  surface_unit?: unknown;
  target_language?: unknown;
}

async function handleCreateWord(request: Request, env: Env): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401, "sign-in required to save words");
  const body = await readJson<CreateWordBody>(request);
  if (!body || typeof body.surface_unit !== "string" || typeof body.target_language !== "string") {
    return problem("bad_request", 400, "surface_unit and target_language are required strings");
  }

  const sql = fromD1(env.DB);
  const freeWordCap = freeWordCapFromEnv(env);
  const out = await saveWord(sql, {
    userId,
    surfaceUnit: body.surface_unit,
    targetLanguage: body.target_language,
    freeWordCap,
    now: Date.now(),
    newId: uuid,
  });
  if (out.status === "invalid_target_language") return problem("invalid_target_language", 422);
  if (out.status === "empty_unit") return problem("empty_unit", 422, "unit is empty after normalization");
  if (out.status === "unit_too_large") {
    return problem("unit_too_large", 422, "save a word or a short phrase, not a sentence (use the context layer for sentences)");
  }
  if (out.status === "cap_reached") {
    // Free saved-word cap hit on a net-new save (not Pro). 402 Payment Required — the request is well-
    // formed, it needs an upgrade. The client renders the milestone prompt and keeps the word as a
    // blocked-by-cap local capture (C3); `cap` is the exact ceiling for the copy. Existing words stay.
    return json(
      { error: "cap_reached", cap: freeWordCap, detail: "free saved-word limit reached — Pro lifts the ceiling" },
      402,
    );
  }
  return json({ status: out.status, word: out.word }, out.status === "created" ? 201 : 200);
}

async function handleListWords(request: Request, env: Env): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401);
  const words = await listWords(fromD1(env.DB), userId);
  return json({ words });
}

async function handleDeleteWord(request: Request, env: Env, url: URL): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401);
  const id = url.pathname.split("/")[2]!;
  const deleted = await softDeleteWord(fromD1(env.DB), userId, id, Date.now());
  return deleted ? json({ status: "deleted", id }) : problem("not_found", 404);
}

async function handleRestoreWord(request: Request, env: Env, url: URL): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401);
  const id = url.pathname.split("/")[2]!; // /words/:id/restore
  const restored = await restoreWord(fromD1(env.DB), userId, id, Date.now());
  // 404 when there's no tombstoned unit by that id for this user (already active, or never existed).
  return restored ? json({ status: "restored", id }) : problem("not_found", 404);
}

// --- /explain (free word layer) ----------------------------------------------

async function handleExplain(request: Request, env: Env, url: URL): Promise<Response> {
  const unit = url.searchParams.get("unit");
  const target = url.searchParams.get("target");
  if (!unit || !target) return problem("bad_request", 400, "unit and target are required");
  const explanationLanguage = url.searchParams.get("explanation_lang") ?? "en";
  const wordId = url.searchParams.get("word_id");

  const userId = await resolveUserId(request, env);
  const account: ExplainRequest["account"] = userId ? "user" : "anon";
  const config = costConfigFromEnv(env);
  const now = Date.now();
  const sql = fromD1(env.DB);

  const head = explainKey({ surfaceUnit: unit, targetLanguage: target, explanationLanguage });

  // Bind word_id to the unit being explained. A stale/buggy client could pass a
  // different owned word's id and corrupt its cache-key pointer/state (Codex P2 /
  // Claude 7.1), so only stamp the row if its server-stored unit + canonical target
  // actually match this request.
  const canonicalTarget = canonicalizeBcp47(target);
  const wordRow = userId && wordId ? await getWordById(sql, userId, wordId) : null;
  const reqNormalized = head.status === "ok" ? head.normalized : canonicalTarget ? dedupKey(unit) : "";
  const wordMatchesRequest =
    wordRow !== null &&
    canonicalTarget !== null &&
    wordRow.target_language === canonicalTarget &&
    wordRow.normalized_unit === reqNormalized;

  const updateState = async (result: ExplainResult): Promise<void> => {
    if (!userId || !wordId || !wordMatchesRequest) return;
    if (result.status === "generated" || result.status === "hit") {
      await markExplanationReady(sql, userId, wordId, result.key, now);
    } else if (result.status === "failed") {
      await markExplanationState(sql, userId, wordId, "failed", now);
    } else if (result.status === "language_unsupported" || result.status === "not_a_word") {
      // A saved unit the free layer will never explain — an unsupported target, or degenerate junk
      // that slipped through the (intentionally non-junk-gating) save path. Record a TERMINAL state so
      // the Word Book stops showing "pending"; there is no separate "not a word" state at MVP.
      await markExplanationState(sql, userId, wordId, "language_unsupported", now);
    }
  };
  if (head.status === "language_unsupported") {
    await updateState({ status: "language_unsupported" });
    return json({ status: "language_unsupported" });
  }
  if (head.status === "unit_too_large") {
    // Reject before any cache key / DO hop / spend (§13): a sentence isn't a free
    // word-layer unit. Server-authoritative — never trust the client's selection size.
    return problem("unit_too_large", 422, "explain a word or a short phrase, not a sentence (use the context layer for sentences)");
  }
  if (head.status === "not_a_word") {
    // Degenerate non-vocabulary (pure punctuation/number/URL): reject before any cache key / DO hop /
    // spend (RFC §B). Authoritative twin of the client junk gate. 422 like an over-bound unit, but a
    // DISTINCT code so metrics can tell "sentence" from "junk". Stamp a terminal state on the word if
    // one was bound (a junk unit that slipped through save).
    await updateState({ status: "not_a_word" });
    return problem("not_a_word", 422, "that doesn't look like a word — nothing to explain");
  }

  // Fast path: serve a CDN/R2 cache HIT at the edge without a DO hop.
  const cache = fromR2(env.EXPLANATION_CACHE);
  const hit = await cache.get(head.key);
  if (hit) {
    await updateState({ status: "hit", key: head.key, explanation: hit });
    return json({ status: "hit", explanation: hit });
  }

  const anonOpen = account === "anon" && config.anonDailyGenerationUnits > 0;
  if (account === "anon" && !anonOpen) {
    // HIT-only: anonymous cache miss never generates (budget-DoS guard, US-3.1).
    return json({ status: "anon_miss", detail: "sign in to generate this explanation" }, 200);
  }

  // Cross-request single-flight: route the miss to the DO keyed by the cache key, so
  // concurrent misses for the same word collapse to ONE generation (ENG-6).
  const explainReq: ExplainRequest = {
    surfaceUnit: unit,
    targetLanguage: target,
    explanationLanguage,
    account,
    budgetDayKey: utcDayKey(now),
    globalCap: config.globalDailyBudgetUnits,
    anonDayKey: anonOpen ? `anon:${utcDayKey(now)}` : undefined,
    anonCap: config.anonDailyGenerationUnits,
    cost: 1,
  };
  const doStub = env.SINGLE_FLIGHT.get(env.SINGLE_FLIGHT.idFromName(head.key));
  const res = await doStub.fetch("https://single-flight.internal/", {
    method: "POST",
    body: JSON.stringify(explainReq),
  });
  const result = (await res.json()) as ExplainResult;
  await updateState(result);

  if (result.status === "generated" || result.status === "hit") {
    return json({ status: result.status, explanation: result.explanation });
  }
  if (result.status === "budget_exhausted") return problem("budget_exhausted", 503, "daily capacity reached");
  if (result.status === "failed") return problem("generation_failed", 502, result.reason);
  if (result.status === "not_a_word") {
    // The model declined a word-shaped non-word. Same 422 + code as the pre-generation junk gate, so the
    // client handles "not a word" uniformly however it was caught. updateState above already stamped the
    // bound word terminal.
    return problem("not_a_word", 422, "that doesn't look like a word — nothing to explain");
  }
  return json(result);
}

// --- /contexts + /explain/context (private context layer, T8) ----------------
// Context text + private glosses are encrypted at rest; the KEK is a Worker Secret.
// No context plaintext ever appears in URLs, logs, traces, or CDN keys (ENG-10).

// Provider precedence mirrors the word layer: dev mock (deterministic, for tests/local) → real Gemini
// (GEMINI_API_KEY) → fail-closed. The context call sends the user's sentence off-box, so the Gemini path
// is the zero-retention vendor requirement (T8); with no key it stays Unconfigured (throws → no spend).
const contextProvider = (env: Env) =>
  env.DEV_USE_MOCK_PROVIDER === "true"
    ? new MockContextProvider()
    : env.GEMINI_API_KEY
      ? makeGeminiContextProvider(env.GEMINI_API_KEY, env.GEMINI_CONTEXT_MODEL)
      : new UnconfiguredContextProvider();

interface CreateContextBody {
  word_id?: unknown;
  context_text?: unknown;
  context_language?: unknown;
  span_start?: unknown;
  span_end?: unknown;
  /** E2: a context-preview handle to ADOPT the already-metered gloss onto this new context (no
   *  recharge). Ignored if absent / stale / for a different sentence. */
  preview_handle?: unknown;
}

async function handleCreateContext(request: Request, env: Env): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401, "sign-in required");
  const crypto = await envelopeCryptoFromEnv(env);
  if (!crypto) return problem("encryption_unavailable", 503, "context encryption not configured");
  const body = await readJson<CreateContextBody>(request);
  if (!body || typeof body.word_id !== "string" || typeof body.context_text !== "string") {
    return problem("bad_request", 400, "word_id and context_text are required strings");
  }
  const { start, end } = spanPair(body.span_start, body.span_end);
  const out = await createContext(fromD1(env.DB), crypto, {
    userId,
    wordId: body.word_id,
    contextText: body.context_text,
    contextLanguage: typeof body.context_language === "string" ? body.context_language : null,
    spanStart: start,
    spanEnd: end,
    now: Date.now(),
    newId: uuid,
  });
  if (out.status === "word_not_found") return problem("not_found", 404, "no such unit for this account");
  if (out.status === "empty_context") return problem("empty_context", 422, "context text is empty");
  if (out.status === "context_too_large") return problem("context_too_large", 422, "context text exceeds the limit");

  // E2: if Save carries a preview handle, adopt the already-metered gloss onto the new context (no
  // recharge). Best-effort — a stale / foreign / different-sentence handle simply doesn't adopt, and
  // the user can re-explain from the Word Book. Adoption is reported so the client can skip re-meter.
  let glossAdopted = false;
  if (typeof body.preview_handle === "string" && body.preview_handle.length > 0) {
    glossAdopted = await adoptPreview(fromD1(env.DB), crypto, {
      userId,
      previewHandle: body.preview_handle,
      contextId: out.id,
      now: Date.now(),
    });
  }
  return json({ status: "created", context: { id: out.id }, glossAdopted }, 201);
}

async function handleListContexts(request: Request, env: Env, url: URL): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401);
  const crypto = await envelopeCryptoFromEnv(env);
  if (!crypto) return problem("encryption_unavailable", 503, "context encryption not configured");
  const wordId = url.searchParams.get("word_id");
  if (!wordId) return problem("bad_request", 400, "word_id is required");
  const contexts = await listContextsForWord(fromD1(env.DB), crypto, userId, wordId);
  return json({ contexts });
}

async function handleEditContext(request: Request, env: Env, url: URL): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401);
  const crypto = await envelopeCryptoFromEnv(env);
  if (!crypto) return problem("encryption_unavailable", 503, "context encryption not configured");
  const id = url.pathname.split("/")[2]!;
  const body = await readJson<{ context_text?: unknown }>(request);
  if (!body || typeof body.context_text !== "string") return problem("bad_request", 400, "context_text is required");
  const out = await editContextText(fromD1(env.DB), crypto, userId, id, body.context_text);
  if (out.status === "not_found") return problem("not_found", 404);
  if (out.status === "empty_context") return problem("empty_context", 422, "context text is empty");
  if (out.status === "context_too_large") return problem("context_too_large", 422, "context text exceeds the limit");
  return json({ status: "updated", id });
}

async function handleDeleteContext(request: Request, env: Env, url: URL): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401);
  const id = url.pathname.split("/")[2]!;
  const deleted = await deleteContext(fromD1(env.DB), userId, id);
  return deleted ? json({ status: "deleted", id }) : problem("not_found", 404);
}

interface ExplainContextBody {
  word_context_id?: unknown;
  idempotency_key?: unknown;
  explanation_lang?: unknown;
}

async function handleExplainContext(request: Request, env: Env): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401, "sign-in required");
  const crypto = await envelopeCryptoFromEnv(env);
  if (!crypto) return problem("encryption_unavailable", 503, "context encryption not configured");
  const body = await readJson<ExplainContextBody>(request);
  if (!body || typeof body.word_context_id !== "string") {
    return problem("bad_request", 400, "word_context_id is required");
  }

  const sql = fromD1(env.DB);
  const account = await getAccount(sql, userId);
  if (!account) return problem("unauthorized", 401);
  const now = Date.now();
  // Resolve the requested gloss language to the canonical explanation-language set —
  // server-authoritative, same as the word layer — so re-view's language match is
  // exact and the stored gloss is keyed to a canonical language.
  const requested =
    typeof body.explanation_lang === "string"
      ? body.explanation_lang
      : effectiveExplanationLanguage(
          account.explanation_follows_learning === 1,
          account.explanation_language,
          account.learning_language,
        );
  const explanationLanguage = resolveExplanationLanguage(requested) ?? "en";

  const result = await explainContext(
    {
      sql,
      crypto,
      provider: contextProvider(env),
      budget: budgetClient(env.GLOBAL_BUDGET),
      config: costConfigFromEnv(env),
      now: () => Date.now(),
      newId: uuid,
    },
    {
      userId,
      wordContextId: body.word_context_id,
      explanationLanguage,
      idempotencyKey: typeof body.idempotency_key === "string" ? body.idempotency_key : undefined,
      quotaDay: accountDayKey(now, account.iana_timezone),
      budgetDayKey: utcDayKey(now),
      cost: 1,
      isPro: isPro(account, now),
    },
  );

  switch (result.status) {
    case "ready":
      return json({
        status: "ready",
        meaning: result.meaning,
        charged: result.charged,
      });
    case "not_found":
      return problem("not_found", 404);
    case "quota_exhausted":
      return problem("quota_exhausted", 429, "daily context-explanation limit reached");
    case "budget_exhausted":
      return problem("budget_exhausted", 503, "temporarily unavailable — try later");
    case "conflict":
      return problem(result.reason, 409);
    case "failed":
      return problem("generation_failed", 502, result.reason);
  }
}

interface ExplainContextPreviewBody {
  surface_unit?: unknown;
  target_language?: unknown;
  context_text?: unknown;
  context_language?: unknown;
  span_start?: unknown;
  span_end?: unknown;
  idempotency_key?: unknown;
  explanation_lang?: unknown;
}

// POST /explain/context/preview — E2: explain a word IN its captured sentence BEFORE it is saved (no
// word_context id), on the RAW (word, sentence). Metered from the SAME daily context pool; the result
// is stored transiently and returned with a `previewHandle` that Save adopts (no recharge).
async function handleExplainContextPreview(request: Request, env: Env): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401, "sign-in required");
  const crypto = await envelopeCryptoFromEnv(env);
  if (!crypto) return problem("encryption_unavailable", 503, "context encryption not configured");
  const body = await readJson<ExplainContextPreviewBody>(request);
  if (!body || typeof body.surface_unit !== "string" || typeof body.context_text !== "string") {
    return problem("bad_request", 400, "surface_unit and context_text are required");
  }

  const sql = fromD1(env.DB);
  const account = await getAccount(sql, userId);
  if (!account) return problem("unauthorized", 401);
  const now = Date.now();

  // Canonicalize the target (the context layer isn't generation-allowlisted; it serves any target).
  // Fall back to the account's learning language, then English.
  const rawTarget = typeof body.target_language === "string" ? body.target_language : account.learning_language ?? "en";
  const target = canonicalizeBcp47(rawTarget) ?? "en";
  const requested =
    typeof body.explanation_lang === "string"
      ? body.explanation_lang
      : effectiveExplanationLanguage(
          account.explanation_follows_learning === 1,
          account.explanation_language,
          account.learning_language,
        );
  const explanationLanguage = resolveExplanationLanguage(requested) ?? "en";
  const { start, end } = spanPair(body.span_start, body.span_end);

  const result = await explainContextPreview(
    {
      sql,
      crypto,
      provider: contextProvider(env),
      budget: budgetClient(env.GLOBAL_BUDGET),
      config: costConfigFromEnv(env),
      now: () => Date.now(),
      newId: uuid,
      // E8 parity with /explain: a PII-free preview generation signal (outcome + public axes only).
      observe: (o) => console.log("context_preview_generation", o),
    },
    {
      userId,
      surfaceUnit: body.surface_unit,
      targetLanguage: target,
      contextText: body.context_text,
      contextLanguage: typeof body.context_language === "string" ? body.context_language : null,
      spanStart: start,
      spanEnd: end,
      explanationLanguage,
      idempotencyKey: typeof body.idempotency_key === "string" ? body.idempotency_key : undefined,
      quotaDay: accountDayKey(now, account.iana_timezone),
      budgetDayKey: utcDayKey(now),
      cost: 1,
      isPro: isPro(account, now),
    },
  );

  switch (result.status) {
    case "ready":
      return json({
        status: "ready",
        meaning: result.meaning,
        previewHandle: result.previewHandle,
        charged: result.charged,
      });
    case "invalid_unit":
      return problem("invalid_unit", 422, "that doesn't look like a word to explain in context");
    case "empty_context":
      return problem("empty_context", 422, "context text is empty");
    case "context_too_large":
      return problem("context_too_large", 422, "context text exceeds the limit");
    case "quota_exhausted":
      return problem("quota_exhausted", 429, "daily context-explanation limit reached");
    case "budget_exhausted":
      return problem("budget_exhausted", 503, "temporarily unavailable — try later");
    case "conflict":
      return problem(result.reason, 409);
    case "failed":
      return problem("generation_failed", 502, result.reason);
  }
}

// --- /review (server-authoritative FSRS, M3a) --------------------------------

interface ReviewBody {
  word_id?: unknown;
  event_id?: unknown;
  rating?: unknown;
  client_review_ts?: unknown;
  source?: unknown;
}

async function handleReview(request: Request, env: Env): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401, "sign-in required to review");
  const body = await readJson<ReviewBody>(request);
  if (
    !body ||
    typeof body.word_id !== "string" ||
    typeof body.event_id !== "string" ||
    typeof body.rating !== "number" ||
    !Number.isInteger(body.rating) ||
    body.rating < 1 ||
    body.rating > 4 ||
    typeof body.client_review_ts !== "number" ||
    !Number.isFinite(body.client_review_ts)
  ) {
    return problem("bad_request", 400, "word_id, event_id, rating (1-4), and client_review_ts are required");
  }

  const out = await ingestReview(fromD1(env.DB), {
    userId,
    wordId: body.word_id,
    eventId: body.event_id,
    rating: body.rating as RatingValue,
    clientReviewTs: body.client_review_ts,
    now: Date.now(),
    source: normalizeSource(body.source),
  });
  switch (out.status) {
    case "applied":
      return json({ status: "applied", replay: out.replay, card: out.card });
    case "not_found":
      return problem("not_found", 404);
    case "unit_deleted":
      return problem("unit_deleted", 409, "this unit was deleted — its reviews are closed");
    case "id_conflict":
      return problem("event_id_conflict", 409, "event_id already used for a different unit");
  }
}

async function handleReviewDue(request: Request, env: Env, url: URL): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401);
  const rawLimit = url.searchParams.get("new_limit");
  const parsed = rawLimit === null ? DEFAULT_NEW_CARD_CAP : Number.parseInt(rawLimit, 10);
  const newCardCap = Number.isInteger(parsed) && parsed >= 0 ? parsed : DEFAULT_NEW_CARD_CAP;
  const sql = fromD1(env.DB);
  const account = await getAccount(sql, userId);
  if (!account) return problem("unauthorized", 401);
  // The new-card soft cap is per account-tz DAY (US-1.2), so the daily-introduction
  // accounting needs the account's IANA timezone to find today's local-midnight window.
  const { due, newCards } = await listDueReviews(sql, userId, Date.now(), account.iana_timezone, newCardCap);
  return json({ due, new: newCards, counts: { due: due.length, new: newCards.length } });
}

// --- /words/claim + /sync (cross-device, M3b) --------------------------------

const MAX_CLAIM_ROWS = 500; // bound a single batch flush (untrusted client input)
const MAX_SYNC_EVENTS = 500;

/** Normalize a captured span to a valid pair or null-both. A one-sided or inverted span
 *  is meaningless rendering metadata (and violates the schema CHECK), so drop it rather
 *  than 500 — the context text is preserved, just without a highlight. */
function spanPair(rawStart: unknown, rawEnd: unknown): { start: number | null; end: number | null } {
  if (
    Number.isInteger(rawStart) &&
    Number.isInteger(rawEnd) &&
    (rawStart as number) >= 0 &&
    (rawEnd as number) >= (rawStart as number)
  ) {
    return { start: rawStart as number, end: rawEnd as number };
  }
  return { start: null, end: null };
}

interface ClaimBody {
  install_id?: unknown;
  rows?: unknown;
}

async function handleClaim(request: Request, env: Env): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401, "sign-in required to claim");
  const body = await readJson<ClaimBody>(request);
  if (!body || typeof body.install_id !== "string" || !Array.isArray(body.rows)) {
    return problem("bad_request", 400, "install_id and rows[] are required");
  }
  if (body.rows.length > MAX_CLAIM_ROWS) return problem("payload_too_large", 413, "too many rows in one claim");

  const rows: ClaimRowInput[] = [];
  for (const r of body.rows) {
    if (!r || typeof r !== "object") return problem("bad_request", 400, "each row must be an object");
    const o = r as Record<string, unknown>;
    if (typeof o.client_row_id !== "string" || typeof o.surface_unit !== "string" || typeof o.target_language !== "string") {
      return problem("bad_request", 400, "each row needs client_row_id, surface_unit, target_language");
    }
    let context: ClaimRowInput["context"];
    if (o.context !== undefined && o.context !== null) {
      const c = o.context as Record<string, unknown>;
      if (typeof c.text !== "string") return problem("bad_request", 400, "context.text must be a string");
      const { start, end } = spanPair(c.span_start, c.span_end);
      context = {
        text: c.text,
        contextLanguage: typeof c.context_language === "string" ? c.context_language : null,
        spanStart: start,
        spanEnd: end,
        // Capture-source provenance synced with the context (createContext canonicalizes/bounds/encrypts).
        sourceApp: typeof c.source_app === "string" ? c.source_app : null,
        sourceTitle: typeof c.source_title === "string" ? c.source_title : null,
        detectedLanguage: typeof c.detected_language === "string" ? c.detected_language : null,
        detectedLanguageConfidence:
          typeof c.detected_language_confidence === "number" ? c.detected_language_confidence : null,
        // E2 adopt-on-save: a capture-time preview handle the client carries so the already-metered
        // gloss is attached to this context without recharge (best-effort — see claim.ts).
        previewHandle: typeof c.preview_handle === "string" ? c.preview_handle : null,
      };
    }
    rows.push({ clientRowId: o.client_row_id, surfaceUnit: o.surface_unit, targetLanguage: o.target_language, ...(context ? { context } : {}) });
  }

  const sql = fromD1(env.DB);
  const needsCrypto = rows.some((r) => r.context);
  const crypto = needsCrypto ? await envelopeCryptoFromEnv(env) : null;
  if (needsCrypto && !crypto) return problem("encryption_unavailable", 503, "context encryption not configured");

  const results = await claimRows(sql, crypto, {
    userId,
    installId: body.install_id,
    rows,
    freeWordCap: freeWordCapFromEnv(env),
    now: Date.now(),
    newId: uuid,
  });
  return json({ results });
}

interface SyncBody {
  events?: unknown;
}

async function handleSync(request: Request, env: Env): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401, "sign-in required to sync");
  const body = await readJson<SyncBody>(request);
  if (!body || !Array.isArray(body.events)) return problem("bad_request", 400, "events[] is required");
  if (body.events.length > MAX_SYNC_EVENTS) return problem("payload_too_large", 413, "too many events in one flush");

  // Only ENVELOPE errors (non-JSON body, missing events[], oversized batch) reject the whole
  // request. A single structurally-malformed event is parsed to an `invalid` per-event result
  // so the rest of the offline queue still flushes — NOT a batch-wide 400 that would wedge the
  // client's queue (and its FSRS progress) behind one poison-pill event (review-fix: Codex P2).
  const events = body.events.map(parseSyncEvent);
  const results = await replayReviews(fromD1(env.DB), { userId, events, now: Date.now() });
  return json({ results });
}

// --- /export (Anki/CSV, M5) ---------------------------------------------------

async function handleExport(request: Request, env: Env, url: URL): Promise<Response> {
  const userId = await resolveUserId(request, env);
  if (!userId) return problem("unauthorized", 401, "sign-in required to export");

  // format=anki|csv (build-plan §5.2; csv is the default). Reject an unknown value rather than
  // silently handing back the wrong file (a typo'd/old client shouldn't get a surprise format).
  const formatParam = url.searchParams.get("format");
  let format: ExportFormat;
  if (formatParam === null || formatParam === "csv") format = "csv";
  else if (formatParam === "anki") format = "anki";
  else if (formatParam === "json") format = "json"; // structured rows for the client-built .apkg deck
  else return problem("bad_request", 400, "format must be 'anki', 'csv', or 'json'");
  // Opt-in attribution (off by default) — the r/Anki community punishes spammy exports (§8).
  const attribution = url.searchParams.get("attribution") === "true";

  const sql = fromD1(env.DB);
  // Export DECRYPTS the user's own context text, so it needs the envelope key. Fail closed
  // (503) if unconfigured, same as the other T8 context paths — never silently drop contexts.
  const crypto = await envelopeCryptoFromEnv(env);
  if (!crypto) return problem("encryption_unavailable", 503, "context encryption not configured");

  const rows = await collectExportRows(sql, crypto, fromR2(env.EXPLANATION_CACHE), userId);
  const { body, contentType, ext } = renderExport(rows, format, { attribution });
  return attachment(body, contentType, `capecho-export-${utcDayKey(Date.now())}.${ext}`);
}

// --- Durable Objects ---------------------------------------------------------
// Per ENG-2 these handle only true cross-request serialization: the global daily
// AI-spend cap (atomic, fail-closed) and single-flight generation coalescing. The
// per-user context quota is the D1 context_quota_reservations table, NOT a DO.

export class GlobalBudget {
  private readonly ledger: BudgetLedger;
  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env,
  ) {
    const store: BudgetStore = {
      get: (k) => this.state.storage.get<number>(k),
      put: async (k, v) => {
        await this.state.storage.put(k, v);
      },
    };
    this.ledger = new BudgetLedger(store);
  }

  async fetch(request: Request): Promise<Response> {
    const body = await readJson<BudgetWire>(request);
    if (!body || typeof body.key !== "string") return problem("bad_request", 400);
    if (body.action === "reserve") {
      const cost = body.cost ?? 1;
      const decision = await this.ledger.reserve(body.key, cost, body.cap ?? 0);
      if (decision.ok) {
        try {
          await this.mirror(body.key, decision.spent);
        } catch {
          // The D1 mirror is the durable record. If it fails we must NOT keep the
          // reserved unit in the DO ledger: that ratchets the cap down with ZERO
          // generation — the exact "spend leak" class this PR's budget-client fix
          // closed, here at the DO boundary. Roll the ledger back and report
          // unavailable so the caller fails closed without consuming budget.
          await this.ledger.refund(body.key, cost);
          return problem("budget_mirror_unavailable", 503);
        }
      }
      return json(decision);
    }
    if (body.action === "refund") {
      const cost = body.cost ?? 1;
      await this.ledger.refund(body.key, cost);
      // Best-effort mirror: the refund is already applied to the authoritative DO
      // ledger; a failed D1 sync only leaves D1 transiently over-counting spend
      // (conservative — never under-counts), reconciled on the next successful write.
      try {
        await this.mirror(body.key, await this.ledger.spent(body.key));
      } catch {
        /* best-effort */
      }
      return json({ ok: true });
    }
    if (body.action === "spent") return json({ spent: await this.ledger.spent(body.key) });
    return problem("bad_action", 400);
  }

  // Mirror the UTC-day counter to D1 (fail-closed, queryable). Sub-cap keys are skipped.
  private async mirror(key: string, spent: number): Promise<void> {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(key)) return;
    await this.env.DB.prepare(
      `INSERT INTO global_budget (spend_day, spent_units, updated_at) VALUES (?, ?, ?)
       ON CONFLICT (spend_day) DO UPDATE SET spent_units = excluded.spent_units, updated_at = excluded.updated_at`,
    )
      .bind(key, spent, Date.now())
      .run();
  }
}

export class SingleFlight {
  private readonly deps: ExplainDeps;
  constructor(state: DurableObjectState, env: Env) {
    void state; // routing is by id (the cache key); no per-id storage needed
    // Provider precedence: dev mock (deterministic, for tests/local) → real Gemini (GEMINI_API_KEY)
    // → fail-closed Unconfigured. Failing closed (rather than defaulting to a mock) keeps fake
    // definitions out of the shared public cache if generation is reached before a key is set.
    const provider =
      env.DEV_USE_MOCK_PROVIDER === "true"
        ? new MockExplanationProvider()
        : env.GEMINI_API_KEY
          ? makeGeminiProvider(env.GEMINI_API_KEY, env.GEMINI_MODEL)
          : new UnconfiguredProvider();
    this.deps = {
      cache: fromR2(env.EXPLANATION_CACHE),
      budget: budgetClient(env.GLOBAL_BUDGET),
      singleFlight: new Coalescer(), // coalesces concurrent in-isolate misses for this key
      provider,
      // E8: a structured record per generation outcome (never on a cache hit). Workers Observability
      // indexes the JSON fields, so the omit-on-fail rate (pronunciationState) + failure reasons are
      // queryable and the bar stays calibratable. Carries no unit/context text (T8).
      observe: (o) => console.log("explain_generation", o),
    };
  }

  async fetch(request: Request): Promise<Response> {
    const req = await readJson<ExplainRequest>(request);
    if (!req) return problem("bad_request", 400);
    return json(await getWordExplanation(this.deps, req));
  }
}
