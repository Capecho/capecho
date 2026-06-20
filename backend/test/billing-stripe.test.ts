import { test, expect } from "bun:test";
import worker from "../src/index.ts";
import { makeEnv } from "./helpers/worker-env.ts";
import { seedAccount } from "./helpers/db.ts";
import { getAccount } from "../src/accounts.ts";
import {
  verifyStripeSignature,
  mapStripeEvent,
  mapStripeStatus,
  buildCheckoutForm,
  parseCheckoutUrl,
  resolvePriceId,
} from "../src/billing/stripe.ts";
import type { Env } from "../src/index.ts";

const ctx = {} as ExecutionContext;
const SECRET = "whsec_test_secret";

/** Sign a payload the way Stripe does: header "t=<unix>,v1=<hmac-sha256 hex of `${t}.${payload}`>". */
async function stripeSign(payload: string, secret: string, tSec: number): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${tSec}.${payload}`));
  const hex = [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `t=${tSec},v1=${hex}`;
}

const DAY = 24 * 60 * 60 * 1000;
function subEvent(over: Record<string, unknown> = {}, objOver: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "evt_1",
    type: "customer.subscription.updated",
    created: 1_700_000_000,
    data: {
      object: {
        id: "sub_123",
        status: "active",
        current_period_end: 1_700_000_000 + 30 * 24 * 3600, // unix seconds
        cancel_at_period_end: false,
        metadata: { capecho_user_id: "u1" },
        ...objOver,
      },
    },
    ...over,
  };
}

// --- unit: signature verification --------------------------------------------

test("verifyStripeSignature: a correctly-signed body passes", async () => {
  const body = JSON.stringify({ hello: "world" });
  const t = Math.floor(Date.now() / 1000);
  const sig = await stripeSign(body, SECRET, t);
  expect(await verifyStripeSignature(body, sig, SECRET, Date.now())).toEqual({ ok: true });
});

test("verifyStripeSignature: a tampered body fails", async () => {
  const t = Math.floor(Date.now() / 1000);
  const sig = await stripeSign(JSON.stringify({ amount: 1 }), SECRET, t);
  const r = await verifyStripeSignature(JSON.stringify({ amount: 999999 }), sig, SECRET, Date.now());
  expect(r.ok).toBe(false);
});

test("verifyStripeSignature: a missing header, malformed header, and stale timestamp all fail", async () => {
  const body = "{}";
  const t = Math.floor(Date.now() / 1000);
  expect((await verifyStripeSignature(body, null, SECRET, Date.now())).ok).toBe(false);
  expect((await verifyStripeSignature(body, "garbage", SECRET, Date.now())).ok).toBe(false);
  // valid signature but the timestamp is 10 minutes old → outside the 5-min replay window
  const stale = await stripeSign(body, SECRET, t - 600);
  const r = await verifyStripeSignature(body, stale, SECRET, Date.now());
  expect(r).toEqual({ ok: false, reason: "timestamp_out_of_tolerance" });
});

test("verifyStripeSignature: the wrong secret fails", async () => {
  const body = "{}";
  const t = Math.floor(Date.now() / 1000);
  const sig = await stripeSign(body, "whsec_attacker", t);
  expect((await verifyStripeSignature(body, sig, SECRET, Date.now())).ok).toBe(false);
});

// --- unit: event mapping -----------------------------------------------------

test("mapStripeStatus: Stripe statuses → entitlement statuses", () => {
  expect(mapStripeStatus("active")).toBe("active");
  expect(mapStripeStatus("trialing")).toBe("trialing");
  expect(mapStripeStatus("past_due")).toBe("grace_period");
  expect(mapStripeStatus("canceled")).toBe("canceled");
  expect(mapStripeStatus("unpaid")).toBe("expired");
  expect(mapStripeStatus("incomplete_expired")).toBe("expired");
  expect(mapStripeStatus("something_new")).toBe("expired"); // unknown → fail safe
});

test("mapStripeEvent: a subscription event maps to an entitlement update", () => {
  const r = mapStripeEvent(subEvent());
  expect(r.kind).toBe("update");
  if (r.kind !== "update") return;
  expect(r.update.provider).toBe("stripe");
  expect(r.update.providerEventId).toBe("evt_1");
  expect(r.update.providerSubscriptionId).toBe("sub_123");
  expect(r.update.userId).toBe("u1");
  expect(r.update.status).toBe("active");
  expect(r.update.currentPeriodEnd).toBe((1_700_000_000 + 30 * 24 * 3600) * 1000); // sec → ms
  expect(r.update.eventTs).toBe(1_700_000_000 * 1000);
});

test("mapStripeEvent: a non-subscription event is ignored; a sub event without capecho_user_id is unlinked", () => {
  expect(mapStripeEvent({ id: "e", type: "payment_intent.succeeded" }).kind).toBe("ignored");
  expect(mapStripeEvent(subEvent({}, { metadata: {} })).kind).toBe("unlinked");
  expect(mapStripeEvent(null).kind).toBe("ignored");
  expect(mapStripeEvent({ type: "customer.subscription.updated" }).kind).toBe("ignored"); // no id/object
});

// --- e2e: through the real worker.fetch --------------------------------------

function stripeEnv(): { env: Env; sql: Awaited<ReturnType<typeof makeEnv>>["sql"] } {
  const h = makeEnv();
  (h.env as Record<string, unknown>).STRIPE_WEBHOOK_SECRET = SECRET;
  return { env: h.env, sql: h.sql };
}

function postWebhook(env: Env, body: string, sig: string | null): Promise<Response> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (sig) headers["stripe-signature"] = sig;
  return worker.fetch!(
    new Request("https://capecho.test/billing/stripe/webhook", { method: "POST", headers, body }),
    env,
    ctx,
  );
}

test("e2e: a signed subscription event grants Pro; a replay is idempotent", async () => {
  const { env, sql } = stripeEnv();
  await seedAccount(sql, "u1");

  const periodEndSec = Math.floor(Date.now() / 1000) + 30 * 24 * 3600;
  const body = JSON.stringify(subEvent({ id: "evt_grant" }, { current_period_end: periodEndSec }));
  const sig = await stripeSign(body, SECRET, Math.floor(Date.now() / 1000));

  const first = await postWebhook(env, body, sig);
  expect(first.status).toBe(200);
  expect((await first.json()) as unknown).toEqual({ received: true, applied: true });
  expect((await getAccount(sql, "u1"))?.pro_until).toBe(periodEndSec * 1000);

  // Replay the exact same event → idempotent (recorded once), entitlement unchanged.
  const replay = await postWebhook(env, body, await stripeSign(body, SECRET, Math.floor(Date.now() / 1000)));
  expect(replay.status).toBe(200);
  expect((await replay.json()) as unknown).toEqual({ received: true, applied: false });
  expect((await getAccount(sql, "u1"))?.pro_until).toBe(periodEndSec * 1000);
});

test("e2e: a forged (bad-signature) event is rejected 400 and grants nothing", async () => {
  const { env, sql } = stripeEnv();
  await seedAccount(sql, "u1");
  const body = JSON.stringify(subEvent({ id: "evt_forge" }));
  const res = await postWebhook(env, body, "t=123,v1=deadbeef");
  expect(res.status).toBe(400);
  expect((await getAccount(sql, "u1"))?.pro_until).toBeNull();
});

test("e2e: an unconfigured deployment (no secret) fails closed 503", async () => {
  const h = makeEnv(); // no STRIPE_WEBHOOK_SECRET
  const res = await postWebhook(h.env, "{}", "t=1,v1=x");
  expect(res.status).toBe(503);
});

test("e2e: a valid-signed but non-actionable event is acked (200) without applying", async () => {
  const { env } = stripeEnv();
  const body = JSON.stringify({ id: "evt_x", type: "invoice.paid", created: 1, data: { object: {} } });
  const res = await postWebhook(env, body, await stripeSign(body, SECRET, Math.floor(Date.now() / 1000)));
  expect(res.status).toBe(200);
  expect((await res.json()) as { ignored?: string }).toEqual({ received: true, ignored: "invoice.paid" });
});

// --- buy path ----------------------------------------------------------------

test("buildCheckoutForm stamps the account id where the fulfillment webhook reads it", () => {
  const f = buildCheckoutForm({ userId: "u1", email: "a@b.c", priceId: "price_123", successUrl: "https://s", cancelUrl: "https://c" });
  expect(f.get("mode")).toBe("subscription");
  expect(f.get("line_items[0][price]")).toBe("price_123");
  expect(f.get("subscription_data[metadata][capecho_user_id]")).toBe("u1"); // → Subscription.metadata
  expect(f.get("client_reference_id")).toBe("u1");
  expect(f.get("customer_email")).toBe("a@b.c");
});

test("buildCheckoutForm omits customer_email when the account has none", () => {
  const f = buildCheckoutForm({ userId: "u1", email: null, priceId: "p", successUrl: "s", cancelUrl: "c" });
  expect(f.has("customer_email")).toBe(false);
});

test("parseCheckoutUrl extracts the redirect url, else null", () => {
  expect(parseCheckoutUrl({ url: "https://checkout.stripe.com/x" })).toBe("https://checkout.stripe.com/x");
  expect(parseCheckoutUrl({ url: "" })).toBeNull();
  expect(parseCheckoutUrl({})).toBeNull();
  expect(parseCheckoutUrl(null)).toBeNull();
});

// A fake fetch for resolvePriceId: records the URL, returns a canned ok/json.
function fakeFetch(ok: boolean, body: unknown, capture?: (url: string) => void): typeof fetch {
  return (async (url: string | URL | Request) => {
    capture?.(String(url));
    return { ok, json: async () => body } as Response;
  }) as unknown as typeof fetch;
}

test("resolvePriceId: a price_… ref passes through unchanged, no API call", async () => {
  let called = false;
  const r = await resolvePriceId("sk", "price_123", fakeFetch(true, {}, () => (called = true)));
  expect(r).toBe("price_123");
  expect(called).toBe(false); // already a Price id — never hits the network
});

test("resolvePriceId: a lookup_key resolves to its current active Price id", async () => {
  let url = "";
  const r = await resolvePriceId(
    "sk",
    "capecho_pro_monthly",
    fakeFetch(true, { data: [{ id: "price_live" }] }, (u) => (url = u)),
  );
  expect(r).toBe("price_live");
  expect(url).toContain("lookup_keys[]=capecho_pro_monthly");
  expect(url).toContain("active=true");
});

test("resolvePriceId: a lookup_key with no active price, or a non-2xx, is null (caller 503s)", async () => {
  expect(await resolvePriceId("sk", "nope", fakeFetch(true, { data: [] }))).toBeNull();
  expect(await resolvePriceId("sk", "nope", fakeFetch(false, {}))).toBeNull();
});

test("e2e: POST /billing/stripe/checkout needs a session, then a configured price", async () => {
  const h = makeEnv(); // DEV_TRUST_USER_HEADER on; no STRIPE_SECRET_KEY
  const post = (headers: Record<string, string>) =>
    worker.fetch!(
      new Request("https://capecho.test/billing/stripe/checkout", { method: "POST", headers, body: "{}" }),
      h.env,
      ctx,
    );
  expect((await post({ "content-type": "application/json" })).status).toBe(401); // no auth
  expect((await post({ "content-type": "application/json", "x-capecho-user-id": "u1" })).status).toBe(503); // authed, unconfigured
});
