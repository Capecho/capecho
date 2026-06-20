import { test, expect, beforeEach } from "bun:test";
import { freshDb, ids } from "./helpers/db.ts";
import {
  getOrCreateAccount,
  issueSession,
  resolveSession,
  revokeSession,
  purgeExpiredSessions,
  hashToken,
  generateSessionToken,
  parseSessionTtlMs,
  DEFAULT_SESSION_TTL_MS,
  isValidIanaTimeZone,
} from "../src/auth.ts";
import { getAccount, markAccountDeleted } from "../src/accounts.ts";
import type { Sql } from "../src/sql.ts";

let sql: Sql;
let newId: () => string;

beforeEach(() => {
  ({ sql } = freshDb());
  newId = ids("acc");
});

// --- accounts ----------------------------------------------------------------

test("getOrCreateAccount creates an account and is idempotent on (provider, subject)", async () => {
  const a = await getOrCreateAccount(
    sql,
    { provider: "apple", subject: "sub-1", timezone: "America/New_York", learningLanguage: "en" },
    1000,
    newId,
  );
  const b = await getOrCreateAccount(sql, { provider: "apple", subject: "sub-1", timezone: "UTC" }, 2000, newId);
  expect(b).toBe(a); // same account, no duplicate row
  const acct = await getAccount(sql, a);
  expect(acct?.iana_timezone).toBe("America/New_York"); // first-create tz kept, not clobbered on re-login
  expect(acct?.learning_language).toBe("en");
});

test("the same subject under a DIFFERENT provider is a different account", async () => {
  const apple = await getOrCreateAccount(sql, { provider: "apple", subject: "shared", timezone: "UTC" }, 1, newId);
  const google = await getOrCreateAccount(sql, { provider: "google", subject: "shared", timezone: "UTC" }, 1, newId);
  expect(google).not.toBe(apple);
});

test("re-signing in resurrects a soft-deleted account (clears deleted_at)", async () => {
  const id = await getOrCreateAccount(sql, { provider: "apple", subject: "sub-x", timezone: "UTC" }, 1000, newId);
  expect(await markAccountDeleted(sql, id, 5000)).toBe(true);
  expect((await getAccount(sql, id))?.deleted_at).toBe(5000);
  const again = await getOrCreateAccount(sql, { provider: "apple", subject: "sub-x", timezone: "UTC" }, 9000, newId);
  expect(again).toBe(id);
  expect((await getAccount(sql, id))?.deleted_at).toBeNull(); // un-deleted by the explicit re-sign-in
});

// --- tokens ------------------------------------------------------------------

test("session tokens are random + url-safe; hashing is deterministic sha-256 hex", async () => {
  const t1 = generateSessionToken();
  const t2 = generateSessionToken();
  expect(t1).not.toBe(t2);
  expect(t1).toMatch(/^[A-Za-z0-9_-]+$/); // base64url, no padding
  expect(await hashToken(t1)).toBe(await hashToken(t1));
  expect(await hashToken(t1)).not.toBe(await hashToken(t2));
  expect(await hashToken(t1)).toMatch(/^[0-9a-f]{64}$/);
});

// --- sessions ----------------------------------------------------------------

function account(subject = "s"): Promise<string> {
  return getOrCreateAccount(sql, { provider: "apple", subject, timezone: "UTC" }, 1000, newId);
}

test("issue → resolve returns the user; the RAW token is never stored (only its hash)", async () => {
  const uid = await account();
  const { token, expiresAt } = await issueSession(sql, uid, 1000, 10_000);
  expect(expiresAt).toBe(11_000);
  expect(await resolveSession(sql, token, 2000)).toBe(uid);
  const row = await sql.prepare(`SELECT token_hash FROM sessions`).first<{ token_hash: string }>();
  expect(row?.token_hash).toBe(await hashToken(token));
  expect(row?.token_hash).not.toBe(token); // the raw bearer token is not in the DB
});

test("an expired session does not resolve", async () => {
  const uid = await account();
  const { token } = await issueSession(sql, uid, 1000, 10_000); // expires at 11_000
  expect(await resolveSession(sql, token, 10_999)).toBe(uid);
  expect(await resolveSession(sql, token, 11_001)).toBeNull();
});

test("a revoked session does not resolve (sign-out); revoke is idempotent", async () => {
  const uid = await account();
  const { token } = await issueSession(sql, uid, 1000, 10_000);
  expect(await revokeSession(sql, token, 2000)).toBe(true);
  expect(await resolveSession(sql, token, 3000)).toBeNull();
  expect(await revokeSession(sql, token, 4000)).toBe(false); // already revoked
});

test("an unknown / empty token never resolves", async () => {
  await account();
  expect(await resolveSession(sql, "nope", 1)).toBeNull();
  expect(await resolveSession(sql, "", 1)).toBeNull();
});

test("a soft-deleted account's live session goes inert", async () => {
  const uid = await account();
  const { token } = await issueSession(sql, uid, 1000, 1_000_000);
  expect(await resolveSession(sql, token, 2000)).toBe(uid);
  await markAccountDeleted(sql, uid, 3000);
  expect(await resolveSession(sql, token, 4000)).toBeNull(); // pending-hard-delete ⇒ no auth
});

test("purgeExpiredSessions removes expired + revoked, keeps the active one", async () => {
  const uid = await account();
  const active = await issueSession(sql, uid, 1000, 1_000_000);
  await issueSession(sql, uid, 1000, 5000); // expires 6000
  const revoked = await issueSession(sql, uid, 1000, 1_000_000);
  await revokeSession(sql, revoked.token, 2000);
  expect(await purgeExpiredSessions(sql, 7000)).toBe(2); // expired + revoked
  expect(await resolveSession(sql, active.token, 8000)).toBe(uid);
});

test("hard-deleting the account cascades to its sessions", async () => {
  const uid = await account();
  await issueSession(sql, uid, 1000, 1_000_000);
  await sql.prepare(`DELETE FROM accounts WHERE id = ?`).bind(uid).run();
  const n = await sql.prepare(`SELECT COUNT(*) AS n FROM sessions`).first<{ n: number }>();
  expect(Number(n?.n)).toBe(0);
});

// --- helpers -----------------------------------------------------------------

test("parseSessionTtlMs: a plain positive int wins; garbage / zero → default", () => {
  expect(parseSessionTtlMs("5000")).toBe(5000);
  expect(parseSessionTtlMs(undefined)).toBe(DEFAULT_SESSION_TTL_MS);
  expect(parseSessionTtlMs("0")).toBe(DEFAULT_SESSION_TTL_MS);
  expect(parseSessionTtlMs("90d")).toBe(DEFAULT_SESSION_TTL_MS);
});

test("isValidIanaTimeZone accepts real zones, rejects garbage", () => {
  expect(isValidIanaTimeZone("America/New_York")).toBe(true);
  expect(isValidIanaTimeZone("UTC")).toBe(true);
  expect(isValidIanaTimeZone("Not/AZone")).toBe(false);
  expect(isValidIanaTimeZone("")).toBe(false);
});
