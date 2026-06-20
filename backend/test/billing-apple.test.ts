import { test, expect } from "bun:test";
import worker from "../src/index.ts";
import { makeEnv } from "./helpers/worker-env.ts";
import { freshDb, ids, seedAccount } from "./helpers/db.ts";
import { getAccount } from "../src/accounts.ts";
import {
  importApplePrivateKey,
  signAppStoreApiJwt,
  decodeJwsPayload,
  mapAppleStatus,
  entitlementFromStatusResponse,
  reconcileAppleSubscription,
  type AppleApiClient,
  type AppleStatusResponse,
  type AppleEnvironment,
  type AppleTransactionInfo,
} from "../src/billing/apple.ts";
import type { Env } from "../src/index.ts";

const ctx = {} as ExecutionContext;

// --- test helpers ------------------------------------------------------------

function b64url(s: string): string {
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlBytes(s: string): Uint8Array {
  const pad = "=".repeat((4 - (s.length % 4)) % 4);
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
  const a = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) a[i] = bin.charCodeAt(i);
  return a;
}
function b64urlStr(s: string): string {
  return new TextDecoder().decode(b64urlBytes(s));
}
/** A JWS whose payload base64url-decodes to `payload` (a fake signature — decodeJwsPayload doesn't verify). */
function fakeJws(payload: unknown): string {
  return `${b64url(JSON.stringify({ alg: "ES256" }))}.${b64url(JSON.stringify(payload))}.${b64url("sig")}`;
}
function derToPem(der: Uint8Array): string {
  let bin = "";
  for (const b of der) bin += String.fromCharCode(b);
  const lines = btoa(bin).match(/.{1,64}/g)!.join("\n");
  return `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----`;
}
function statusResponse(
  tx: Partial<AppleTransactionInfo>,
  status = 1,
  environment: AppleEnvironment = "Production",
): AppleStatusResponse {
  return {
    environment,
    data: [{ lastTransactions: [{ originalTransactionId: tx.originalTransactionId, status, signedTransactionInfo: fakeJws(tx) }] }],
  };
}
const mockClient = (resp: AppleStatusResponse | null): AppleApiClient => ({
  getSubscriptionStatuses: async () => resp,
});

// --- ES256 JWT signing (App Store Server API auth) ---------------------------

test("signAppStoreApiJwt: a valid ES256 JWT verifiable by the public key, with Apple's required claims", async () => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const key = await importApplePrivateKey(derToPem(pkcs8));

  const jwt = await signAppStoreApiJwt(key, { keyId: "KID", issuerId: "ISS", bundleId: "com.capecho.app" }, 1_000_000);
  const [h, p, sig] = jwt.split(".");
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    pair.publicKey,
    b64urlBytes(sig!) as BufferSource,
    new TextEncoder().encode(`${h}.${p}`),
  );
  expect(ok).toBe(true);

  expect(JSON.parse(b64urlStr(h!))).toEqual({ alg: "ES256", kid: "KID", typ: "JWT" });
  const payload = JSON.parse(b64urlStr(p!));
  expect(payload.iss).toBe("ISS");
  expect(payload.aud).toBe("appstoreconnect-v1");
  expect(payload.bid).toBe("com.capecho.app");
  expect(payload.exp).toBeGreaterThan(payload.iat);
});

// --- pure decode + mapping ---------------------------------------------------

test("decodeJwsPayload: decodes a JWS payload, returns null on malformed input", () => {
  expect(decodeJwsPayload(fakeJws({ a: 1 }))).toEqual({ a: 1 });
  expect(decodeJwsPayload("not-a-jws")).toBeNull();
  expect(decodeJwsPayload("a.b")).toBeNull(); // only 2 parts
});

test("mapAppleStatus: Apple subscription status codes → entitlement statuses", () => {
  expect(mapAppleStatus(1)).toBe("active");
  expect(mapAppleStatus(2)).toBe("expired");
  expect(mapAppleStatus(3)).toBe("expired"); // billing retry — no access
  expect(mapAppleStatus(4)).toBe("grace_period");
  expect(mapAppleStatus(5)).toBe("revoked");
});

