import { test, expect, beforeEach } from "bun:test";
import { freshDb } from "./helpers/db.ts";
import {
  normalizeEmail,
  isValidEmail,
  generateOtpCode,
  hashCode,
  startEmailCode,
  verifyEmailCode,
  clearEmailCode,
  purgeExpiredEmailCodes,
  reserveEmailSend,
  purgeExpiredEmailSendCounters,
  parseSendCap,
  DEFAULT_CODE_TTL_MS,
  DEFAULT_RESEND_THROTTLE_MS,
  DEFAULT_MAX_ATTEMPTS,
  EMAIL_COUNTER_TTL_MS,
} from "../src/email-otp.ts";
import type { Sql } from "../src/sql.ts";

let sql: Sql;
beforeEach(() => {
  ({ sql } = freshDb());
});

const codeHashOf = (email: string) =>
  sql.prepare(`SELECT code_hash FROM email_codes WHERE email = ?`).bind(email).first<{ code_hash: string }>();
const attemptsOf = async (email: string) =>
  (await sql.prepare(`SELECT attempts FROM email_codes WHERE email = ?`).bind(email).first<{ attempts: number }>())
    ?.attempts;

// --- pure helpers ------------------------------------------------------------

test("normalizeEmail lowercases + trims so casing/whitespace can't fork an identity", () => {
  expect(normalizeEmail("  USER@Example.COM ")).toBe("user@example.com");
});

test("normalizeEmail folds Unicode compatibility forms (NFKC) so one address can't fork into two", () => {
  // U+FF21 FULLWIDTH LATIN CAPITAL A → NFKC "A" → lowercased "a"
  expect(normalizeEmail("Ａbc@x.z")).toBe("abc@x.z");
});

test("isValidEmail accepts a plain address, rejects garbage + over-long", () => {
  expect(isValidEmail("a@b.co")).toBe(true);
  expect(isValidEmail("first.last@sub.example.com")).toBe(true);
  expect(isValidEmail("")).toBe(false);
  expect(isValidEmail("no-at-sign")).toBe(false);
  expect(isValidEmail("a@b")).toBe(false); // no TLD dot
  expect(isValidEmail("a b@c.dz")).toBe(false); // internal space
  expect(isValidEmail(`${"a".repeat(250)}@b.com`)).toBe(false); // > 254
});

test("generateOtpCode is always 6 digits (zero-padded, in range)", () => {
  for (let i = 0; i < 500; i++) {
    const c = generateOtpCode();
    expect(c).toMatch(/^\d{6}$/);
    expect(Number(c)).toBeGreaterThanOrEqual(0);
    expect(Number(c)).toBeLessThan(1_000_000);
  }
});

test("hashCode is deterministic, 64-hex, and salted by the email", async () => {
  expect(await hashCode("a@b.com", "123456")).toBe(await hashCode("a@b.com", "123456"));
  expect(await hashCode("a@b.com", "123456")).toMatch(/^[0-9a-f]{64}$/);
  expect(await hashCode("a@b.com", "123456")).not.toBe(await hashCode("a@b.com", "654321")); // code matters
  expect(await hashCode("a@b.com", "123456")).not.toBe(await hashCode("c@d.com", "123456")); // email salts
});

// --- start -------------------------------------------------------------------

test("startEmailCode stores a HASH (never the raw code) with the expected expiry", async () => {
  const ok = await startEmailCode(sql, { email: "u@x.z", code: "424242", now: 1000 });
  expect(ok).toEqual({ ok: true });
  const row = await sql
    .prepare(`SELECT code_hash, created_at, expires_at, attempts FROM email_codes WHERE email = ?`)
    .bind("u@x.z")
    .first<{ code_hash: string; created_at: number; expires_at: number; attempts: number }>();
  expect(row?.code_hash).toBe(await hashCode("u@x.z", "424242"));
  expect(row?.code_hash).not.toBe("424242"); // raw code is not stored
  expect(row?.created_at).toBe(1000);
  expect(row?.expires_at).toBe(1000 + DEFAULT_CODE_TTL_MS);
  expect(row?.attempts).toBe(0);
});

