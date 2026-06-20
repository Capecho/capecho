import type { Sql } from "./sql.ts";

// First-party retention & engagement readout — NO third-party analytics SDK, NO new tracking, NO new
// tables. Computed entirely from data Capecho already stores: accounts (sign-up), sessions (sign-in),
// words (capture), fsrs_events (review), context_quota_reservations (the paid context layer). This is
// the §14 success-metric / §16 kill-criteria readout that informs "form the LLC?" + "is there
// willingness to pay?". Admin-gated at the route layer (index.ts) by METRICS_ADMIN_TOKEN, same gate as
// the After-M3 GATE. Exact, not sampled (the beta cohort is small); recomputable any time from the
// immutable rows.
//
// Day bucketing is by UTC calendar day: dayIndex = floor(epoch_ms / 86_400_000). "Activity" on a day
// = a capture, a review, OR a sign-in that day. "Returned within N days" = activity strictly AFTER the
// sign-up day and within N days of it; the rate's denominator is only cohorts whose N-day window has
// fully elapsed (signupDay + N <= today), so a young cohort never deflates the number. DAU/WAU/MAU are
// distinct active users over the trailing 1 / 7 / 30 UTC days.

const DAY_MS = 86_400_000;
const dayIndex = (ms: number): number => Math.floor(ms / DAY_MS);
const dayIndexToDate = (idx: number): string => new Date(idx * DAY_MS).toISOString().slice(0, 10);

const median = (xs: number[]): number | null => {
  if (xs.length === 0) return null;
  const s = [...xs].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid]! : (s[mid - 1]! + s[mid]!) / 2;
};
const rate = (num: number, den: number): number | null => (den > 0 ? num / den : null);
const round3 = (x: number | null): number | null => (x === null ? null : Math.round(x * 1000) / 1000);

export const DEFAULT_QUOTA_CAP = 10;
const RETENTION_DAYS = [1, 7, 30] as const;

export interface RetentionBucket {
  days: number;
  eligible: number; // cohorts old enough that the N-day window has elapsed
  returned: number;
  rate: number | null;
}

export interface CohortRow {
  day: string; // UTC sign-up day, YYYY-MM-DD
  size: number;
  returnedWithin1: number;
  returnedWithin7: number;
  returnedWithin30: number;
}

export interface AnalyticsReport {
  generatedAtMs: number;
  quotaCap: number;
  notes: string;
  accounts: { total: number; active: number; deleted: number; byProvider: Record<string, number> };
  active: { dauUtc: number; wauUtc: number; mauUtc: number };
  retention: RetentionBucket[];
  capture: {
    totalSaves: number;
    liveWords: number;
    capturingUsers: number;
    avgSavesPerCapturingUser: number | null;
    medianSavesPerCapturingUser: number | null;
  };
  review: {
    totalReviews: number;
    reviewingUsers: number;
    reviewsPerSave: number | null;
    pctCapturingUsersWhoReview: number | null;
    // Per-surface review counts ('app' | 'widget' | 'notification' | …) and the distinct users who
    // reviewed from ANY non-'app' surface — the widget RFC's core hypothesis readout ("does
    // fragmented-time review actually happen, and for how many people?").
    bySource: Record<string, number>;
    fragmentedReviewingUsers: number;
  };
  willingnessToPay: {
    contextUsers: number;
    totalContextExplanations: number;
    adoptionRate: number | null; // contextUsers / active accounts
    userDayCapHits: number; // (user, day) pairs that reached the free cap
    usersWhoHitCap: number;
    maxPerUserDay: number;
  };
  cohorts: CohortRow[];
}

interface AccountRow { id: string; createdAt: number; provider: string; deletedAt: number | null }

