import type { Sql } from "../sql.ts";
import { applySubscriptionUpdate, type SubscriptionProvider } from "../entitlement.ts";
import { mapStripeSubscriptionObject, fetchStripeSubscription, cancelStripeSubscription } from "./stripe.ts";
import {
  reconcileAppleSubscription,
  makeAppleApiClient,
  appleConfigFromEnv,
  appleExpectedEnvironment,
  type AppleApiClient,
  type AppleEnvironment,
  type AppleEnvConfig,
} from "./apple.ts";
import { utcDayKey } from "../time.ts";

// Billing reconciliation (T6) + account-deletion subscription handling (T7). Both walk the
// `subscriptions` table and act per provider; the network calls are behind the same injectable seams
// the rails use (so the orchestration is fully unit-testable with mock clients/keys).

// --- injectable provider seams (so the orchestration is testable without network) ------------------

export interface StripeClient {
  fetchSubscription: (id: string) => Promise<unknown | null>;
  cancelSubscription: (id: string) => Promise<boolean>;
}

/** Bind a StripeClient to a secret key (the real network impl). */
export function makeStripeClient(secretKey: string): StripeClient {
  return {
    fetchSubscription: (id) => fetchStripeSubscription(secretKey, id),
    cancelSubscription: (id) => cancelStripeSubscription(secretKey, id),
  };
}

/** The Stripe client for this deployment, or null when the secret key isn't set. */
export function stripeClientFromEnv(env: { STRIPE_SECRET_KEY?: string }): StripeClient | null {
  return env.STRIPE_SECRET_KEY ? makeStripeClient(env.STRIPE_SECRET_KEY) : null;
}

// --- T6: reconciliation cron -----------------------------------------------------------------------

export interface ReconcileDeps {
  /** Stripe client for live subscription reads, or null if Stripe isn't configured (skip its subs). */
  stripe: StripeClient | null;
  /** Apple App Store Server API client, or null if Apple isn't configured (skip its subs). */
  appleClient: AppleApiClient | null;
  appleExpectedEnvironment: AppleEnvironment;
  newId: () => string;
}

export interface ReconcileResult {
  checked: number;
  applied: number; // authoritative state differed (or first-seen) → entitlement advanced
  skipped: number; // provider unconfigured / object not actionable
  errors: number; // couldn't fetch authoritative state (transient — next run retries)
}

export interface BillingEnv extends AppleEnvConfig {
  STRIPE_SECRET_KEY?: string;
}

/** Build the reconcile deps from env — skips a provider whose credentials aren't set (no network). */
export function reconcileDepsFromEnv(env: BillingEnv, newId: () => string): ReconcileDeps {
  const appleCfg = appleConfigFromEnv(env);
  return {
    stripe: stripeClientFromEnv(env),
    appleClient: appleCfg ? makeAppleApiClient(appleCfg) : null,
    appleExpectedEnvironment: appleExpectedEnvironment(env),
    newId,
  };
}

// Reconcile anything not terminally dead. revoked/refunded are terminal (already clawed back); every
// other status can still change (renew / expire / lapse-then-recover), so re-check it against the
// provider. Pre-launch volume is tiny → reconcile the whole set; bound by an updated_at window later.
const RECONCILE_STATUSES = "('active','trialing','grace_period','canceled','expired')";

interface ReconcileSubRow {
  provider: SubscriptionProvider;
  provider_subscription_id: string;
}

/**
 * Re-fetch each live subscription's authoritative state from its provider and apply it — the backstop
 * for missed / out-of-order webhooks (a dropped renewal or a stale `canceled` that the monotonic guard
 * skipped). applySubscriptionUpdate is idempotent + monotonic, so reconciling an unchanged sub is a
 * cheap no-op; a drifted one is corrected. Runs from the daily cron.
 */