test("a new start REPLACES the prior code and resets attempts (one active code per email)", async () => {
  await startEmailCode(sql, { email: "u@x.z", code: "111111", now: 1000 });
  // burn an attempt against the first code
  await verifyEmailCode(sql, { email: "u@x.z", code: "000000", now: 2000 });
  expect(await attemptsOf("u@x.z")).toBe(1);
  // a fresh start past the throttle window swaps the hash + zeroes attempts
  await startEmailCode(sql, { email: "u@x.z", code: "222222", now: 1000 + DEFAULT_RESEND_THROTTLE_MS });
  expect((await codeHashOf("u@x.z"))?.code_hash).toBe(await hashCode("u@x.z", "222222"));
  expect(await attemptsOf("u@x.z")).toBe(0);
  // the OLD code no longer verifies; the NEW one does
  expect((await verifyEmailCode(sql, { email: "u@x.z", code: "111111", now: 99_999 })).ok).toBe(false);
});

test("resend throttle: a second start within the window is refused without touching the row", async () => {
  await startEmailCode(sql, { email: "u@x.z", code: "111111", now: 1000 });
  const tooSoon = await startEmailCode(sql, { email: "u@x.z", code: "222222", now: 1000 + DEFAULT_RESEND_THROTTLE_MS - 1 });
  expect(tooSoon).toEqual({ ok: false, reason: "throttled" });
  // unchanged — still the first code
  expect((await codeHashOf("u@x.z"))?.code_hash).toBe(await hashCode("u@x.z", "111111"));
  // exactly at the window boundary it is allowed again
  const atBoundary = await startEmailCode(sql, { email: "u@x.z", code: "222222", now: 1000 + DEFAULT_RESEND_THROTTLE_MS });
  expect(atBoundary).toEqual({ ok: true });
});

// --- verify ------------------------------------------------------------------

test("verify with no pending code → no_code", async () => {
  expect(await verifyEmailCode(sql, { email: "u@x.z", code: "123456", now: 1 })).toEqual({
    ok: false,
    reason: "no_code",
  });
});

test("the correct code verifies once, then is consumed (single-use, no replay)", async () => {
  await startEmailCode(sql, { email: "u@x.z", code: "314159", now: 1000 });
  expect(await verifyEmailCode(sql, { email: "u@x.z", code: "314159", now: 2000 })).toEqual({ ok: true });
  // consumed — the same code can't be replayed
  expect(await verifyEmailCode(sql, { email: "u@x.z", code: "314159", now: 2001 })).toEqual({
    ok: false,
    reason: "no_code",
  });
});

test("a wrong code increments attempts; the cap burns the code (too_many_attempts)", async () => {
  await startEmailCode(sql, { email: "u@x.z", code: "314159", now: 1000 });
  for (let i = 1; i <= DEFAULT_MAX_ATTEMPTS; i++) {
    expect(await verifyEmailCode(sql, { email: "u@x.z", code: "000000", now: 2000 })).toEqual({
      ok: false,
      reason: "mismatch",
    });
    expect(await attemptsOf("u@x.z")).toBe(i);
  }
  // cap reached: the next verify (even with the RIGHT code) is rejected + the code is burned
  expect(await verifyEmailCode(sql, { email: "u@x.z", code: "314159", now: 2000 })).toEqual({
    ok: false,
    reason: "too_many_attempts",
  });
  expect(await codeHashOf("u@x.z")).toBeNull(); // burned — a new code is required
});

test("an expired code is rejected and deleted on sight", async () => {
  await startEmailCode(sql, { email: "u@x.z", code: "314159", now: 1000, ttlMs: 5000 }); // expires 6000
  expect(await verifyEmailCode(sql, { email: "u@x.z", code: "314159", now: 5999 })).toEqual({ ok: true });
  // fresh code, now let it expire
  await startEmailCode(sql, { email: "u@x.z", code: "271828", now: 10_000, ttlMs: 5000 }); // expires 15_000
  expect(await verifyEmailCode(sql, { email: "u@x.z", code: "271828", now: 15_000 })).toEqual({
    ok: false,
    reason: "expired",
  });
  expect(await codeHashOf("u@x.z")).toBeNull();
});

// --- housekeeping ------------------------------------------------------------

test("clearEmailCode removes the active code", async () => {
  await startEmailCode(sql, { email: "u@x.z", code: "111111", now: 1000 });
  await clearEmailCode(sql, "u@x.z");
  expect(await codeHashOf("u@x.z")).toBeNull();
});

test("purgeExpiredEmailCodes deletes only expired rows", async () => {
  await startEmailCode(sql, { email: "old@x.z", code: "111111", now: 1000, ttlMs: 5000 }); // expires 6000
  await startEmailCode(sql, { email: "live@x.z", code: "222222", now: 1000, ttlMs: 1_000_000 });
  expect(await purgeExpiredEmailCodes(sql, 10_000)).toBe(1);
  expect(await codeHashOf("old@x.z")).toBeNull();
  expect((await codeHashOf("live@x.z"))?.code_hash).toBeTruthy();
});

