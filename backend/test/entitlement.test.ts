import { test, expect, beforeEach } from "bun:test";
import { freshDb, ids, seedAccount } from "./helpers/db.ts";
import {
  isPro,
  recomputeProUntil,
  applySubscriptionUpdate,
  getSubscriptionByProviderId,
  type SubscriptionUpdate,
} from "../src/entitlement.ts";
import { getAccount } from "../src/accounts.ts";
import type { Sql } from "../src/sql.ts";

let sql: Sql;
let newId: () => string;

beforeEach(async () => {
  ({ sql } = freshDb());
  newId = ids("sub");
  await seedAccount(sql, "u1");
  await seedAccount(sql, "u2");
});

const DAY = 24 * 60 * 60 * 1000;
let eseq = 0;

/** A subscription event builder — defaults to a healthy active Stripe sub for u1; override per test. */
function evt(over: Partial<SubscriptionUpdate> = {}): SubscriptionUpdate {
  return {
    provider: "stripe",
    providerEventId: `evt-${++eseq}`,
    providerSubscriptionId: "sub_A",
    userId: "u1",
    status: "active",
    currentPeriodEnd: 10_000 + 30 * DAY,
    cancelAtPeriodEnd: false,
    eventTs: 1000,
    eventType: "customer.subscription.updated",
    now: 5000,
    newId,
    ...over,
  };
}

const countEvents = async (subId: string): Promise<number> =>
  Number(
    (
      await sql
        .prepare(`SELECT COUNT(*) AS n FROM subscription_events WHERE provider_subscription_id = ?`)
        .bind(subId)
        .first<{ n: number }>()
    )?.n ?? -1,
  );

test("isPro: a strictly-future horizon grants; equal/past/null does not", () => {
  expect(isPro({ pro_until: null }, 100)).toBe(false);
  expect(isPro({ pro_until: 100 }, 100)).toBe(false); // equal is NOT pro (strict >)
  expect(isPro({ pro_until: 101 }, 100)).toBe(true);
  expect(isPro({ pro_until: 99 }, 100)).toBe(false);
});

test("recomputeProUntil: null with no subs; MAX across rails; persisted to the cache", async () => {
  expect(await recomputeProUntil(sql, "u1")).toBeNull();
  expect((await getAccount(sql, "u1"))?.pro_until).toBeNull();

  await applySubscriptionUpdate(sql, evt({ provider: "stripe", providerSubscriptionId: "sub_S", currentPeriodEnd: 200 }));
  await applySubscriptionUpdate(sql, evt({ provider: "apple", providerSubscriptionId: "appl_A", currentPeriodEnd: 500 }));
  expect(await recomputeProUntil(sql, "u1")).toBe(500); // MAX(200, 500)
  expect((await getAccount(sql, "u1"))?.pro_until).toBe(500);
});

test("a fresh active sub grants Pro and sets the horizon", async () => {
  const r = await applySubscriptionUpdate(sql, evt({ currentPeriodEnd: 9_000_000 }));
  expect(r.applied).toBe(true);
  if (r.applied) expect(r.proUntil).toBe(9_000_000);
  expect(isPro((await getAccount(sql, "u1"))!, 5000)).toBe(true);
});

test("idempotent: replaying the same provider_event_id is a no-op, recorded once", async () => {
  const e = evt({ providerEventId: "evt-dup", currentPeriodEnd: 100 });
  expect((await applySubscriptionUpdate(sql, e)).applied).toBe(true);
  expect(await applySubscriptionUpdate(sql, e)).toEqual({ applied: false, reason: "duplicate" });
  expect(await countEvents("sub_A")).toBe(1);
});

