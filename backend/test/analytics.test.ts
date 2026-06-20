import { test, expect, beforeEach } from "bun:test";
import { freshDb } from "./helpers/db.ts";
import type { Sql } from "../src/sql.ts";
import { computeAnalyticsReport } from "../src/analytics.ts";
import { ANALYTICS_DASHBOARD_HTML } from "../src/analytics-dashboard.ts";

// First-party retention/engagement readout — math correctness. The founder makes the "form the LLC?"
// and "is there willingness to pay?" calls off these numbers, so the retention/cohort/WTP arithmetic
// is asserted against a hand-computed fixture.

const DAY = 86_400_000;
let sql: Sql;

beforeEach(() => {
  ({ sql } = freshDb());
});

async function acct(id: string, createdAtDay: number, provider = "apple"): Promise<void> {
  await sql
    .prepare(
      `INSERT INTO accounts (id, auth_provider, provider_subject, iana_timezone, explanation_language, created_at)
       VALUES (?, ?, ?, 'UTC', 'en', ?)`,
    )
    .bind(id, provider, `subj-${id}`, createdAtDay * DAY)
    .run();
}

async function word(id: string, userId: string, createdAtDay: number, deleted = false): Promise<void> {
  await sql
    .prepare(
      `INSERT INTO words (id, user_id, target_language, surface_unit, normalized_unit, target_normalization_version, created_at, updated_at, deleted_at)
       VALUES (?, ?, 'en', ?, ?, 'v1', ?, ?, ?)`,
    )
    .bind(id, userId, `s-${id}`, `n-${id}`, createdAtDay * DAY, createdAtDay * DAY, deleted ? createdAtDay * DAY : null)
    .run();
}

async function review(id: string, userId: string, wordId: string, createdAtDay: number, seq: number): Promise<void> {
  await sql
    .prepare(
      `INSERT INTO fsrs_events (id, user_id, word_id, server_seq, rating, client_review_ts, clamped_elapsed, created_at)
       VALUES (?, ?, ?, ?, 3, ?, 0, ?)`,
    )
    .bind(id, userId, wordId, seq, createdAtDay * DAY, createdAtDay * DAY)
    .run();
}

async function session(userId: string, createdAtDay: number): Promise<void> {
  await sql
    .prepare(
      `INSERT INTO sessions (token_hash, user_id, created_at, expires_at, last_seen_at)
       VALUES (?, ?, ?, ?, ?)`,
    )
    .bind(`tok-${userId}-${createdAtDay}`, userId, createdAtDay * DAY, (createdAtDay + 30) * DAY, createdAtDay * DAY)
    .run();
}

async function committed(userId: string, quotaDay: string, n: number): Promise<void> {
  for (let i = 0; i < n; i++) {
    await sql
      .prepare(
        `INSERT INTO context_quota_reservations (id, user_id, request_fingerprint, quota_day, idempotency_key, state, expires_at, created_at, committed_at)
         VALUES (?, ?, ?, ?, ?, 'committed', 1, 1, 1)`,
      )
      .bind(`r-${userId}-${quotaDay}-${i}`, userId, `fp-${userId}-${quotaDay}-${i}`, quotaDay, `idem-${userId}-${quotaDay}-${i}`)
      .run();
  }
}

// Shared fixture: "now" = UTC day 100.
//   A (day100, google) — sign-in day100 only
//   B (day90)          — word day92
//   C (day60)          — word day60 + review day61   + 10 committed context-explanations (one day)
//   D (day60)          — word day60 (never returns)  + 3 committed (one day)  ... wait: B gets the 3
async function seedFixture(): Promise<void> {
  await acct("A", 100, "google");
  await acct("B", 90);
  await acct("C", 60);
  await acct("D", 60);
  await session("A", 100);
  await word("wB", "B", 92);
  await word("wC", "C", 60);
  await review("eC", "C", "wC", 61, 1);
  await word("wD", "D", 60);
  await committed("C", "2026-01-01", 10); // hits the free cap of 10
  await committed("B", "2026-01-02", 3); // below cap
}

test("empty DB → zeros and null rates, no throw", async () => {
  const r = await computeAnalyticsReport(sql, { now: 100 * DAY });
  expect(r.accounts.total).toBe(0);
  expect(r.active).toEqual({ dauUtc: 0, wauUtc: 0, mauUtc: 0 });
  expect(r.retention.every((b) => b.rate === null)).toBe(true);
  expect(r.capture.avgSavesPerCapturingUser).toBeNull();
  expect(r.review.reviewsPerSave).toBeNull();
  expect(r.cohorts).toEqual([]);
  expect(r.quotaCap).toBe(10);
});

test("accounts + acquisition source", async () => {
  await seedFixture();
  const r = await computeAnalyticsReport(sql, { now: 100 * DAY });
  expect(r.accounts.total).toBe(4);
  expect(r.accounts.active).toBe(4);
  expect(r.accounts.deleted).toBe(0);
  expect(r.accounts.byProvider).toEqual({ google: 1, apple: 3 });
});