// --- send abuse control ------------------------------------------------------

const globalCount = (day: string) =>
  sql.prepare(`SELECT count FROM email_send_counters WHERE bucket = ?`).bind(`global:${day}`).first<{ count: number }>();

test("reserveEmailSend caps sends per IP per day", async () => {
  const day = "2026-05-30";
  expect(await reserveEmailSend(sql, { ip: "9.9.9.9", dayKey: day, now: 1, perIpCap: 1, globalCap: 100 })).toEqual({ ok: true });
  expect(await reserveEmailSend(sql, { ip: "9.9.9.9", dayKey: day, now: 1, perIpCap: 1, globalCap: 100 })).toEqual({
    ok: false,
    reason: "ip_capped",
  });
});

test("reserveEmailSend checks per-IP BEFORE global, so an IP-capped flood doesn't burn global budget", async () => {
  const day = "2026-05-30";
  await reserveEmailSend(sql, { ip: "9.9.9.9", dayKey: day, now: 1, perIpCap: 1, globalCap: 100 }); // ok → global=1
  await reserveEmailSend(sql, { ip: "9.9.9.9", dayKey: day, now: 1, perIpCap: 1, globalCap: 100 }); // ip_capped
  expect((await globalCount(day))?.count).toBe(1); // the rejected 2nd send did NOT bump global
});

test("reserveEmailSend fails closed once the GLOBAL daily cap is exceeded (across distinct IPs)", async () => {
  const day = "2026-05-30";
  expect(await reserveEmailSend(sql, { ip: "a", dayKey: day, now: 1, globalCap: 2, perIpCap: 100 })).toEqual({ ok: true });
  expect(await reserveEmailSend(sql, { ip: "b", dayKey: day, now: 1, globalCap: 2, perIpCap: 100 })).toEqual({ ok: true });
  expect(await reserveEmailSend(sql, { ip: "c", dayKey: day, now: 1, globalCap: 2, perIpCap: 100 })).toEqual({
    ok: false,
    reason: "global_capped",
  });
});

test("reserveEmailSend with no IP (local/dev) applies only the global cap; no per-IP bucket is created", async () => {
  const day = "2026-05-30";
  expect(await reserveEmailSend(sql, { ip: null, dayKey: day, now: 1, globalCap: 1, perIpCap: 1 })).toEqual({ ok: true });
  expect(await reserveEmailSend(sql, { ip: null, dayKey: day, now: 1, globalCap: 1, perIpCap: 1 })).toEqual({
    ok: false,
    reason: "global_capped",
  });
  const ipRows = await sql.prepare(`SELECT COUNT(*) AS n FROM email_send_counters WHERE bucket LIKE 'ip:%'`).first<{ n: number }>();
  expect(Number(ipRows?.n)).toBe(0);
});

test("the per-day buckets are independent (a new UTC day resets the cap)", async () => {
  expect(await reserveEmailSend(sql, { ip: "a", dayKey: "2026-05-30", now: 1, globalCap: 1, perIpCap: 1 })).toEqual({ ok: true });
  expect(await reserveEmailSend(sql, { ip: "a", dayKey: "2026-05-30", now: 1, globalCap: 1, perIpCap: 1 }).then((r) => r.ok)).toBe(false);
  // next day → fresh bucket → allowed again
  expect(await reserveEmailSend(sql, { ip: "a", dayKey: "2026-05-31", now: 1, globalCap: 1, perIpCap: 1 })).toEqual({ ok: true });
});

test("parseSendCap: a positive int overrides; garbage / zero / negative / undefined → fallback", () => {
  expect(parseSendCap("50", 20)).toBe(50);
  expect(parseSendCap("  100  ", 20)).toBe(100);
  expect(parseSendCap(undefined, 20)).toBe(20);
  expect(parseSendCap("0", 20)).toBe(20);
  expect(parseSendCap("-5", 20)).toBe(20);
  expect(parseSendCap("20.5", 20)).toBe(20);
  expect(parseSendCap("abc", 20)).toBe(20);
});

test("purgeExpiredEmailSendCounters deletes only expired buckets", async () => {
  await reserveEmailSend(sql, { ip: "x", dayKey: "2026-05-30", now: 1000 }); // expires_at = 1000 + TTL
  expect(await purgeExpiredEmailSendCounters(sql, 1000 + EMAIL_COUNTER_TTL_MS + 1)).toBeGreaterThanOrEqual(1);
  expect((await sql.prepare(`SELECT COUNT(*) AS n FROM email_send_counters`).first<{ n: number }>())?.n).toBe(0);
});
