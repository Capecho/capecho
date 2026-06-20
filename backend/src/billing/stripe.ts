import type { SubscriptionStatus, SubscriptionUpdate } from "../entitlement.ts";

// Stripe webhook verification + event → entitlement-update mapping (the macOS-direct / web rail).
// PURE + Web-Crypto only (no Stripe SDK, no deps): a webhook is a signed JSON event; we verify the
// HMAC signature over the RAW body, then map the embedded Subscription object to a SubscriptionUpdate
// that applySubscriptionUpdate (entitlement.ts) applies idempotently + monotonically.
//
// SECURITY: the signature is checked BEFORE any field is trusted (a forged body can't pass), over the
// EXACT raw bytes (so re-serializing the JSON can't change what was signed), with a timestamp-tolerance
// replay window. The fulfillment authority is the verified webhook (+ the reconciliation cron, T6);
// a client never asserts entitlement.

// The events that move entitlement. Other event types are acked + ignored (Stripe sends many).
const RELEVANT_TYPES: ReadonlySet<string> = new Set([
  "customer.subscription.created",
  "customer.subscription.updated",
  "customer.subscription.deleted",
]);

/** Map Stripe's subscription.status → our entitlement status. cancel_at_period_end is carried
 *  SEPARATELY (the won't-renew flag): an active sub set to cancel still grants until current_period_end,
 *  so it stays `active` here and the flag records the intent. Only refund/dispute (handled out of band)
 *  and a true lapse (unpaid/incomplete) remove access. */
export function mapStripeStatus(status: string): SubscriptionStatus {
  switch (status) {
    case "active":
      return "active";
    case "trialing":
      return "trialing";
    case "past_due":
      return "grace_period"; // billing retry — still entitled through current_period_end
    case "canceled":
      return "canceled";
    case "unpaid":
    case "incomplete":
    case "incomplete_expired":
    case "paused":
      return "expired";
    default:
      return "expired"; // unknown status → fail safe to no-access
  }
}

export type StripeMapResult =
  | { kind: "update"; update: Omit<SubscriptionUpdate, "now" | "newId"> }
  | { kind: "ignored"; reason: string } // not an entitlement-moving event (ack, no-op)
  | { kind: "unlinked"; reason: string }; // a relevant sub event with no capecho_user_id (can't attribute)

/**
 * Map a raw Stripe Subscription OBJECT (+ event identity/ordering) to an entitlement update, or
 * classify why it's a no-op. PURE + total. Shared by the webhook (object = event.data.object) and the
 * reconciliation cron (object = the live subscription fetched from the API). The Capecho account is
 * carried in subscription.metadata.capecho_user_id, set on the Checkout Session at buy time. Stripe
 * current_period_end is unix SECONDS → entitlement horizon (ms).
 */
export function mapStripeSubscriptionObject(
  sub: unknown,
  meta: { providerEventId: string; eventTs: number; eventType: string },
): StripeMapResult {
  if (typeof sub !== "object" || sub === null) return { kind: "ignored", reason: "no_object" };
  const s = sub as Record<string, unknown>;
  if (typeof s.id !== "string") return { kind: "ignored", reason: "no_subscription_id" };
  if (typeof s.status !== "string") return { kind: "ignored", reason: "no_status" };

  const metadata = (s.metadata as Record<string, unknown> | undefined) ?? {};
  const userId = metadata.capecho_user_id;
  if (typeof userId !== "string" || userId.length === 0) return { kind: "unlinked", reason: "no_capecho_user_id" };

  const periodEnd = typeof s.current_period_end === "number" ? s.current_period_end * 1000 : null;
  return {
    kind: "update",
    update: {
      provider: "stripe",
      providerEventId: meta.providerEventId,
      providerSubscriptionId: s.id,
      userId,
      status: mapStripeStatus(s.status),
      currentPeriodEnd: periodEnd,
      cancelAtPeriodEnd: s.cancel_at_period_end === true,
      eventTs: meta.eventTs,
      eventType: meta.eventType,
      auditPayload: JSON.stringify({
        stripe_status: s.status,
        current_period_end: s.current_period_end ?? null,
        cancel_at_period_end: s.cancel_at_period_end === true,
      }),
    },
  };
}