test("DAU/WAU/MAU over trailing UTC days", async () => {
  await seedFixture();
  const r = await computeAnalyticsReport(sql, { now: 100 * DAY });
  // A active day100; B day92; C day60/61; D day60. today=100.
  expect(r.active.dauUtc).toBe(1); // A only
  expect(r.active.wauUtc).toBe(1); // [94,100] → A only (B@92 just outside)
  expect(r.active.mauUtc).toBe(2); // [71,100] → A@100 + B@92 (C/D@60-61 outside)
});

test("cohort retention: returned-within-N with elapsed-window denominator", async () => {
  await seedFixture();
  const r = await computeAnalyticsReport(sql, { now: 100 * DAY });
  const byN = Object.fromEntries(r.retention.map((b) => [b.days, b]));

  // N=1: eligible {B,C,D} (A's window not elapsed); returned {C} (C reviewed day61 = signup+1)
  expect(byN[1]).toEqual({ days: 1, eligible: 3, returned: 1, rate: 0.333 });
  // N=7: eligible {B,C,D}; returned {B (day92 within 90+7), C}
  expect(byN[7]).toEqual({ days: 7, eligible: 3, returned: 2, rate: 0.667 });
  // N=30: eligible {C,D} (B's 90+30=120 > 100, not elapsed); returned {C}
  expect(byN[30]).toEqual({ days: 30, eligible: 2, returned: 1, rate: 0.5 });
});

test("per-cohort breakdown", async () => {
  await seedFixture();
  const r = await computeAnalyticsReport(sql, { now: 100 * DAY });
  expect(r.cohorts.length).toBe(3); // sign-up days 60, 90, 100
  const day60 = r.cohorts.find((c) => c.size === 2)!; // C + D
  expect(day60.returnedWithin1).toBe(1); // C only
  expect(day60.returnedWithin7).toBe(1);
  expect(day60.returnedWithin30).toBe(1);
});

test("capture + review engagement", async () => {
  await seedFixture();
  const r = await computeAnalyticsReport(sql, { now: 100 * DAY });
  expect(r.capture.totalSaves).toBe(3);
  expect(r.capture.liveWords).toBe(3);
  expect(r.capture.capturingUsers).toBe(3);
  expect(r.capture.avgSavesPerCapturingUser).toBe(1);
  expect(r.capture.medianSavesPerCapturingUser).toBe(1);
  expect(r.review.totalReviews).toBe(1);
  expect(r.review.reviewingUsers).toBe(1);
  expect(r.review.reviewsPerSave).toBe(0.333);
  expect(r.review.pctCapturingUsersWhoReview).toBe(0.333);
});

test("willingness-to-pay: context adoption + cap hits (default cap 10)", async () => {
  await seedFixture();
  const r = await computeAnalyticsReport(sql, { now: 100 * DAY });
  expect(r.willingnessToPay.contextUsers).toBe(2); // B + C
  expect(r.willingnessToPay.totalContextExplanations).toBe(13); // 10 + 3
  expect(r.willingnessToPay.adoptionRate).toBe(0.5); // 2 of 4 active
  expect(r.willingnessToPay.userDayCapHits).toBe(1); // only C's day reached 10
  expect(r.willingnessToPay.usersWhoHitCap).toBe(1);
  expect(r.willingnessToPay.maxPerUserDay).toBe(10);
});

test("quotaCap override changes cap-hit accounting", async () => {
  await seedFixture();
  const r = await computeAnalyticsReport(sql, { now: 100 * DAY, quotaCap: 3 });
  expect(r.quotaCap).toBe(3);
  expect(r.willingnessToPay.userDayCapHits).toBe(2); // C's 10 and B's 3 both ≥ 3
  expect(r.willingnessToPay.usersWhoHitCap).toBe(2);
});

test("dashboard shell: token field + token-gated data fetch + sections, no embedded data", () => {
  const h = ANALYTICS_DASHBOARD_HTML;
  expect(h).toContain("<!doctype html>");
  expect(h).toContain('name="robots" content="noindex"');
  expect(h).toContain('id="token"');
  expect(h).toContain("/analytics/summary"); // fetches the gated endpoint
  expect(h).toContain("authorization"); // sends the Bearer token
  expect(h).toContain("Retention");
  expect(h).toContain("Willingness to pay");
  // The shell must NOT contain a backtick or ${ (would break the TS template literal it lives in).
  expect(h.includes("\`")).toBe(false);
  expect(h.includes("${")).toBe(false);
});

test("soft-deleted word still counts as a capture activity but not live", async () => {
  await acct("U", 50);
  await word("w1", "U", 50, false);
  await word("w2", "U", 51, true); // soft-deleted
  const r = await computeAnalyticsReport(sql, { now: 60 * DAY });
  expect(r.capture.totalSaves).toBe(2);
  expect(r.capture.liveWords).toBe(1);
});