export async function computeAnalyticsReport(
  sql: Sql,
  input: { now: number; quotaCap?: number },
): Promise<AnalyticsReport> {
  const now = input.now;
  const cap = input.quotaCap && input.quotaCap > 0 ? input.quotaCap : DEFAULT_QUOTA_CAP;
  const today = dayIndex(now);

  const accounts = await sql
    .prepare(`SELECT id, created_at AS createdAt, auth_provider AS provider, deleted_at AS deletedAt FROM accounts`)
    .all<AccountRow>();
  const words = await sql
    .prepare(`SELECT user_id AS userId, created_at AS createdAt, deleted_at AS deletedAt FROM words`)
    .all<{ userId: string; createdAt: number; deletedAt: number | null }>();
  const reviews = await sql
    .prepare(`SELECT user_id AS userId, created_at AS createdAt, source AS source FROM fsrs_events`)
    .all<{ userId: string; createdAt: number; source: string }>();
  const sessions = await sql
    .prepare(`SELECT user_id AS userId, created_at AS createdAt FROM sessions`)
    .all<{ userId: string; createdAt: number }>();
  const committed = await sql
    .prepare(`SELECT user_id AS userId, quota_day AS quotaDay FROM context_quota_reservations WHERE state = 'committed'`)
    .all<{ userId: string; quotaDay: string }>();

  // Per-user active UTC-day set (capture ∪ review ∪ sign-in).
  const activeDays = new Map<string, Set<number>>();
  const markActive = (userId: string, ms: number): void => {
    let s = activeDays.get(userId);
    if (!s) {
      s = new Set<number>();
      activeDays.set(userId, s);
    }
    s.add(dayIndex(ms));
  };
  for (const w of words) markActive(w.userId, w.createdAt);
  for (const r of reviews) markActive(r.userId, r.createdAt);
  for (const s of sessions) markActive(s.userId, s.createdAt);

  // Accounts + acquisition source.
  const byProvider: Record<string, number> = {};
  let activeAccounts = 0;
  let deletedAccounts = 0;
  for (const a of accounts) {
    byProvider[a.provider] = (byProvider[a.provider] ?? 0) + 1;
    if (a.deletedAt === null) activeAccounts++;
    else deletedAccounts++;
  }

  // DAU / WAU / MAU over trailing 1 / 7 / 30 UTC days.
  let dau = 0;
  let wau = 0;
  let mau = 0;
  for (const days of activeDays.values()) {
    let d = false;
    let w = false;
    let m = false;
    for (const di of days) {
      if (di === today) d = true;
      if (di >= today - 6 && di <= today) w = true;
      if (di >= today - 29 && di <= today) m = true;
    }
    if (d) dau++;
    if (w) wau++;
    if (m) mau++;
  }

  // Retention helper: any activity strictly after sign-up day, within N days.
  const returnedWithin = (userId: string, signupDay: number, n: number): boolean => {
    const days = activeDays.get(userId);
    if (!days) return false;
    for (const di of days) if (di > signupDay && di <= signupDay + n) return true;
    return false;
  };

  const retention: RetentionBucket[] = RETENTION_DAYS.map((n) => {
    let eligible = 0;
    let returned = 0;
    for (const a of accounts) {
      const sd = dayIndex(a.createdAt);
      if (sd + n <= today) {
        eligible++;
        if (returnedWithin(a.id, sd, n)) returned++;
      }
    }
    return { days: n, eligible, returned, rate: round3(rate(returned, eligible)) };
  });

  // Per-cohort table (by sign-up UTC day).
  const cohortMap = new Map<number, { size: number; r1: number; r7: number; r30: number }>();
  for (const a of accounts) {
    const sd = dayIndex(a.createdAt);
    let c = cohortMap.get(sd);
    if (!c) {
      c = { size: 0, r1: 0, r7: 0, r30: 0 };
      cohortMap.set(sd, c);
    }
    c.size++;
    if (returnedWithin(a.id, sd, 1)) c.r1++;
    if (returnedWithin(a.id, sd, 7)) c.r7++;
    if (returnedWithin(a.id, sd, 30)) c.r30++;
  }
  const cohorts: CohortRow[] = [...cohortMap.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([sd, c]) => ({
      day: dayIndexToDate(sd),
      size: c.size,
      returnedWithin1: c.r1,
      returnedWithin7: c.r7,
      returnedWithin30: c.r30,
    }));

  // Capture.
  let liveWords = 0;
  const savesPerUser = new Map<string, number>();
  for (const w of words) {
    if (w.deletedAt === null) liveWords++;
    savesPerUser.set(w.userId, (savesPerUser.get(w.userId) ?? 0) + 1);
  }
  const capturingUsers = savesPerUser.size;
  const totalSaves = words.length;

  // Review.
  const reviewingUsers = new Set(reviews.map((r) => r.userId)).size;
  const totalReviews = reviews.length;
  // Per-surface counts + the distinct users who reviewed from any non-'app' surface (widget /
  // notification). A null/absent source degrades to 'app' (defensive; the column defaults 'app').
  const bySource: Record<string, number> = {};
  const fragmentedReviewers = new Set<string>();
  for (const r of reviews) {
    const src = r.source ?? "app";
    bySource[src] = (bySource[src] ?? 0) + 1;
    if (src !== "app") fragmentedReviewers.add(r.userId);
  }

  // Willingness-to-pay (the paid context layer): committed reservations per (user, account-tz day).
  const committedPerUserDay = new Map<string, number>();
  const contextUsers = new Set<string>();
  for (const c of committed) {
    contextUsers.add(c.userId);
    const k = `${c.userId}\x00${c.quotaDay}`;
    committedPerUserDay.set(k, (committedPerUserDay.get(k) ?? 0) + 1);
  }
  let userDayCapHits = 0;
  let maxPerUserDay = 0;
  const usersWhoHitCap = new Set<string>();
  for (const [k, n] of committedPerUserDay) {
    if (n > maxPerUserDay) maxPerUserDay = n;
    if (n >= cap) {
      userDayCapHits++;
      usersWhoHitCap.add(k.split("\x00")[0]!);
    }
  }

  return {
    generatedAtMs: now,
    quotaCap: cap,
    notes:
      "UTC-day buckets. Activity = capture | review | sign-in. 'returned within N days' = activity strictly after sign-up day, within N days; rate denominator = cohorts whose N-day window has elapsed. Exact, not sampled.",
    accounts: { total: accounts.length, active: activeAccounts, deleted: deletedAccounts, byProvider },
    active: { dauUtc: dau, wauUtc: wau, mauUtc: mau },
    retention,
    capture: {
      totalSaves,
      liveWords,
      capturingUsers,
      avgSavesPerCapturingUser: round3(rate(totalSaves, capturingUsers)),
      medianSavesPerCapturingUser: median([...savesPerUser.values()]),
    },
    review: {
      totalReviews,
      reviewingUsers,
      reviewsPerSave: round3(rate(totalReviews, totalSaves)),
      pctCapturingUsersWhoReview: round3(rate(reviewingUsers, capturingUsers)),
      bySource,
      fragmentedReviewingUsers: fragmentedReviewers.size,
    },
    willingnessToPay: {
      contextUsers: contextUsers.size,
      totalContextExplanations: committed.length,
      adoptionRate: round3(rate(contextUsers.size, activeAccounts)),
      userDayCapHits,
      usersWhoHitCap: usersWhoHitCap.size,
      maxPerUserDay,
    },
    cohorts,
  };
}