/**
 * Map a parsed Stripe webhook event to an entitlement update, or classify why it's a no-op. The event's
 * `id` is the idempotency key and `created` (unix seconds) the monotonic ordering token — second-
 * granularity, so two same-second events for one sub could tie (the 2nd reads as stale); rare, and the
 * reconciliation cron (T6) backstops it.
 */
export function mapStripeEvent(event: unknown): StripeMapResult {
  if (typeof event !== "object" || event === null) return { kind: "ignored", reason: "non_object_event" };
  const e = event as Record<string, unknown>;
  if (typeof e.type !== "string") return { kind: "ignored", reason: "no_type" };
  if (!RELEVANT_TYPES.has(e.type)) return { kind: "ignored", reason: e.type };
  if (typeof e.id !== "string") return { kind: "ignored", reason: "no_event_id" };

  const data = e.data as { object?: unknown } | undefined;
  const created = typeof e.created === "number" ? e.created * 1000 : 0;
  return mapStripeSubscriptionObject(data?.object, { providerEventId: e.id, eventTs: created, eventType: e.type });
}

// --- signature verification (Stripe-Signature: "t=<unix>,v1=<hex>,v1=<hex>,v0=...") --------------

export type SignatureCheck = { ok: true } | { ok: false; reason: string };

async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Constant-time hex string compare (avoids leaking the match prefix via early-exit timing). */
function timingSafeEqualHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/**
 * Verify a Stripe webhook signature over the RAW body. Mirrors Stripe's scheme: signedPayload =
 * `${t}.${rawBody}`, expected = HMAC-SHA256(secret, signedPayload) as hex, compared (constant-time)
 * against any `v1` in the header; the `t` must be within `toleranceMs` of now (replay window).
 */
export async function verifyStripeSignature(
  rawBody: string,
  sigHeader: string | null,
  secret: string,
  nowMs: number,
  toleranceMs = 5 * 60 * 1000,
): Promise<SignatureCheck> {
  if (!sigHeader) return { ok: false, reason: "missing_signature" };
  const parts = sigHeader.split(",").map((p) => p.split("="));
  const t = parts.find(([k]) => k === "t")?.[1];
  const v1s = parts.filter(([k]) => k === "v1").map(([, v]) => v);
  if (!t || v1s.length === 0) return { ok: false, reason: "malformed_signature_header" };
  const ts = Number.parseInt(t, 10);
  if (!Number.isFinite(ts)) return { ok: false, reason: "bad_timestamp" };
  if (Math.abs(nowMs - ts * 1000) > toleranceMs) return { ok: false, reason: "timestamp_out_of_tolerance" };
  const expected = await hmacSha256Hex(secret, `${ts}.${rawBody}`);
  if (!v1s.some((v) => v !== undefined && timingSafeEqualHex(v, expected))) {
    return { ok: false, reason: "no_matching_signature" };
  }
  return { ok: true };
}

// --- buy path: Stripe Checkout Session ---------------------------------------

export interface CheckoutInput {
  userId: string;
  email: string | null;
  priceId: string;
  successUrl: string;
  cancelUrl: string;
}

/**
 * Build the form-encoded body for `POST /v1/checkout/sessions`. PURE + testable. The Capecho account
 * is stamped onto subscription_data.metadata.capecho_user_id — that propagates onto the resulting
 * Subscription's metadata, which is exactly what the fulfillment webhook (mapStripeEvent) reads to
 * attribute the entitlement. client_reference_id + session metadata carry it too for completeness.
 */
export function buildCheckoutForm(input: CheckoutInput): URLSearchParams {
  const f = new URLSearchParams();
  f.set("mode", "subscription");
  f.set("line_items[0][price]", input.priceId);
  f.set("line_items[0][quantity]", "1");
  f.set("success_url", input.successUrl);
  f.set("cancel_url", input.cancelUrl);
  f.set("client_reference_id", input.userId);
  f.set("subscription_data[metadata][capecho_user_id]", input.userId);
  f.set("metadata[capecho_user_id]", input.userId);
  if (input.email) f.set("customer_email", input.email);
  return f;
}

