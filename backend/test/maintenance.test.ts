import { test, expect, beforeEach } from "bun:test";
import { freshDb, ids, seedAccount } from "./helpers/db.ts";
import { markAccountDeleted, getAccount } from "../src/accounts.ts";
import { reserveContextQuota } from "../src/quota.ts";
import { runScheduledSweeps, parseRetentionMs, DEFAULT_DELETE_RETENTION_MS } from "../src/maintenance.ts";
import { getOrCreateAccount, issueSession, resolveSession } from "../src/auth.ts";
import { startEmailCode, reserveEmailSend } from "../src/email-otp.ts";
import type { Sql } from "../src/sql.ts";

let sql: Sql;
let newId: () => string;

beforeEach(async () => {
  ({ sql } = freshDb());
  newId = ids("m");
});

const reserve = (userId: string, key: string, now: number, ttlMs: number) =>
  reserveContextQuota(sql, {
    userId,
    wordContextId: null,
    requestFingerprint: `fp-${key}`,
    quotaDay: "2026-05-27",
    idempotencyKey: key,
    dailyCap: 100,
    ttlMs,
    now,
    newId,
  });

const reservationState = async (key: string): Promise<string | undefined> =>
  (await sql.prepare(`SELECT state FROM context_quota_reservations WHERE idempotency_key = ?`).bind(key).first<{ state: string }>())?.state;

test("the default retention window is 30 days", () => {
  expect(DEFAULT_DELETE_RETENTION_MS).toBe(30 * 24 * 60 * 60 * 1000);
});

test("parseRetentionMs is STRICT: only a plain positive integer overrides the safe default [review-fix: Codex+Claude]", () => {
  // anything that would let a malformed var collapse the hard-delete window → safe default
  expect(parseRetentionMs(undefined)).toBe(DEFAULT_DELETE_RETENTION_MS);
  expect(parseRetentionMs("")).toBe(DEFAULT_DELETE_RETENTION_MS);
  expect(parseRetentionMs("abc")).toBe(DEFAULT_DELETE_RETENTION_MS);
  expect(parseRetentionMs("-5")).toBe(DEFAULT_DELETE_RETENTION_MS);
  expect(parseRetentionMs("0")).toBe(DEFAULT_DELETE_RETENTION_MS); // 0 = purge-everything-now → rejected
  expect(parseRetentionMs("30d")).toBe(DEFAULT_DELETE_RETENTION_MS); // parseInt would yield 30 (ms!)
  expect(parseRetentionMs("2.6e9")).toBe(DEFAULT_DELETE_RETENTION_MS); // parseInt would yield 2
  expect(parseRetentionMs("0x10")).toBe(DEFAULT_DELETE_RETENTION_MS); // parseInt would yield 0
  expect(parseRetentionMs("1000ms")).toBe(DEFAULT_DELETE_RETENTION_MS); // parseInt would yield 1000
  // a deliberate plain integer IS honored
  expect(parseRetentionMs("60000")).toBe(60000);
  expect(parseRetentionMs("  86400000  ")).toBe(86_400_000); // trimmed
});

test("runScheduledSweeps purges accounts past the retention window and refunds expired reservations", async () => {
  const RET = 1000;
  await seedAccount(sql, "old");
  await markAccountDeleted(sql, "old", 100); // deleted long ago → past the window
  await seedAccount(sql, "fresh");
  await markAccountDeleted(sql, "fresh", 9_500); // deleted recently → within the window
  await seedAccount(sql, "live"); // never deleted

  await reserve("live", "expired", 100, 10); // expires_at = 110 → stale by sweep time
  await reserve("live", "valid", 9_000, 60_000); // expires_at = 69_000 → still valid

  const now = 10_000; // cutoff = now - RET = 9_000
  const res = await runScheduledSweeps(sql, now, RET);

  expect(res).toEqual({ purgedAccounts: 1, refundedReservations: 1, purgedPreviews: 0, purgedSessions: 0, purgedEmailCodes: 0, purgedEmailSendCounters: 0 });
  expect(await getAccount(sql, "old")).toBeNull(); // hard-deleted (deleted_at 100 <= 9000)
  expect((await getAccount(sql, "fresh"))?.id).toBe("fresh"); // 9500 > 9000 → kept
  expect((await getAccount(sql, "live"))?.id).toBe("live");
  expect(await reservationState("expired")).toBe("refunded"); // TTL lapsed → reclaimed
  expect(await reservationState("valid")).toBe("reserved"); // still within TTL → untouched
});

