import { test, expect } from "bun:test";
import { accountDayKey, accountDayStartMs, utcDayKey } from "../src/time.ts";

// 2026-05-27T03:00:00Z: still 2026-05-26 in New York (EDT, UTC-4), already
// 2026-05-27 in Shanghai (UTC+8). The per-user quota day MUST follow the account's
// local midnight (T10 IANA day boundary), not UTC.
const instant = Date.parse("2026-05-27T03:00:00Z");

test("account day key follows the account's IANA timezone", () => {
  expect(accountDayKey(instant, "America/New_York")).toBe("2026-05-26");
  expect(accountDayKey(instant, "Asia/Shanghai")).toBe("2026-05-27");
  expect(accountDayKey(instant, "UTC")).toBe("2026-05-27");
});

test("the global budget day key is UTC", () => {
  expect(utcDayKey(instant)).toBe("2026-05-27");
});

test("a DST-spring instant still resolves to a single local day", () => {
  // 2026-03-08 07:30Z is 02:30 EST→EDT transition morning in New York.
  const dst = Date.parse("2026-03-08T07:30:00Z");
  expect(accountDayKey(dst, "America/New_York")).toBe("2026-03-08");
});

test("account day start resolves local midnight to its real UTC instant (per tz)", () => {
  // Same instant as above: 05-26 in New York, 05-27 in Shanghai — the day STARTS differ too.
  expect(accountDayStartMs(instant, "UTC")).toBe(Date.parse("2026-05-27T00:00:00Z"));
  expect(accountDayStartMs(instant, "America/New_York")).toBe(Date.parse("2026-05-26T04:00:00Z")); // EDT (UTC-4)
  expect(accountDayStartMs(instant, "Asia/Shanghai")).toBe(Date.parse("2026-05-26T16:00:00Z")); // CST (UTC+8)
  // Invariant: the start is itself within the same local day as the instant.
  expect(accountDayKey(accountDayStartMs(instant, "America/New_York"), "America/New_York")).toBe(
    accountDayKey(instant, "America/New_York"),
  );
});

test("account day start ignores the sub-second fraction of the query instant [review-fix: Codex P3]", () => {
  // A nowMs carrying milliseconds must still return a clean local midnight — otherwise the
  // first few hundred ms of the day would be excluded from `created_at >= dayStart`.
  const withMs = Date.parse("2026-05-27T03:00:00Z") + 123;
  expect(accountDayStartMs(withMs, "UTC")).toBe(Date.parse("2026-05-27T00:00:00Z"));
  expect(accountDayStartMs(withMs, "Asia/Shanghai")).toBe(Date.parse("2026-05-26T16:00:00Z"));
});

test("account day start is DST-correct across a spring-forward day", () => {
  // 2026-03-08 New York springs forward at 02:00 EST → 03:00 EDT. The local day still
  // begins at 00:00 EST = 05:00Z, for any instant queried within that day (morning or evening).
  const morning = Date.parse("2026-03-08T07:30:00Z"); // inside the transition window
  const evening = Date.parse("2026-03-08T23:00:00Z"); // 18:00 EDT, same local day
  expect(accountDayStartMs(morning, "America/New_York")).toBe(Date.parse("2026-03-08T05:00:00Z"));
  expect(accountDayStartMs(evening, "America/New_York")).toBe(Date.parse("2026-03-08T05:00:00Z"));
});