/** Extract the redirect URL from a Checkout Session response. PURE. */
export function parseCheckoutUrl(responseJson: unknown): string | null {
  if (typeof responseJson !== "object" || responseJson === null) return null;
  const url = (responseJson as Record<string, unknown>).url;
  return typeof url === "string" && url.length > 0 ? url : null;
}

export type CheckoutResult = { ok: true; url: string } | { ok: false; status: number; reason: string };

/** Create a Checkout Session via the Stripe API (Bearer secret key, form-encoded). The live network
 *  call — covered by the pure builder/parser tests above + staging verification, not the in-process
 *  harness (same honest limit as the /explain provider fetch). */
export async function createStripeCheckout(secretKey: string, form: URLSearchParams): Promise<CheckoutResult> {
  const res = await fetch("https://api.stripe.com/v1/checkout/sessions", {
    method: "POST",
    headers: {
      authorization: `Bearer ${secretKey}`,
      "content-type": "application/x-www-form-urlencoded",
    },
    body: form.toString(),
  });
  if (!res.ok) return { ok: false, status: res.status, reason: "stripe_api_error" };
  const url = parseCheckoutUrl(await res.json().catch(() => null));
  if (!url) return { ok: false, status: 502, reason: "no_checkout_url" };
  return { ok: true, url };
}

// --- live subscription read / cancel (reconcile T6 + account-deletion T7) --------------------------

const STRIPE_API = "https://api.stripe.com/v1";

/**
 * Resolve a configured price reference to a Stripe **Price id**. A value starting `price_` is used as-is;
 * anything else is treated as a Stripe **lookup_key** (a stable, human-readable alias set on the Price in
 * the dashboard) and resolved to its current ACTIVE Price id. Checkout's `line_items[][price]` accepts
 * only a Price id — never a lookup_key — so this bridges a readable key like `capecho_pro_monthly`. Using
 * a lookup_key also means changing the amount = pointing the key at a new Price in Stripe, no redeploy.
 * Returns null if a lookup_key resolves to no active price (caller fails closed → 503). `fetchImpl` is
 * injected for tests; the live call is covered by staging, like createStripeCheckout.
 */
export async function resolvePriceId(
  secretKey: string,
  ref: string,
  fetchImpl: typeof fetch = fetch,
): Promise<string | null> {
  if (ref.startsWith("price_")) return ref;
  const res = await fetchImpl(
    `${STRIPE_API}/prices?lookup_keys[]=${encodeURIComponent(ref)}&active=true&limit=1`,
    { headers: { authorization: `Bearer ${secretKey}` } },
  );
  if (!res.ok) return null;
  const body = (await res.json().catch(() => null)) as { data?: Array<{ id?: string }> } | null;
  const id = body?.data?.[0]?.id;
  return typeof id === "string" && id.length > 0 ? id : null;
}

/** Fetch the live Subscription object (the reconciliation source of truth). Returns null on any error
 *  so the cron can count + skip rather than throw. */
export async function fetchStripeSubscription(secretKey: string, subscriptionId: string): Promise<unknown | null> {
  const res = await fetch(`${STRIPE_API}/subscriptions/${encodeURIComponent(subscriptionId)}`, {
    headers: { authorization: `Bearer ${secretKey}` },
  });
  if (!res.ok) return null;
  return res.json().catch(() => null);
}

/** Cancel a subscription IMMEDIATELY (DELETE) — used on account deletion so a Stripe sub can't keep
 *  charging a removed account. Returns whether the cancel succeeded. */
export async function cancelStripeSubscription(secretKey: string, subscriptionId: string): Promise<boolean> {
  const res = await fetch(`${STRIPE_API}/subscriptions/${encodeURIComponent(subscriptionId)}`, {
    method: "DELETE",
    headers: { authorization: `Bearer ${secretKey}` },
  });
  return res.ok;
}