test("entitlementFromStatusResponse: maps the authoritative transaction; revocationDate ⇒ revoked; unlinked ⇒ null", () => {
  const ent = entitlementFromStatusResponse(
    statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u1", expiresDate: 9_000_000, signedDate: 1234 }, 1),
    "ot_1",
  );
  expect(ent).toEqual({
    userId: "u1",
    originalTransactionId: "ot_1",
    status: "active",
    currentPeriodEnd: 9_000_000,
    environment: "Production",
    signedDate: 1234,
  });

  const revoked = entitlementFromStatusResponse(
    statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u1", expiresDate: 9_000_000, revocationDate: 5000, signedDate: 2000 }, 1),
    "ot_1",
  );
  expect(revoked?.status).toBe("revoked"); // revocationDate overrides the status code

  const unlinked = entitlementFromStatusResponse(statusResponse({ originalTransactionId: "ot_1", expiresDate: 1 }, 1), "ot_1");
  expect(unlinked).toBeNull(); // no appAccountToken → can't attribute
});

test("entitlementFromStatusResponse: a response missing the looked-up id is unattributable, NOT mis-attributed", () => {
  // The owning Apple ID also holds a DIFFERENT sub (ot_other, owned by u2). We looked up ot_1, which isn't
  // present. Must return null — never fall back to the other transaction and grant the wrong account.
  const r = entitlementFromStatusResponse(
    statusResponse({ originalTransactionId: "ot_other", appAccountToken: "u2", expiresDate: 9_000_000, signedDate: 1 }, 1),
    "ot_1",
  );
  expect(r).toBeNull();
});

// --- reconcile (the API-authority flow), with an injected mock client --------

function recon(
  sql: Parameters<typeof reconcileAppleSubscription>[0],
  client: AppleApiClient,
  over: Partial<Parameters<typeof reconcileAppleSubscription>[2]> = {},
) {
  return reconcileAppleSubscription(sql, client, {
    originalTransactionId: "ot_1",
    environment: "Production",
    expectedEnvironment: "Production",
    providerEventId: "uuid-1",
    eventType: "SUBSCRIBED",
    now: 5000,
    newId: ids("e"),
    ...over,
  });
}

test("reconcile: an authoritative active sub grants Pro to the appAccountToken's account", async () => {
  const { sql } = freshDb();
  await seedAccount(sql, "u1");
  const resp = statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u1", expiresDate: 9_000_000, signedDate: 1000 }, 1);
  const r = await recon(sql, mockClient(resp));
  expect(r.status).toBe("applied");
  expect((await getAccount(sql, "u1"))?.pro_until).toBe(9_000_000);
});

test("reconcile: a sandbox trigger on a production deployment is ignored (sandbox can't mutate prod)", async () => {
  const { sql } = freshDb();
  await seedAccount(sql, "u1");
  const resp = statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u1", expiresDate: 9_000_000, signedDate: 1000 }, 1, "Sandbox");
  const r = await recon(sql, mockClient(resp), { environment: "Sandbox", expectedEnvironment: "Production" });
  expect(r).toEqual({ status: "ignored", reason: "wrong_environment" });
  expect((await getAccount(sql, "u1"))?.pro_until).toBeNull();
});

test("reconcile: a sandbox transaction IS applied when the expected environment is its own (the /billing/apple/verify path)", async () => {
  // The dual of the gate above. The client-verify handler passes expectedEnvironment = the transaction's
  // OWN Apple-signed environment (not the deployment's), because the SAME production binary is tested by
  // App Review in Sandbox and run by real users in Production — a Production deployment MUST unlock Pro
  // for a sandbox verify (Apple always tests IAP in Sandbox) or the app is rejected. Bounded abuse: a
  // sandbox sub's period is minutes, so it auto-expires almost immediately.
  const { sql } = freshDb();
  await seedAccount(sql, "u1");
  const resp = statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u1", expiresDate: 9_000_000, signedDate: 1000 }, 1, "Sandbox");
  const r = await recon(sql, mockClient(resp), { environment: "Sandbox", expectedEnvironment: "Sandbox" });
  expect(r.status).toBe("applied");
  expect((await getAccount(sql, "u1"))?.pro_until).toBe(9_000_000);
});

test("reconcile: idempotent on the notificationUUID (providerEventId)", async () => {
  const { sql } = freshDb();
  await seedAccount(sql, "u1");
  const resp = statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u1", expiresDate: 9_000_000, signedDate: 1000 }, 1);
  expect((await recon(sql, mockClient(resp), { providerEventId: "n1" })).status).toBe("applied");
  expect(await recon(sql, mockClient(resp), { providerEventId: "n1" })).toEqual({ status: "noop", reason: "duplicate", proUntil: undefined, attributedUserId: "u1" });
});

