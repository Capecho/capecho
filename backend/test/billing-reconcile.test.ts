import { test, expect } from "bun:test";
import worker from "../src/index.ts";
import { makeEnv } from "./helpers/worker-env.ts";
import { freshDb, ids, seedAccount } from "./helpers/db.ts";
import { getAccount } from "../src/accounts.ts";
import { applySubscriptionUpdate, getSubscriptionByProviderId, type SubscriptionUpdate } from "../src/entitlement.ts";
import {
  reconcileSubscriptions,
  cancelSubscriptionsForAccount,
  type ReconcileDeps,
  type StripeClient,
} from "../src/billing/reconcile.ts";
import type { AppleApiClient, AppleStatusResponse, AppleTransactionInfo } from "../src/billing/apple.ts";
import type { Sql } from "../src/sql.ts";
import type { Env } from "../src/index.ts";

const ctx = {} as ExecutionContext;

// --- helpers -----------------------------------------------------------------

let eseq = 0;
/** Seed a subscription row by applying an initial event. */
async function seedSub(sql: Sql, over: Partial<SubscriptionUpdate>): Promise<void> {
  await applySubscriptionUpdate(sql, {
    provider: "stripe",
    providerEventId: `seed-${++eseq}`,
    providerSubscriptionId: "sub_S",
    userId: "u1",
    status: "active",
    currentPeriodEnd: 1_000_000,
    cancelAtPeriodEnd: false,
    eventTs: 100,
    eventType: "seed",
    now: 5000,
    newId: ids("seed"),
    ...over,
  });
}

const stripeSubObj = (over: Record<string, unknown> = {}): Record<string, unknown> => ({
  id: "sub_S",
  status: "active",
  current_period_end: 2000, // unix seconds → 2_000_000 ms
  cancel_at_period_end: false,
  metadata: { capecho_user_id: "u1" },
  ...over,
});

const stripeClient = (obj: unknown | null, canceled = true): StripeClient => ({
  fetchSubscription: async () => obj,
  cancelSubscription: async () => canceled,
});