test("monotonic: a stale 'expired' delivered after a renewal does NOT downgrade a payer", async () => {
  // Newer event first: renewed/active, far-future, ts=200.
  await applySubscriptionUpdate(
    sql,
    evt({ providerEventId: "e-renew", status: "active", currentPeriodEnd: 9_000_000, eventTs: 200 }),
  );
  expect((await getAccount(sql, "u1"))?.pro_until).toBe(9_000_000);

  // Out-of-order STALE event: an older expired/canceled, ts=100.
  const stale = await applySubscriptionUpdate(
    sql,
    evt({ providerEventId: "e-stale", status: "expired", currentPeriodEnd: 100, eventTs: 100 }),
  );
  expect(stale.applied).toBe(false);
  if (!stale.applied && stale.reason === "stale") expect(stale.proUntil).toBe(9_000_000);

  // The subscription is UNCHANGED — the payer keeps Pro — but the stale event is recorded for audit.
  const sub = await getSubscriptionByProviderId(sql, "stripe", "sub_A");
  expect(sub?.status).toBe("active");
  expect(sub?.current_period_end).toBe(9_000_000);
  expect((await getAccount(sql, "u1"))?.pro_until).toBe(9_000_000);
  expect(await countEvents("sub_A")).toBe(2);
});

test("a newer event advances state and lifts the horizon", async () => {
  await applySubscriptionUpdate(sql, evt({ providerEventId: "e1", currentPeriodEnd: 1000, eventTs: 100 }));
  const r = await applySubscriptionUpdate(sql, evt({ providerEventId: "e2", currentPeriodEnd: 9_000_000, eventTs: 200 }));
  expect(r.applied).toBe(true);
  expect((await getSubscriptionByProviderId(sql, "stripe", "sub_A"))?.current_period_end).toBe(9_000_000);
  expect((await getAccount(sql, "u1"))?.pro_until).toBe(9_000_000);
});

test("refund claws back access immediately, even with a future period_end", async () => {
  await applySubscriptionUpdate(sql, evt({ providerEventId: "e1", status: "active", currentPeriodEnd: 9_000_000, eventTs: 100 }));
  expect(isPro((await getAccount(sql, "u1"))!, 5000)).toBe(true);

  const r = await applySubscriptionUpdate(sql, evt({ providerEventId: "e2", status: "refunded", currentPeriodEnd: 9_000_000, eventTs: 200 }));
  expect(r.applied).toBe(true);
  if (r.applied) expect(r.proUntil).toBeNull(); // refunded sub excluded from MAX → no horizon
  expect(isPro((await getAccount(sql, "u1"))!, 5000)).toBe(false);
});

test("a plain 'canceled' (won't renew) keeps Pro through its period_end — only refund/revoke claw back early", async () => {
  const r = await applySubscriptionUpdate(
    sql,
    evt({ status: "canceled", cancelAtPeriodEnd: true, currentPeriodEnd: 9_000_000, eventTs: 100 }),
  );
  expect(r.applied).toBe(true);
  expect(isPro((await getAccount(sql, "u1"))!, 5000)).toBe(true);
});

test("cross-rail: refunding one rail keeps Pro from the other", async () => {
  await applySubscriptionUpdate(sql, evt({ provider: "stripe", providerSubscriptionId: "sub_S", providerEventId: "s1", currentPeriodEnd: 1000, eventTs: 100 }));
  await applySubscriptionUpdate(sql, evt({ provider: "apple", providerSubscriptionId: "appl_A", providerEventId: "a1", currentPeriodEnd: 9_000_000, eventTs: 100 }));
  expect((await getAccount(sql, "u1"))?.pro_until).toBe(9_000_000);

  await applySubscriptionUpdate(sql, evt({ provider: "stripe", providerSubscriptionId: "sub_S", providerEventId: "s2", status: "refunded", currentPeriodEnd: 1000, eventTs: 200 }));
  expect((await getAccount(sql, "u1"))?.pro_until).toBe(9_000_000); // apple rail still grants
  expect(isPro((await getAccount(sql, "u1"))!, 5000)).toBe(true);
});

test("ownership: a provider sub bound to one account is rejected for another — no entitlement leak", async () => {
  await applySubscriptionUpdate(sql, evt({ userId: "u1", providerSubscriptionId: "sub_X", providerEventId: "x1", currentPeriodEnd: 9_000_000, eventTs: 100 }));
  // u2 tries to claim the SAME provider subscription id (restore into a 2nd account).
  const r = await applySubscriptionUpdate(sql, evt({ userId: "u2", providerSubscriptionId: "sub_X", providerEventId: "x2", currentPeriodEnd: 9_000_000, eventTs: 200 }));
  expect(r).toEqual({ applied: false, reason: "account_mismatch" });

  expect((await getAccount(sql, "u2"))?.pro_until).toBeNull(); // u2 got nothing
  expect((await getAccount(sql, "u1"))?.pro_until).toBe(9_000_000); // u1 still owns it
  expect((await getSubscriptionByProviderId(sql, "stripe", "sub_X"))?.user_id).toBe("u1");
  expect(await countEvents("sub_X")).toBe(1); // u2's foreign event was NOT recorded against the sub
});