export async function reconcileSubscriptions(sql: Sql, deps: ReconcileDeps, now: number): Promise<ReconcileResult> {
  const subs = await sql
    .prepare(`SELECT provider, provider_subscription_id FROM subscriptions WHERE status IN ${RECONCILE_STATUSES}`)
    .all<ReconcileSubRow>();
  const dayKey = utcDayKey(now);
  let applied = 0;
  let skipped = 0;
  let errors = 0;

  for (const sub of subs) {
    try {
      if (sub.provider === "stripe") {
        if (!deps.stripe) {
          skipped++;
          continue;
        }
        const obj = await deps.stripe.fetchSubscription(sub.provider_subscription_id);
        if (!obj) {
          errors++;
          continue;
        }
        // Reconcile asserts "authoritative as of now" → eventTs = now (a fetch is fresher than any past
        // event); a per-day providerEventId keeps the audit log to one reconcile event per sub per day.
        const mapped = mapStripeSubscriptionObject(obj, {
          providerEventId: `reconcile:stripe:${sub.provider_subscription_id}:${dayKey}`,
          eventTs: now,
          eventType: "reconcile",
        });
        if (mapped.kind !== "update") {
          skipped++;
          continue;
        }
        const out = await applySubscriptionUpdate(sql, { ...mapped.update, now, newId: deps.newId });
        if (out.applied) applied++;
      } else if (sub.provider === "apple") {
        if (!deps.appleClient) {
          skipped++;
          continue;
        }
        // All stored Apple subs are in the deployment's honored environment (wrong-env triggers were
        // ignored at ingest), so reconcile at expectedEnvironment.
        const r = await reconcileAppleSubscription(sql, deps.appleClient, {
          originalTransactionId: sub.provider_subscription_id,
          environment: deps.appleExpectedEnvironment,
          expectedEnvironment: deps.appleExpectedEnvironment,
          providerEventId: `reconcile:apple:${sub.provider_subscription_id}:${dayKey}`,
          eventType: "reconcile",
          now,
          newId: deps.newId,
        });
        if (r.status === "applied") applied++;
        else if (r.status === "unavailable") errors++;
      }
    } catch {
      errors++;
    }
  }
  return { checked: subs.length, applied, skipped, errors };
}

// --- T7: cancel subscriptions on account deletion --------------------------------------------------

export interface AccountSubsResult {
  /** Stripe subs canceled server-side (we hold the key → we stop the charges). */
  canceledStripe: number;
  /** Stripe cancels that failed (logged; the cron + Stripe dashboard backstop). */
  stripeCancelFailures: number;
  /** Apple subs that only the USER can cancel (App Store settings) → return cancel guidance. */
  appleNeedsManualCancel: number;
}

// Still-chargeable = could keep billing if left alone. expired/revoked/refunded don't charge, so skip.
const CHARGEABLE_STATUSES = "('active','trialing','grace_period','canceled')";

interface CancelSubRow {
  provider: SubscriptionProvider;
  provider_subscription_id: string;
}

/**
 * On account deletion, stop the orphaned charges: cancel the Stripe subscriptions (we hold the secret
 * key) and count the Apple ones — an Apple subscription can ONLY be canceled by the user in App Store
 * settings, so the caller surfaces cancel guidance when appleNeedsManualCancel > 0. Best-effort: a
 * failed Stripe cancel is counted, not thrown (the account delete still proceeds; the cron backstops).
 */
export async function cancelSubscriptionsForAccount(
  sql: Sql,
  deps: { stripe: StripeClient | null },
  userId: string,
): Promise<AccountSubsResult> {
  const subs = await sql
    .prepare(`SELECT provider, provider_subscription_id FROM subscriptions WHERE user_id = ? AND status IN ${CHARGEABLE_STATUSES}`)
    .bind(userId)
    .all<CancelSubRow>();
  let canceledStripe = 0;
  let stripeCancelFailures = 0;
  let appleNeedsManualCancel = 0;

  for (const sub of subs) {
    if (sub.provider === "stripe") {
      if (deps.stripe && (await deps.stripe.cancelSubscription(sub.provider_subscription_id))) {
        canceledStripe++;
      } else {
        stripeCancelFailures++;
      }
    } else if (sub.provider === "apple") {
      appleNeedsManualCancel++;
    }
  }
  return { canceledStripe, stripeCancelFailures, appleNeedsManualCancel };
}