test("reconcile: applied returns attributedUserId = the appAccountToken account (the cross-account signal)", async () => {
  // The verify handler compares this to the session to flag a GENUINE cross-account. The sub is attributed
  // STRICTLY to its baked appAccountToken — there is no re-attribution off a bare originalTransactionId.
  const { sql } = freshDb();
  await seedAccount(sql, "u_owner");
  const resp = statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u_owner", expiresDate: 9_000_000, signedDate: 1000 }, 1);
  const r = await recon(sql, mockClient(resp));
  expect(r.status).toBe("applied");
  if (r.status === "applied") expect(r.attributedUserId).toBe("u_owner");
});

test("reconcile: a sub whose appAccountToken account no longer exists is account_missing, NOT granted", async () => {
  // An orphaned sub (account deleted / DB wiped) must NEVER be re-attributed off a forgeable, unverified
  // originalTransactionId — that would let a leaked ot claim a deleted user's subscription. It
  // stays account_missing; the verify handler then reports a calm "not active", never a grant.
  const { sql } = freshDb();
  await seedAccount(sql, "u_caller"); // a live caller; "gone-acct" is deliberately NOT seeded
  const resp = statusResponse({ originalTransactionId: "ot_1", appAccountToken: "gone-acct", expiresDate: 9_000_000, signedDate: 1000 }, 1);
  const r = await recon(sql, mockClient(resp));
  expect(r).toEqual({ status: "unattributable", reason: "account_missing" });
  expect((await getAccount(sql, "u_caller"))?.pro_until).toBeNull(); // no account is granted Pro
});

test("reconcile: an unlinked transaction is unattributable; a null client response is unavailable", async () => {
  const { sql } = freshDb();
  await seedAccount(sql, "u1");
  const unlinked = statusResponse({ originalTransactionId: "ot_1", expiresDate: 9_000_000, signedDate: 1000 }, 1);
  expect(await recon(sql, mockClient(unlinked))).toEqual({ status: "unattributable", reason: "unlinked" });
  expect(await recon(sql, mockClient(null))).toEqual({ status: "unavailable" });
});