function b64url(s: string): string {
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
const fakeJws = (payload: unknown): string => `${b64url("{}")}.${b64url(JSON.stringify(payload))}.${b64url("s")}`;
const appleClient = (tx: Partial<AppleTransactionInfo>, status = 1): AppleApiClient => ({
  getSubscriptionStatuses: async (): Promise<AppleStatusResponse> => ({
    environment: "Production",
    data: [{ lastTransactions: [{ originalTransactionId: tx.originalTransactionId, status, signedTransactionInfo: fakeJws(tx) }] }],
  }),
});

function deps(over: Partial<ReconcileDeps> = {}): ReconcileDeps {
  return {
    stripe: stripeClient(stripeSubObj()),
    appleClient: null,
    appleExpectedEnvironment: "Production",
    newId: ids("r"),
    ...over,
  };
}

// --- T6: reconciliation ------------------------------------------------------

test("reconcile: a missed Stripe renewal is corrected — pro_until advances to the live period end", async () => {
  const { sql } = freshDb();
  await seedAccount(sql, "u1");
  await seedSub(sql, { currentPeriodEnd: 1_000_000, eventTs: 100 }); // old state (active through 1_000_000)
  expect((await getAccount(sql, "u1"))?.pro_until).toBe(1_000_000);

  // the renewal webhook was dropped; the live sub is active far into the future.
  const r = await reconcileSubscriptions(sql, deps({ stripe: stripeClient(stripeSubObj({ current_period_end: 9000 })) }), 2_000_000);
  expect(r).toEqual({ checked: 1, applied: 1, skipped: 0, errors: 0 });
  expect((await getAccount(sql, "u1"))?.pro_until).toBe(9_000_000); // 9000s → 9_000_000ms
});

test("reconcile: a Stripe cancellation the webhook missed is caught (status → canceled, horizon held to period end)", async () => {
  const { sql } = freshDb();
  await seedAccount(sql, "u1");
  await seedSub(sql, { currentPeriodEnd: 9_000_000, eventTs: 100 });
  // live sub now shows canceled (won't renew) but still through its period end.
  const r = await reconcileSubscriptions(sql, deps({ stripe: stripeClient(stripeSubObj({ status: "canceled", current_period_end: 9000, cancel_at_period_end: true })) }), 2_000_000);
  expect(r.applied).toBe(1);
  expect((await getSubscriptionByProviderId(sql, "stripe", "sub_S"))?.status).toBe("canceled");
});

test("reconcile: an unconfigured provider is skipped; a failed fetch is an error (not a throw)", async () => {
  const { sql } = freshDb();
  await seedAccount(sql, "u1");
  await seedSub(sql, {});
  expect(await reconcileSubscriptions(sql, deps({ stripe: null }), 2_000_000)).toMatchObject({ checked: 1, skipped: 1 });
  expect(await reconcileSubscriptions(sql, deps({ stripe: stripeClient(null) }), 2_000_000)).toMatchObject({ checked: 1, errors: 1 });
});

test("reconcile: a terminal (revoked/refunded) sub is NOT reconciled", async () => {
  const { sql } = freshDb();
  await seedAccount(sql, "u1");
  await seedSub(sql, { providerSubscriptionId: "sub_live", status: "active", eventTs: 100 });
  await seedSub(sql, { providerSubscriptionId: "sub_dead", status: "revoked", eventTs: 100 });
  const r = await reconcileSubscriptions(sql, deps(), 2_000_000);
  expect(r.checked).toBe(1); // only the live one
});

test("reconcile: an Apple sub re-fetches authoritative status at the honored environment", async () => {
  const { sql } = freshDb();
  await seedAccount(sql, "u1");
  await seedSub(sql, { provider: "apple", providerSubscriptionId: "ot_1", currentPeriodEnd: 1_000_000, eventTs: 100 });
  const r = await reconcileSubscriptions(
    sql,
    deps({ stripe: null, appleClient: appleClient({ originalTransactionId: "ot_1", appAccountToken: "u1", expiresDate: 9_000_000, signedDate: 2000 }) }),
    2_000_000,
  );
  expect(r.applied).toBe(1);
  expect((await getAccount(sql, "u1"))?.pro_until).toBe(9_000_000);
});

// --- T7: cancel on account deletion ------------------------------------------

test("cancelSubscriptionsForAccount: cancels Stripe server-side; flags Apple for manual cancel", async () => {
  const { sql } = freshDb();
  await seedAccount(sql, "u1");
  await seedSub(sql, { provider: "stripe", providerSubscriptionId: "sub_S", status: "active", eventTs: 100 });
  await seedSub(sql, { provider: "apple", providerSubscriptionId: "ot_A", status: "active", eventTs: 100 });
  const r = await cancelSubscriptionsForAccount(sql, { stripe: stripeClient(null, true) }, "u1");
  expect(r).toEqual({ canceledStripe: 1, stripeCancelFailures: 0, appleNeedsManualCancel: 1 });
});

test("cancelSubscriptionsForAccount: a Stripe cancel failure (or no key) is counted, not thrown", async () => {
  const { sql } = freshDb();
  await seedAccount(sql, "u1");
  await seedSub(sql, { provider: "stripe", providerSubscriptionId: "sub_S", status: "active", eventTs: 100 });
  expect(await cancelSubscriptionsForAccount(sql, { stripe: stripeClient(null, false) }, "u1")).toMatchObject({ stripeCancelFailures: 1 });
  expect(await cancelSubscriptionsForAccount(sql, { stripe: null }, "u1")).toMatchObject({ stripeCancelFailures: 1 });
});

test("cancelSubscriptionsForAccount: only chargeable subs are touched (expired/revoked skipped)", async () => {
  const { sql } = freshDb();
  await seedAccount(sql, "u1");
  await seedSub(sql, { provider: "stripe", providerSubscriptionId: "sub_exp", status: "expired", eventTs: 100 });
  const r = await cancelSubscriptionsForAccount(sql, { stripe: stripeClient(null, true) }, "u1");
  expect(r).toEqual({ canceledStripe: 0, stripeCancelFailures: 0, appleNeedsManualCancel: 0 });
});

test("e2e: DELETE /account flags an active Apple subscription for user-side cancellation", async () => {
  const h = makeEnv(); // DEV_TRUST_USER_HEADER on; no Stripe key
  await seedAccount(h.sql, "u1");
  await applySubscriptionUpdate(h.sql, {
    provider: "apple",
    providerEventId: "a1",
    providerSubscriptionId: "ot_A",
    userId: "u1",
    status: "active",
    currentPeriodEnd: 9_000_000,
    cancelAtPeriodEnd: false,
    eventTs: 100,
    eventType: "seed",
    now: 5000,
    newId: ids("a"),
  });
  const res = await worker.fetch!(
    new Request("https://capecho.test/account", { method: "DELETE", headers: { "x-capecho-user-id": "u1" } }),
    h.env,
    ctx,
  );
  expect(res.status).toBe(200);
  expect((await res.json()) as unknown).toEqual({ status: "deletion_scheduled", apple_subscription_cancel_required: true });
  expect((await getAccount(h.sql, "u1"))?.deleted_at).not.toBeNull(); // still marked for deletion
});