test("allowTransfer: re-assigns a sub from its old owner to the caller + recomputes BOTH horizons", async () => {
  // The JWS-verified Apple /verify TRANSFER path: u1 owns the sub (e.g. a prior account on the same Apple
  // ID); u2 (the signed-in account) claims it. Ownership + Pro move to u2; u1's horizon drops.
  await applySubscriptionUpdate(sql, evt({ userId: "u1", providerSubscriptionId: "sub_X", providerEventId: "x1", currentPeriodEnd: 9_000_000, eventTs: 100 }));
  expect((await getAccount(sql, "u1"))?.pro_until).toBe(9_000_000);

  const r = await applySubscriptionUpdate(sql, evt({ userId: "u2", providerSubscriptionId: "sub_X", providerEventId: "x2", currentPeriodEnd: 9_000_000, eventTs: 200, allowTransfer: true }));
  expect(r).toEqual({ applied: true, proUntil: 9_000_000, transferredFrom: "u1" });
  expect((await getAccount(sql, "u2"))?.pro_until).toBe(9_000_000); // caller now holds Pro
  expect((await getAccount(sql, "u1"))?.pro_until).toBeNull(); // old owner's horizon recomputed away
  expect((await getSubscriptionByProviderId(sql, "stripe", "sub_X"))?.user_id).toBe("u2");
});

test("allowTransfer: ownership moves even when the value-upsert is stale (identical authoritative state)", async () => {
  // The exact App Review case: the sub was already applied to u1 at eventTs=100; u2 claims the SAME current
  // transaction (same eventTs). The monotonic value-upsert is a no-op, but ownership must still transfer so
  // the caller gets Pro — otherwise the reviewer's new account stays blocked.
  await applySubscriptionUpdate(sql, evt({ userId: "u1", providerSubscriptionId: "sub_X", providerEventId: "x1", currentPeriodEnd: 9_000_000, eventTs: 100 }));
  const r = await applySubscriptionUpdate(sql, evt({ userId: "u2", providerSubscriptionId: "sub_X", providerEventId: "x2", currentPeriodEnd: 9_000_000, eventTs: 100, allowTransfer: true }));
  expect(r.applied).toBe(false); // value-upsert was stale…
  if (!r.applied && r.reason === "stale") expect(r.transferredFrom).toBe("u1");
  expect((await getAccount(sql, "u2"))?.pro_until).toBe(9_000_000); // …but ownership + Pro still moved
  expect((await getAccount(sql, "u1"))?.pro_until).toBeNull();
  expect((await getSubscriptionByProviderId(sql, "stripe", "sub_X"))?.user_id).toBe("u2");
});

test("a non-account userId is unattributable (no FK throw, no rows written)", async () => {
  // A forged/garbage appAccountToken, or an account hard-purged between checkout and a late event. The
  // user_id FK would otherwise throw → 500 → provider retry storm; instead it's a clean account_missing.
  const r = await applySubscriptionUpdate(sql, evt({ userId: "ghost", providerSubscriptionId: "sub_G", providerEventId: "g1" }));
  expect(r).toEqual({ applied: false, reason: "account_missing" });
  expect(await countEvents("sub_G")).toBe(0); // nothing recorded
  expect(await getSubscriptionByProviderId(sql, "stripe", "sub_G")).toBeNull(); // no sub row
});

test("an expired-only sub leaves a past horizon → not Pro", async () => {
  await applySubscriptionUpdate(sql, evt({ status: "expired", currentPeriodEnd: 100, eventTs: 50 }));
  const acct = (await getAccount(sql, "u1"))!;
  expect(acct.pro_until).toBe(100); // included in MAX (not revoked/refunded), but it's in the past
  expect(isPro(acct, 5000)).toBe(false);
});
