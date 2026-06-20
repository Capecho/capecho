import type { Sql } from "./sql.ts";

// Server-authoritative Pro entitlement. Two providers (Stripe + Apple),
// account-scoped (buy-once-unlock-everywhere). `accounts.pro_until` is a DENORMALIZED cache of the
// entitlement horizon; the authoritative value is MAX(current_period_end) over the account's
// non-refunded/non-revoked subscriptions, rebuildable at any time via recomputeProUntil.
//
// Provider delivery is at-least-once AND out-of-order, so applySubscriptionUpdate is:
//   • idempotent — subscription_events UNIQUE(provider, provider_event_id); a replay is a no-op.
//   • monotonic  — subscriptions.last_event_ts; an event older than the last APPLIED one is recorded
//                  for audit but never mutates state, so a stale `canceled` can't downgrade a payer (C1).
// The webhook handlers pair this with a canonical provider-API fetch on key events (OV3) and a
// reconciliation cron (T6) backstops any residual drift — so the entitlement here only needs a sane
// monotonic ordering token per event (Apple signedDate / Stripe event.created).

export type SubscriptionProvider = "stripe" | "apple";

export type SubscriptionStatus =
  | "active" // paid, current
  | "trialing" // intro / free trial (entitled)
  | "grace_period" // billing retry / Apple billing grace (entitled through current_period_end)
  | "canceled" // will not renew; entitled until current_period_end
  | "expired" // lapsed (period ended, no renewal)
  | "revoked" // entitlement pulled (Apple REVOKE / family-share removal)
  | "refunded"; // money returned (Apple REFUND / Stripe refund) — access removed

export const SUBSCRIPTION_STATUSES: readonly SubscriptionStatus[] = [
  "active",
  "trialing",
  "grace_period",
  "canceled",
  "expired",
  "revoked",
  "refunded",
];

/** Does the account currently hold Pro? Pure read of the denormalized horizon (clients call /auth/me;
 *  the server gates Pro-only paths with this). `now` is injected so it's deterministic in tests. */
export function isPro(account: { pro_until: number | null }, now: number): boolean {
  return account.pro_until !== null && account.pro_until > now;
}

/**
 * Recompute accounts.pro_until from the account's subscriptions and persist the cache. Returns the new
 * horizon (epoch ms) or null. The horizon is MAX(current_period_end) over subs whose status still
 * GRANTS — i.e. everything except `refunded`/`revoked`, which claw back access immediately even though
 * their period_end is still in the future. A plain `canceled` (cancel-at-period-end) keeps granting
 * until its period_end, which is correct billing behavior. `expired` rows have a past period_end so
 * they can't lift the horizon above `now` regardless. Call after every applied subscription change.
 *
 * NOTE: this OVERWRITES any manually-set pro_until. A founder-comp account (A6/OV2) must therefore have
 * no `subscriptions` rows — it never gets here.
 */
export async function recomputeProUntil(sql: Sql, userId: string): Promise<number | null> {
  const row = await sql
    .prepare(
      `SELECT MAX(current_period_end) AS horizon
         FROM subscriptions
        WHERE user_id = ? AND current_period_end IS NOT NULL
          AND status NOT IN ('revoked','refunded')`,
    )
    .bind(userId)
    .first<{ horizon: number | null }>();
  const horizon = row?.horizon ?? null;
  await sql.prepare(`UPDATE accounts SET pro_until = ? WHERE id = ?`).bind(horizon, userId).run();
  return horizon;
}

