import { test, expect, beforeEach } from "bun:test";
import { freshDb, ids, seedAccount } from "./helpers/db.ts";
import { saveWord } from "../src/words.ts";
import { ingestReview, parseSyncEvent, replayReviews } from "../src/review.ts";
import { computeAnalyticsReport } from "../src/analytics.ts";
import type { Sql } from "../src/sql.ts";

// SyncEvent.source end-to-end: the rating's originating surface is stored
// on fsrs_events for attribution ONLY — never folded into FSRS — and surfaces in /analytics so we can
// answer "does fragmented-time (widget) review actually happen?". Default 'app' for any omitting path.

let sql: Sql;
let newId: () => string;

async function seedWord(user: string, surface: string, createdAt = 1): Promise<string> {
  const w = await saveWord(sql, { userId: user, surfaceUnit: surface, targetLanguage: "en", now: createdAt, newId });
  return w.status === "created" || w.status === "resurrected" || w.status === "deduped" ? w.word.id : "";
}

async function sourceOf(eventId: string): Promise<string | null> {
  const r = await sql.prepare(`SELECT source FROM fsrs_events WHERE id = ?`).bind(eventId).first<{ source: string }>();
  return r?.source ?? null;
}

beforeEach(async () => {
  ({ sql } = freshDb());
  newId = ids("s");
  await seedAccount(sql, "u1");
});

test("ingestReview persists the given source, and defaults to 'app' when omitted", async () => {
  const wid = await seedWord("u1", "ledger", 1);
  await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "e-widget", rating: 3, clientReviewTs: 1000, now: 1000, source: "widget" });
  await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "e-default", rating: 3, clientReviewTs: 2000, now: 2000 }); // no source
  expect(await sourceOf("e-widget")).toBe("widget");
  expect(await sourceOf("e-default")).toBe("app");
});

test("source is attribution only — it does NOT change the FSRS fold (same rating, different source ⇒ same projection)", async () => {
  const a = await seedWord("u1", "alpha", 1);
  const b = await seedWord("u1", "bravo", 1);
  const app = await ingestReview(sql, { userId: "u1", wordId: a, eventId: "ea", rating: 3, clientReviewTs: 1000, now: 1000, source: "app" });
  const wid = await ingestReview(sql, { userId: "u1", wordId: b, eventId: "eb", rating: 3, clientReviewTs: 1000, now: 1000, source: "widget" });
  expect(app.status).toBe("applied");
  expect(wid.status).toBe("applied");
  if (app.status === "applied" && wid.status === "applied") {
    // Identical first review, only the source differs → byte-identical projection.
    expect(wid.card).toEqual(app.card);
  }
});

test("double-producer idempotency: re-flushing the SAME event id (even from another surface) does not double-count or rewrite source", async () => {
  const wid = await seedWord("u1", "charlie", 1);
  // The widget enqueued event 'dup' and graded; a later /sync flush re-sends the SAME id tagged 'app'.
  await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "dup", rating: 3, clientReviewTs: 1000, now: 1000, source: "widget" });
  const events = [{ word_id: wid, event_id: "dup", rating: 3, client_review_ts: 1000, source: "app" }].map(parseSyncEvent);
  const results = await replayReviews(sql, { userId: "u1", events, now: 2000 });
  expect(results.map((r) => r.status)).toEqual(["applied"]);

  // Exactly one event row, reps==1 (no double count), and the FIRST writer's source is retained (the
  // idempotent replay refolds but never re-inserts) — so attribution reflects who really produced it.
  const count = await sql.prepare(`SELECT COUNT(*) AS n FROM fsrs_events WHERE word_id = ?`).bind(wid).first<{ n: number }>();
  expect(Number(count?.n)).toBe(1);
  expect(await sourceOf("dup")).toBe("widget");
  const card = await sql.prepare(`SELECT reps FROM fsrs_cards WHERE word_id = ?`).bind(wid).first<{ reps: number }>();
  expect(card?.reps).toBe(1);
});

test("analytics: review.bySource counts per surface and fragmentedReviewingUsers counts distinct non-'app' reviewers", async () => {
  await seedAccount(sql, "u2");
  const w1 = await seedWord("u1", "delta", 1);
  const w2 = await seedWord("u2", "echo", 1);
  // u1 reviews twice in-app + once via widget; u2 reviews once via notification.
  await ingestReview(sql, { userId: "u1", wordId: w1, eventId: "a1", rating: 3, clientReviewTs: 1000, now: 1000, source: "app" });
  await ingestReview(sql, { userId: "u1", wordId: w1, eventId: "a2", rating: 3, clientReviewTs: 2000, now: 2000, source: "app" });
  await ingestReview(sql, { userId: "u1", wordId: w1, eventId: "a3", rating: 3, clientReviewTs: 3000, now: 3000, source: "widget" });
  await ingestReview(sql, { userId: "u2", wordId: w2, eventId: "b1", rating: 3, clientReviewTs: 1000, now: 1000, source: "notification" });

  const report = await computeAnalyticsReport(sql, { now: 4000 });
  expect(report.review.totalReviews).toBe(4);
  expect(report.review.bySource).toEqual({ app: 2, widget: 1, notification: 1 });
  expect(report.review.fragmentedReviewingUsers).toBe(2); // u1 (widget) + u2 (notification)
});