test("reconcile: a revoked transaction claws back access", async () => {
  const { sql } = freshDb();
  await seedAccount(sql, "u1");
  await recon(sql, mockClient(statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u1", expiresDate: 9_000_000, signedDate: 1000 }, 1)), { providerEventId: "n1" });
  expect((await getAccount(sql, "u1"))?.pro_until).toBe(9_000_000);

  const revoked = statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u1", expiresDate: 9_000_000, revocationDate: 6000, signedDate: 2000 }, 1);
  const r = await recon(sql, mockClient(revoked), { providerEventId: "n2" });
  expect(r.status).toBe("applied");
  expect((await getAccount(sql, "u1"))?.pro_until).toBeNull(); // revoked → excluded from the horizon
});

test("reconcile: a foreign appAccountToken for an EXISTING sub attributes to the row owner, never the foreigner (no leak)", async () => {
  // A subscription's appAccountToken is immutable, so two different tokens for one ot should never arrive
  // from Apple — but if one did (forged/garbage), the existing row's owner is the source of truth: the
  // update applies to u1 and u2 gets nothing. (The owner-resolution is also what makes post-transfer
  // clawbacks work — see the transfer tests below.)
  const { sql } = freshDb();
  await seedAccount(sql, "u1");
  await seedAccount(sql, "u2");
  await recon(sql, mockClient(statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u1", expiresDate: 9_000_000, signedDate: 1000 }, 1)), { providerEventId: "n1" });
  const r = await recon(sql, mockClient(statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u2", expiresDate: 9_000_000, signedDate: 2000 }, 1)), { providerEventId: "n2" });
  expect(r.status).toBe("applied");
  if (r.status === "applied") expect(r.attributedUserId).toBe("u1"); // attributed to the row owner, NOT u2
  expect((await getAccount(sql, "u2"))?.pro_until).toBeNull(); // the foreigner gained nothing
  expect((await getAccount(sql, "u1"))?.pro_until).toBe(9_000_000);
});

// --- transfer (the JWS-verified /verify path: transferToUserId set) ----------

test("reconcile transfer: a verified verify moves an active sub from another LIVE account to the caller", async () => {
  // The App Store rejection scenario: u_old subscribed (its appAccountToken) on an earlier account; u_caller
  // is a NEW account on the SAME Apple ID and verifies the same transaction. Ownership + Pro move to u_caller.
  const { sql } = freshDb();
  await seedAccount(sql, "u_old");
  await seedAccount(sql, "u_caller");
  await recon(sql, mockClient(statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u_old", expiresDate: 9_000_000, signedDate: 1000 }, 1)), { providerEventId: "n1" });
  expect((await getAccount(sql, "u_old"))?.pro_until).toBe(9_000_000);

  const r = await recon(sql, mockClient(statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u_old", expiresDate: 9_000_000, signedDate: 2000 }, 1)), { providerEventId: "n2", transferToUserId: "u_caller" });
  expect(r.status).toBe("applied");
  if (r.status === "applied") expect(r.attributedUserId).toBe("u_caller"); // attributed to the caller → no cross-account flag
  expect((await getAccount(sql, "u_caller"))?.pro_until).toBe(9_000_000);
  expect((await getAccount(sql, "u_old"))?.pro_until).toBeNull();
});

test("reconcile transfer: ownership moves even when the authoritative state is identical (stale upsert)", async () => {
  // Same signedDate as the row already holds (u_caller verifies the exact current transaction). The value
  // upsert no-ops, but ownership + Pro must still transfer or the reviewer's new account stays blocked.
  const { sql } = freshDb();
  await seedAccount(sql, "u_old");
  await seedAccount(sql, "u_caller");
  await recon(sql, mockClient(statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u_old", expiresDate: 9_000_000, signedDate: 1000 }, 1)), { providerEventId: "n1" });
  const r = await recon(sql, mockClient(statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u_old", expiresDate: 9_000_000, signedDate: 1000 }, 1)), { providerEventId: "n2", transferToUserId: "u_caller" });
  expect(r.attributedUserId).toBe("u_caller");
  expect((await getAccount(sql, "u_caller"))?.pro_until).toBe(9_000_000);
  expect((await getAccount(sql, "u_old"))?.pro_until).toBeNull();
});

test("reconcile transfer: claims an orphaned (account-gone) active sub for the caller", async () => {
  const { sql } = freshDb();
  await seedAccount(sql, "u_caller"); // the appAccountToken account "gone" is deliberately NOT seeded
  const r = await recon(sql, mockClient(statusResponse({ originalTransactionId: "ot_1", appAccountToken: "gone", expiresDate: 9_000_000, signedDate: 1000 }, 1)), { transferToUserId: "u_caller" });
  expect(r.status).toBe("applied");
  if (r.status === "applied") expect(r.attributedUserId).toBe("u_caller");
  expect((await getAccount(sql, "u_caller"))?.pro_until).toBe(9_000_000);
});

test("reconcile transfer: claims an UNLINKED active sub (no appAccountToken) for the caller", async () => {
  const { sql } = freshDb();
  await seedAccount(sql, "u_caller");
  const r = await recon(sql, mockClient(statusResponse({ originalTransactionId: "ot_1", expiresDate: 9_000_000, signedDate: 1000 }, 1)), { transferToUserId: "u_caller" });
  expect(r.status).toBe("applied");
  expect((await getAccount(sql, "u_caller"))?.pro_until).toBe(9_000_000);
});

test("reconcile transfer: a NON-entitling (expired) sub is NOT transferred — no claim, no grant", async () => {
  // Transfer only re-assigns a LIVE subscription; a dead one falls back to strict attribution (here the
  // appAccountToken account is gone → account_missing → a calm "not active", never a grant).
  const { sql } = freshDb();
  await seedAccount(sql, "u_caller");
  const r = await recon(sql, mockClient(statusResponse({ originalTransactionId: "ot_1", appAccountToken: "gone", expiresDate: 9_000_000, signedDate: 1000 }, 2)), { transferToUserId: "u_caller" });
  expect(r).toEqual({ status: "unattributable", reason: "account_missing" });
  expect((await getAccount(sql, "u_caller"))?.pro_until).toBeNull();
});

test("reconcile transfer: the flag is a harmless no-op when the sub already belongs to the caller", async () => {
  const { sql } = freshDb();
  await seedAccount(sql, "u_caller");
  const r = await recon(sql, mockClient(statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u_caller", expiresDate: 9_000_000, signedDate: 1000 }, 1)), { transferToUserId: "u_caller" });
  expect(r.status).toBe("applied");
  if (r.status === "applied") expect(r.attributedUserId).toBe("u_caller");
  expect((await getAccount(sql, "u_caller"))?.pro_until).toBe(9_000_000);
});

test("reconcile transfer: a later REFUND notification (immutable old token) claws back from the NEW owner", async () => {
  // Frozen-row regression: after a transfer the appAccountToken still names the OLD owner, so the strict
  // notification path must resolve the CURRENT row owner — otherwise the refund would be refused and the
  // transferred owner would keep Pro after the money is returned.
  const { sql } = freshDb();
  await seedAccount(sql, "u_old");
  await seedAccount(sql, "u_caller");
  await recon(sql, mockClient(statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u_old", expiresDate: 9_000_000, signedDate: 1000 }, 1)), { providerEventId: "n1" });
  await recon(sql, mockClient(statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u_old", expiresDate: 9_000_000, signedDate: 2000 }, 1)), { providerEventId: "n2", transferToUserId: "u_caller" });
  expect((await getAccount(sql, "u_caller"))?.pro_until).toBe(9_000_000);

  // REFUND/REVOKE arrives later, still carrying appAccountToken=u_old, strict (no transfer).
  const r = await recon(sql, mockClient(statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u_old", expiresDate: 9_000_000, revocationDate: 3000, signedDate: 3000 }, 1)), { providerEventId: "n3" });
  expect(r.status).toBe("applied");
  if (r.status === "applied") expect(r.attributedUserId).toBe("u_caller");
  expect((await getAccount(sql, "u_caller"))?.pro_until).toBeNull(); // clawed back from the transferred owner
});

test("reconcile transfer: a later RENEWAL notification (immutable old token) extends the NEW owner", async () => {
  const { sql } = freshDb();
  await seedAccount(sql, "u_old");
  await seedAccount(sql, "u_caller");
  await recon(sql, mockClient(statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u_old", expiresDate: 9_000_000, signedDate: 1000 }, 1)), { providerEventId: "n1" });
  await recon(sql, mockClient(statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u_old", expiresDate: 9_000_000, signedDate: 2000 }, 1)), { providerEventId: "n2", transferToUserId: "u_caller" });

  const r = await recon(sql, mockClient(statusResponse({ originalTransactionId: "ot_1", appAccountToken: "u_old", expiresDate: 20_000_000, signedDate: 3000 }, 1)), { providerEventId: "n3" });
  expect(r.status).toBe("applied");
  expect((await getAccount(sql, "u_caller"))?.pro_until).toBe(20_000_000); // renewal extends the new owner
  expect((await getAccount(sql, "u_old"))?.pro_until).toBeNull();
});

// --- handler gating (network path lives in reconcile tests above) ------------

function appleEnv(): Env {
  const h = makeEnv();
  Object.assign(h.env as Record<string, unknown>, {
    APPLE_IAP_PRIVATE_KEY: "x",
    APPLE_IAP_KEY_ID: "k",
    APPLE_IAP_ISSUER_ID: "i",
    APPLE_IAP_BUNDLE_ID: "com.capecho.app",
  });
  return h.env;
}
const post = (env: Env, path: string, body: unknown, headers: Record<string, string> = {}) =>
  worker.fetch!(
    new Request(`https://capecho.test${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", ...headers },
      body: JSON.stringify(body),
    }),
    env,
    ctx,
  );

test("e2e: apple routes fail closed (503) when unconfigured", async () => {
  const { env } = makeEnv(); // no APPLE_IAP_* set
  expect((await post(env, "/billing/apple/notifications", { signedPayload: "x" })).status).toBe(503);
  expect((await post(env, "/billing/apple/verify", { signed_transaction: "x" }, { "x-capecho-user-id": "u1" })).status).toBe(503);
});

test("e2e: a notification with no transaction is acked + ignored; a malformed one is 400", async () => {
  const env = appleEnv();
  const ok = await post(env, "/billing/apple/notifications", {
    signedPayload: fakeJws({ notificationUUID: "u", notificationType: "TEST", data: { environment: "Production" } }),
  });
  expect(ok.status).toBe(200);
  expect((await ok.json()) as unknown).toEqual({ received: true, ignored: "no_transaction" });

  expect((await post(env, "/billing/apple/notifications", { signedPayload: "not-a-jws" })).status).toBe(400);
});

test("e2e: apple verify requires a session, then a well-formed transaction", async () => {
  const env = appleEnv();
  expect((await post(env, "/billing/apple/verify", { signed_transaction: "x" })).status).toBe(401); // no auth
  expect((await post(env, "/billing/apple/verify", { signed_transaction: "not-a-jws" }, { "x-capecho-user-id": "u1" })).status).toBe(400);
});