export interface SubscriptionUpdate {
  provider: SubscriptionProvider;
  /** the provider's unique event id (Stripe event.id / Apple notificationUUID) — the idempotency key */
  providerEventId: string;
  /** Stripe subscription id / Apple originalTransactionId — identifies the subscription row */
  providerSubscriptionId: string;
  userId: string;
  status: SubscriptionStatus;
  /** entitlement horizon for this sub (epoch ms); null when not yet known from the provider */
  currentPeriodEnd: number | null;
  cancelAtPeriodEnd: boolean;
  /** provider event time — the monotonic ordering source (out-of-order-delivery safe) */
  eventTs: number;
  /** raw provider event/notification type, recorded for audit */
  eventType: string;
  now: number;
  newId: () => string;
  /** compact JSON audit summary — billing metadata ONLY (never card data / address / user content) */
  auditPayload?: string | null;
  /**
   * Permit re-assigning this provider subscription to `userId` when it currently belongs to a DIFFERENT
   * account, instead of refusing with `account_mismatch`. Set ONLY on the Apple /verify TRANSFER path,
   * and ONLY after the posted transaction's JWS signature has been verified (see apple-jws.ts) — so an
   * Apple ID's active subscription unlocks for whoever is signed in (App Store Guideline 2.1(a)) without
   * reopening the forgeable-transaction-id hole. The previous owner's entitlement is recomputed too.
   */
  allowTransfer?: boolean;
}

export type ApplyOutcome =
  | { applied: true; proUntil: number | null; transferredFrom?: string } // state advanced; entitlement recomputed
  | { applied: false; reason: "duplicate" } // replayed provider_event_id — recorded once, no-op now
  | { applied: false; reason: "stale"; proUntil: number | null; transferredFrom?: string } // older than the last applied event
  | { applied: false; reason: "account_mismatch" } // this provider sub already belongs to another account
  | { applied: false; reason: "account_missing" }; // userId isn't a live account (purged / forged token)

/**
 * Apply one provider subscription event to the entitlement state. Records the event (idempotent),
 * upserts the subscription under a monotonic guard, and recomputes the denormalized pro_until. Safe
 * under replay and out-of-order delivery (see the file header). Returns whether state actually advanced.
 */
