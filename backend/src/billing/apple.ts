import type { SubscriptionStatus, SubscriptionUpdate } from "../entitlement.ts";
import { applySubscriptionUpdate, getSubscriptionByProviderId } from "../entitlement.ts";
import type { Sql } from "../sql.ts";

// Apple IAP rail (iOS + macOS Mac App Store build). API-AUTHORITY design, Web-Crypto
// only — NO node:crypto X509Certificate, NO cert-chain parsing, NO new deps. A notification / StoreKit2
// transaction is an UNTRUSTED trigger: we decode it to read originalTransactionId, then refetch the
// authoritative subscription state from the App Store Server API (getAllSubscriptionStatuses) over TLS,
// authenticating with an ES256 JWT signed by our .p8 key. Apple's response is the truth; the
// appAccountToken in it (a UUID = the Capecho account id, set client-side at purchase) is the linkage.
//
// SECURITY: trust anchor = TLS to api.storekit.itunes.apple.com + our JWT. A forged notification is
// useless — we ignore its body and re-fetch by transactionId; attribution comes from the authoritative
// response's appAccountToken, never the inbound payload. (Why this beats local x5c verification on
// Workers: X509Certificate is unreliable there and chain-validation is risky to hand-roll.)

export type AppleEnvironment = "Production" | "Sandbox";

// --- base64url (local; the auth-verifier helpers are unexported + decode-only) ----------------------