test("the retention cutoff is inclusive: deleted_at == cutoff is purged, cutoff+1 survives", async () => {
  const RET = 1000;
  await seedAccount(sql, "at-cutoff");
  await markAccountDeleted(sql, "at-cutoff", 9_000); // == cutoff
  await seedAccount(sql, "just-after");
  await markAccountDeleted(sql, "just-after", 9_001); // cutoff + 1

  const res = await runScheduledSweeps(sql, 10_000, RET); // cutoff = 9_000
  expect(res.purgedAccounts).toBe(1);
  expect(await getAccount(sql, "at-cutoff")).toBeNull();
  expect((await getAccount(sql, "just-after"))?.id).toBe("just-after");
});

test("the sweep purges expired sessions but leaves an active one resolvable", async () => {
  const uid = await getOrCreateAccount(sql, { provider: "apple", subject: "s", timezone: "UTC" }, 1000, newId);
  await issueSession(sql, uid, 1000, 5000); // expires at 6000
  const live = await issueSession(sql, uid, 1000, 1_000_000); // long-lived
  const res = await runScheduledSweeps(sql, 10_000, 1000); // now=10_000 → the 6000 session is expired
  expect(res.purgedSessions).toBe(1);
  expect(await resolveSession(sql, live.token, 10_000)).toBe(uid); // active session untouched
});

test("a sweep with nothing to do is a no-op (and is idempotent on re-run)", async () => {
  await seedAccount(sql, "live");
  expect(await runScheduledSweeps(sql, 10_000, 1000)).toEqual({ purgedAccounts: 0, refundedReservations: 0, purgedPreviews: 0, purgedSessions: 0, purgedEmailCodes: 0, purgedEmailSendCounters: 0 });
  // re-running changes nothing
  expect(await runScheduledSweeps(sql, 20_000, 1000)).toEqual({ purgedAccounts: 0, refundedReservations: 0, purgedPreviews: 0, purgedSessions: 0, purgedEmailCodes: 0, purgedEmailSendCounters: 0 });
  expect((await getAccount(sql, "live"))?.id).toBe("live");
});

test("the sweep purges expired email sign-in codes but leaves an unexpired one", async () => {
  // expired code (expires_at 6000) and a still-valid one (expires_at 1_000_000)
  await startEmailCode(sql, { email: "old@x.z", code: "111111", now: 1000, ttlMs: 5000 });
  await startEmailCode(sql, { email: "live@x.z", code: "222222", now: 1000, ttlMs: 1_000_000 });
  const res = await runScheduledSweeps(sql, 10_000, 1000); // now=10_000 → old@x.z is expired
  expect(res.purgedEmailCodes).toBe(1);
  const remaining = await sql.prepare(`SELECT email FROM email_codes`).all<{ email: string }>();
  expect(remaining.map((r) => r.email)).toEqual(["live@x.z"]);
});

test("the sweep purges expired email send-abuse counters", async () => {
  // EMAIL_COUNTER_TTL_MS keeps a counter ~2 days; seed one well in the past so the sweep reclaims it.
  await reserveEmailSend(sql, { ip: "1.2.3.4", dayKey: "2026-05-20", now: 1000 });
  const res = await runScheduledSweeps(sql, 1000 + 3 * 24 * 60 * 60 * 1000, 1000); // 3 days later
  expect(res.purgedEmailSendCounters).toBeGreaterThanOrEqual(1);
  expect((await sql.prepare(`SELECT COUNT(*) AS n FROM email_send_counters`).first<{ n: number }>())?.n).toBe(0);
});