export async function applySubscriptionUpdate(sql: Sql, u: SubscriptionUpdate): Promise<ApplyOutcome> {
  // 0. Ownership invariant: a provider subscription belongs to exactly ONE account. If this sub already
  //    exists under a DIFFERENT account, refuse — the "same Apple original-transaction restored into a
  //    2nd Capecho account" case. Defense-in-depth: the Stripe/Apple verify handlers (T4/T5)
  //    resolve the right account upstream via appAccountToken, but the core enforces it too. Checked
  //    BEFORE recording so a foreign event never pollutes this sub's log.
  //    EXCEPTION — `allowTransfer` (the JWS-verified Apple /verify path): re-assign ownership to `userId`
  //    instead of refusing, so an Apple ID's active subscription follows the signed-in account. The
  //    re-assign is unconditional (NOT under the monotonic guard below) because the existing row may
  //    already carry this exact authoritative state under the old owner — the value upsert would then be a
  //    no-op, but ownership must still move. The previous owner's horizon is recomputed at the end.
  const existing = await getSubscriptionByProviderId(sql, u.provider, u.providerSubscriptionId);
  let transferredFrom: string | undefined;
  if (existing && existing.user_id !== u.userId) {
    if (!u.allowTransfer) return { applied: false, reason: "account_mismatch" };
    // Re-assign ownership to the caller, CONDITIONED on the owner we just read. If a concurrent transfer
    // moved the row first, this writes 0 rows and we did NOT win — `transferredFrom` stays unset and the
    // recompute below leaves the caller without a row (no stale Pro on a race loser). Last writer wins
    // deterministically rather than both claimants caching a grant. Unconditional would let two concurrent
    // verifies each believe they displaced the original owner.
    const moved = await sql
      .prepare(
        `UPDATE subscriptions SET user_id = ?, updated_at = ?
           WHERE provider = ? AND provider_subscription_id = ? AND user_id = ?`,
      )
      .bind(u.userId, u.now, u.provider, u.providerSubscriptionId, existing.user_id)
      .run();
    if (moved.rowsWritten === 1) transferredFrom = existing.user_id;
  }

  // 0.5. The userId must be a LIVE account. Both inserts below carry user_id as a FK to accounts; a
  //      non-account id raises a FOREIGN KEY violation that would bubble to a 500 — and since the
  //      providers RETRY non-2xx, that becomes an infinite retry storm. Two real triggers: a forged /
  //      non-account `appAccountToken` on the Apple rail, and an account hard-purged (retention sweep)
  //      between Stripe checkout and a late `subscription.updated/deleted`. Treat it as unattributable
  //      (the caller acks + logs) instead of throwing. Checked before the event is recorded.
  const acct = await sql.prepare(`SELECT 1 AS ok FROM accounts WHERE id = ?`).bind(u.userId).first<{ ok: number }>();
  if (!acct) return { applied: false, reason: "account_missing" };

  // 1. Idempotency: record the event exactly once. A replay (same provider_event_id) writes nothing.
  const evt = await sql
    .prepare(
      `INSERT INTO subscription_events
         (id, provider, provider_event_id, provider_subscription_id, user_id, type, event_ts, payload, received_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (provider, provider_event_id) DO NOTHING`,
    )
    .bind(
      u.newId(),
      u.provider,
      u.providerEventId,
      u.providerSubscriptionId,
      u.userId,
      u.eventType,
      u.eventTs,
      u.auditPayload ?? null,
      u.now,
    )
    .run();
  if (evt.rowsWritten === 0) return { applied: false, reason: "duplicate" };

  // 2. Upsert the subscription under the monotonic guard. The DO UPDATE ... WHERE makes a stale event
  //    (event time <= the last applied) a no-op: it never overwrites a newer state. A brand-new sub
  //    inserts cleanly with last_event_ts = eventTs. rowsWritten === 1 ⇒ state advanced; 0 ⇒ stale.
  const sub = await sql
    .prepare(
      `INSERT INTO subscriptions
         (id, user_id, provider, provider_subscription_id, status, current_period_end, cancel_at_period_end, last_event_ts, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (provider, provider_subscription_id) DO UPDATE SET
         status = excluded.status,
         current_period_end = excluded.current_period_end,
         cancel_at_period_end = excluded.cancel_at_period_end,
         last_event_ts = excluded.last_event_ts,
         updated_at = excluded.updated_at
       WHERE excluded.last_event_ts > subscriptions.last_event_ts`,
    )
    .bind(
      u.newId(),
      u.userId,
      u.provider,
      u.providerSubscriptionId,
      u.status,
      u.currentPeriodEnd,
      u.cancelAtPeriodEnd ? 1 : 0,
      u.eventTs,
      u.now,
      u.now,
    )
    .run();

  // 3. Recompute the denormalized horizon from the (possibly unchanged) subscription set. Cheap and
  //    always-correct; on a stale event nothing changed but the recompute is a harmless no-op write. On a
  //    transfer, the PREVIOUS owner just lost this sub, so recompute their horizon too (it may drop to null).
  const proUntil = await recomputeProUntil(sql, u.userId);
  if (transferredFrom) await recomputeProUntil(sql, transferredFrom);
  return sub.rowsWritten === 1
    ? { applied: true, proUntil, transferredFrom }
    : { applied: false, reason: "stale", proUntil, transferredFrom };
}

/** Read a single subscription row by provider id (reconciliation / restore / tests). */
export interface SubscriptionRow {
  id: string;
  user_id: string;
  provider: SubscriptionProvider;
  provider_subscription_id: string;
  status: SubscriptionStatus;
  current_period_end: number | null;
  cancel_at_period_end: number;
  last_event_ts: number;
  created_at: number;
  updated_at: number;
}

export async function getSubscriptionByProviderId(
  sql: Sql,
  provider: SubscriptionProvider,
  providerSubscriptionId: string,
): Promise<SubscriptionRow | null> {
  return sql
    .prepare(
      `SELECT id, user_id, provider, provider_subscription_id, status, current_period_end,
              cancel_at_period_end, last_event_ts, created_at, updated_at
         FROM subscriptions WHERE provider = ? AND provider_subscription_id = ?`,
    )
    .bind(provider, providerSubscriptionId)
    .first<SubscriptionRow>();
}