function b64urlFromBytes(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlFromString(s: string): string {
  return b64urlFromBytes(new TextEncoder().encode(s));
}
function bytesFromB64url(s: string): Uint8Array {
  const pad = "=".repeat((4 - (s.length % 4)) % 4);
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + pad;
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}
function pemToDer(pem: string): Uint8Array {
  const b64 = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

// --- ES256 JWT for App Store Server API auth -------------------------------------------------------

export interface AppleApiConfig {
  /** the .p8 EC P-256 private key (PKCS#8 PEM) — a SECRET */
  privateKeyP8: string;
  keyId: string; // the .p8's Key ID
  issuerId: string; // App Store Connect Issuer ID
  bundleId: string; // the app's bundle id (the JWT `bid` claim)
}

/** Import the .p8 (PKCS#8 PEM, EC P-256) as an ES256 signing key. */
export async function importApplePrivateKey(p8Pem: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "pkcs8",
    pemToDer(p8Pem) as BufferSource,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

/**
 * Sign an App Store Server API bearer JWT (ES256). Apple requires aud "appstoreconnect-v1", the Issuer
 * ID as iss, the Key ID as the header kid, a short expiry (≤ 60 min — we use 20), and the bundle id as
 * the `bid` claim. crypto.subtle's ECDSA signature is raw r‖s, which is exactly the JWS ES256 encoding.
 */
export async function signAppStoreApiJwt(
  key: CryptoKey,
  cfg: { keyId: string; issuerId: string; bundleId: string },
  nowMs: number,
  ttlMs = 20 * 60 * 1000,
): Promise<string> {
  const header = { alg: "ES256", kid: cfg.keyId, typ: "JWT" };
  const payload = {
    iss: cfg.issuerId,
    iat: Math.floor(nowMs / 1000),
    exp: Math.floor((nowMs + ttlMs) / 1000),
    aud: "appstoreconnect-v1",
    bid: cfg.bundleId,
  };
  const signingInput = `${b64urlFromString(JSON.stringify(header))}.${b64urlFromString(JSON.stringify(payload))}`;
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${b64urlFromBytes(new Uint8Array(sig))}`;
}

// --- untrusted JWS payload decode ------------------------------------------------------------------

/** Decode (NOT verify) a JWS compact serialization's payload to JSON. Trust comes from the App Store
 *  Server API's TLS, not this — so a forged inbound JWS only yields a lookup key we then re-fetch. */
export function decodeJwsPayload<T = unknown>(jws: string): T | null {
  const parts = jws.split(".");
  if (parts.length !== 3 || !parts[1]) return null;
  try {
    return JSON.parse(new TextDecoder().decode(bytesFromB64url(parts[1]))) as T;
  } catch {
    return null;
  }
}

// --- Apple decoded shapes (the fields we read) -----------------------------------------------------

export interface AppleNotificationPayload {
  notificationType?: string;
  subtype?: string;
  notificationUUID?: string;
  data?: {
    environment?: AppleEnvironment;
    bundleId?: string;
    signedTransactionInfo?: string;
    signedRenewalInfo?: string;
  };
  signedDate?: number;
}

export interface AppleTransactionInfo {
  originalTransactionId?: string;
  transactionId?: string;
  appAccountToken?: string;
  expiresDate?: number; // ms
  revocationDate?: number; // ms — present ⇒ refunded/revoked (access pulled)
  revocationReason?: number;
  productId?: string;
  type?: string;
  environment?: AppleEnvironment;
  signedDate?: number; // ms — when Apple signed this state; the monotonic ordering token
}

/** getAllSubscriptionStatuses response (the slice we use). Each subscription group lists its last
 *  transaction per originalTransactionId, with the signed (JWS) transaction info + a status code. */
export interface AppleStatusResponse {
  environment?: AppleEnvironment;
  data?: Array<{
    lastTransactions?: Array<{
      originalTransactionId?: string;
      status?: number; // 1 active, 2 expired, 3 billing-retry, 4 grace, 5 revoked
      signedTransactionInfo?: string;
      signedRenewalInfo?: string;
    }>;
  }>;
}

/** Apple auto-renewable subscription status code → our entitlement status. */
export function mapAppleStatus(status: number): SubscriptionStatus {
  switch (status) {
    case 1:
      return "active";
    case 4:
      return "grace_period"; // billing grace — access retained through expiresDate
    case 5:
      return "revoked";
    case 2: // expired
    case 3: // billing retry — expired, no grace, no access
    default:
      return "expired";
  }
}

export interface AppleEntitlement {
  /** the Capecho account id (the transaction's appAccountToken) */
  userId: string;
  originalTransactionId: string;
  status: SubscriptionStatus;
  currentPeriodEnd: number | null;
  environment: AppleEnvironment;
  /** the authoritative ordering token (the transaction's signedDate, ms) for the monotonic guard */
  signedDate: number;
}

/**
 * Map an authoritative getAllSubscriptionStatuses response (+ the originalTransactionId we looked up)
 * to an entitlement, or null if it can't be attributed. PURE. A present revocationDate (refund/revoke)
 * overrides the status code → access removed; otherwise the status code maps and expiresDate is the
 * horizon. The appAccountToken (set at purchase = the Capecho account) is the user linkage.
 *
 * `ownerOverride` (the JWS-verified /verify TRANSFER path only) forces `userId` to the signed-in account
 * regardless of the baked appAccountToken — so an Apple ID's active sub can move to whoever just proved
 * (via a genuine, signature-verified transaction) they completed it. It ALSO admits a transaction with no
 * appAccountToken at all (a sub bought before we set tokens), which would otherwise be unattributable.
 */
export function entitlementFromStatusResponse(
  resp: AppleStatusResponse,
  originalTransactionId: string,
  ownerOverride?: string,
): AppleEntitlement | null {
  const txns = (resp.data ?? []).flatMap((g) => g.lastTransactions ?? []);
  // Attribute ONLY to the exact subscription we looked up. No `?? txns[0]` fallback: the status endpoint
  // returns every sub the owning Apple ID holds, and a different one can carry a different appAccountToken
  // (a 2nd Capecho account / family share) — picking it would attribute the trigger to the wrong account.
  // If the looked-up id isn't present, it's unattributable (the caller acks + logs).
  const match = txns.find((t) => t.originalTransactionId === originalTransactionId);
  if (!match || typeof match.signedTransactionInfo !== "string") return null;

  const info = decodeJwsPayload<AppleTransactionInfo>(match.signedTransactionInfo);
  if (!info) return null;
  const token = info.appAccountToken;
  const userId =
    typeof ownerOverride === "string" && ownerOverride.length > 0
      ? ownerOverride
      : typeof token === "string" && token.length > 0
        ? token
        : null;
  if (!userId) return null; // unlinked + no override — can't attribute

  const orig = info.originalTransactionId ?? originalTransactionId;
  const environment = info.environment ?? resp.environment ?? "Production";
  const revoked = typeof info.revocationDate === "number";
  const status: SubscriptionStatus = revoked
    ? "revoked"
    : typeof match.status === "number"
      ? mapAppleStatus(match.status)
      : "expired";
  const currentPeriodEnd = typeof info.expiresDate === "number" ? info.expiresDate : null;
  const signedDate = typeof info.signedDate === "number" ? info.signedDate : 0;

  return { userId, originalTransactionId: orig, status, currentPeriodEnd, environment, signedDate };
}

/** Does this authoritative entitlement currently GRANT Pro? (Mirrors the horizon rule in
 *  recomputeProUntil: a future period_end and a non-revoked/refunded/expired status.) The transfer path
 *  only re-assigns a LIVE subscription — never a dead one, which would just strip the old owner for nothing. */
export function appleEntitlementGrants(ent: AppleEntitlement, now: number): boolean {
  return (
    ent.currentPeriodEnd !== null &&
    ent.currentPeriodEnd > now &&
    ent.status !== "revoked" &&
    ent.status !== "refunded" &&
    ent.status !== "expired"
  );
}

/** Convert an AppleEntitlement (authoritative) into a SubscriptionUpdate for applySubscriptionUpdate.
 *  provider="apple", providerSubscriptionId = originalTransactionId, eventTs = the authoritative
 *  signedDate (so the monotonic guard orders by Apple's truth, not the untrusted trigger). */
export function appleEntitlementToUpdate(
  ent: AppleEntitlement,
  meta: { providerEventId: string; eventType: string },
): Omit<SubscriptionUpdate, "now" | "newId"> {
  return {
    provider: "apple",
    providerEventId: meta.providerEventId,
    providerSubscriptionId: ent.originalTransactionId,
    userId: ent.userId,
    status: ent.status,
    currentPeriodEnd: ent.currentPeriodEnd,
    cancelAtPeriodEnd: false, // Apple carries auto-renew intent in renewalInfo; not modeled at MVP
    eventTs: ent.signedDate,
    eventType: meta.eventType,
    auditPayload: JSON.stringify({ environment: ent.environment, status: ent.status }),
  };
}

// --- App Store Server API client (the network seam; injectable for tests) --------------------------

const PROD_BASE = "https://api.storekit.itunes.apple.com";
const SANDBOX_BASE = "https://api.storekit-sandbox.itunes.apple.com";

export interface AppleApiClient {
  /** GET /inApps/v1/subscriptions/{originalTransactionId} — authoritative status, env-routed. */
  getSubscriptionStatuses(
    originalTransactionId: string,
    environment: AppleEnvironment,
  ): Promise<AppleStatusResponse | null>;
}

export interface AppleEnvConfig {
  APPLE_IAP_PRIVATE_KEY?: string; // .p8 PEM (secret)
  APPLE_IAP_KEY_ID?: string;
  APPLE_IAP_ISSUER_ID?: string;
  APPLE_IAP_BUNDLE_ID?: string;
  APPLE_ENVIRONMENT?: string; // "Production" (default) | "Sandbox" — which env this deployment honors
}

/** Read the Apple billing config from env, or null if any required piece is missing (⇒ rail 503s). */
export function appleConfigFromEnv(env: AppleEnvConfig): AppleApiConfig | null {
  const key = env.APPLE_IAP_PRIVATE_KEY;
  const keyId = env.APPLE_IAP_KEY_ID;
  const issuerId = env.APPLE_IAP_ISSUER_ID;
  const bundleId = env.APPLE_IAP_BUNDLE_ID;
  if (!key || !keyId || !issuerId || !bundleId) return null;
  return { privateKeyP8: key, keyId, issuerId, bundleId };
}

/** The environment this deployment honors. A trigger from the other environment is ignored, so a
 *  sandbox notification can't grant production Pro. Default Production (a prod deployment ignores sandbox). */
export function appleExpectedEnvironment(env: AppleEnvConfig): AppleEnvironment {
  return env.APPLE_ENVIRONMENT === "Sandbox" ? "Sandbox" : "Production";
}

/** The real client: signs an ES256 JWT with the .p8 key and calls Apple, routing by environment. The
 *  live fetch — covered by the pure mapping tests + staging, not the in-process harness. */
export function makeAppleApiClient(cfg: AppleApiConfig): AppleApiClient {
  return {
    async getSubscriptionStatuses(originalTransactionId, environment) {
      const base = environment === "Sandbox" ? SANDBOX_BASE : PROD_BASE;
      const key = await importApplePrivateKey(cfg.privateKeyP8);
      const jwt = await signAppStoreApiJwt(key, cfg, Date.now());
      const res = await fetch(`${base}/inApps/v1/subscriptions/${encodeURIComponent(originalTransactionId)}`, {
        headers: { authorization: `Bearer ${jwt}` },
      });
      if (!res.ok) return null;
      return (await res.json().catch(() => null)) as AppleStatusResponse | null;
    },
  };
}

// --- orchestration: trigger → authoritative refetch → entitlement apply ----------------------------

export interface ReconcileInput {
  originalTransactionId: string;
  /** environment the trigger arrived in (from the decoded notification / transaction) */
  environment: AppleEnvironment;
  /** the environment this deployment honors — a mismatch is ignored (sandbox must not mutate prod) */
  expectedEnvironment: AppleEnvironment;
  providerEventId: string; // notificationUUID, or a synthesized id for the client verify path
  eventType: string; // notificationType, or "verify" (the monotonic ordering token is the authoritative signedDate)
  now: number;
  newId: () => string;
  /**
   * The signed-in account to TRANSFER an active subscription to, when the authoritative state shows it
   * entitling. Set ONLY by the /verify handler AFTER the posted transaction's JWS signature is verified
   * (apple-jws.ts) — never on the server-to-server notification path (no caller, no transfer). When unset,
   * attribution is strict: the sub goes to its baked appAccountToken and a foreign owner is rejected.
   */
  transferToUserId?: string;
}

export type ReconcileResult =
  // `attributedUserId` = the account the sub was applied to (always its appAccountToken's account — there is
  // no re-attribution off the ot). The verify handler compares it to the session to flag a cross-account.
  | { status: "applied"; proUntil: number | null; attributedUserId: string }
  | { status: "noop"; reason: "duplicate" | "stale"; proUntil?: number | null; attributedUserId: string } // benign — ack
  | { status: "ignored"; reason: "wrong_environment" } // ack (e.g. a sandbox notification on a prod box)
  | { status: "unattributable"; reason: "unlinked" | "account_mismatch" | "account_missing" } // ack + log
  | { status: "unavailable" }; // the App Store Server API returned nothing — caller should let Apple retry

/**
 * The API-authority flow: refetch the authoritative subscription status from Apple for the trigger's
 * originalTransactionId, map it, and apply it to entitlement. The inbound trigger is NEVER trusted for
 * content — only for the lookup key. `expectedEnvironment` gates sandbox-vs-prod so a sandbox event
 * can't grant production Pro.
 */
export async function reconcileAppleSubscription(
  sql: Sql,
  client: AppleApiClient,
  input: ReconcileInput,
): Promise<ReconcileResult> {
  if (input.environment !== input.expectedEnvironment) return { status: "ignored", reason: "wrong_environment" };

  const resp = await client.getSubscriptionStatuses(input.originalTransactionId, input.environment);
  if (!resp) return { status: "unavailable" };

  // Strict attribution (by the baked appAccountToken) is the default and the only behavior for the
  // notification path. On the JWS-verified /verify path, if the authoritative sub is currently entitling,
  // re-derive it OWNED BY THE CALLER and apply with transfer — moving an Apple ID's active subscription to
  // the signed-in account (Guideline 2.1(a)). A dead/expired sub is left to strict handling (no pointless
  // ownership churn), and a failed/absent verify never reaches here with transferToUserId set.
  let ent = entitlementFromStatusResponse(resp, input.originalTransactionId);
  let allowTransfer = false;
  if (input.transferToUserId) {
    const claimed = entitlementFromStatusResponse(resp, input.originalTransactionId, input.transferToUserId);
    if (claimed && appleEntitlementGrants(claimed, input.now)) {
      ent = claimed;
      allowTransfer = true;
    }
  }

  // Post-transfer attribution: a subscription's appAccountToken is immutable, so once a sub has been
  // transferred (its row reassigned to a new owner), every later authoritative event — a renewal, a
  // REFUND/REVOKE clawback, an expiry — still carries the OLD token. Without this, the strict path would
  // resolve the old owner, mismatch the row, and refuse the update, freezing the row forever (a refunded
  // payer would keep Pro; a renewing one would lose it at the stale period end). The existing row's owner
  // is the source of truth for an existing sub: attribute strict updates to it, not the baked token. Never
  // overrides a transfer (the reassign target wins) and never invents an owner for a brand-new sub.
  if (!allowTransfer && ent) {
    const existing = await getSubscriptionByProviderId(sql, "apple", input.originalTransactionId);
    if (existing && existing.user_id !== ent.userId) ent = { ...ent, userId: existing.user_id };
  }

  if (!ent) return { status: "unattributable", reason: "unlinked" };

  const update = appleEntitlementToUpdate(ent, {
    providerEventId: input.providerEventId,
    eventType: input.eventType,
  });
  const out = await applySubscriptionUpdate(sql, { ...update, now: input.now, newId: input.newId, allowTransfer });
  // `attributedUserId` = the account the sub was applied to. On the STRICT path it is the baked
  // appAccountToken, which lets the verify handler flag a GENUINE cross-account (the sub belongs to a
  // different LIVE account than the caller). On the TRANSFER path (`allowTransfer`, JWS-verified) it is the
  // caller — ownership was just re-assigned to them, so it equals the session and is no cross-account.
  // Strict-path safety unchanged: without a verified JWS we never re-attribute off a forgeable
  // originalTransactionId, so a leaked/forged ot can't claim a sub (dual CR P0); an orphaned sub stays
  // `account_missing` → a calm "not active", never a grant.
  if (out.applied) return { status: "applied", proUntil: out.proUntil, attributedUserId: ent.userId };
  if (out.reason === "account_mismatch") return { status: "unattributable", reason: "account_mismatch" };
  if (out.reason === "account_missing") return { status: "unattributable", reason: "account_missing" };
  return {
    status: "noop",
    reason: out.reason,
    proUntil: out.reason === "stale" ? out.proUntil : undefined,
    attributedUserId: ent.userId,
  };
}
