import { test, expect, beforeEach } from "bun:test";
import { freshDb, ids, seedAccount } from "./helpers/db.ts";
import { saveWord, softDeleteWord } from "../src/words.ts";
import { replayReviews, parseSyncEvent, type SyncEventInput, type ParsedSyncEvent } from "../src/review.ts";
import type { Sql } from "../src/sql.ts";

let sql: Sql;
let newId: () => string;

// The flush takes the PARSED queue; these unit tests feed already-good events, so wrap them.
const ok = (event: SyncEventInput): ParsedSyncEvent => ({ ok: true, event });

async function seedWord(surface: string, createdAt = 1): Promise<string> {
  const w = await saveWord(sql, { userId: "u1", surfaceUnit: surface, targetLanguage: "en", now: createdAt, newId });
  return w.status === "created" ? w.word.id : "";
}

async function eventSeq(id: string): Promise<number | undefined> {
  return (await sql.prepare(`SELECT server_seq FROM fsrs_events WHERE id = ?`).bind(id).first<{ server_seq: number }>())?.server_seq;
}

async function eventCount(): Promise<number> {
  return Number((await sql.prepare(`SELECT COUNT(*) AS n FROM fsrs_events`).first<{ n: number }>())?.n ?? 0);
}

beforeEach(async () => {
  ({ sql } = freshDb());
  newId = ids("s");
  await seedAccount(sql, "u1");
});

test("ordered batch replay: events apply in array order, server_seq assigned in flush order", async () => {
  const a = await seedWord("alpha");
  const b = await seedWord("beta");
  const events: SyncEventInput[] = [
    { wordId: a, eventId: "e1", rating: 3, clientReviewTs: 1000 },
    { wordId: b, eventId: "e2", rating: 3, clientReviewTs: 1000 },
  ];
  const res = await replayReviews(sql, { userId: "u1", events: events.map(ok), now: 1000 });
  expect(res.map((r) => r.status)).toEqual(["applied", "applied"]);
  expect(await eventSeq("e1")).toBe(1);
  expect(await eventSeq("e2")).toBe(2);
});

test("flush is idempotent: re-sending the same batch adds no new events", async () => {
  const a = await seedWord("alpha");
  const events: SyncEventInput[] = [{ wordId: a, eventId: "e1", rating: 3, clientReviewTs: 1000 }];
  await replayReviews(sql, { userId: "u1", events: events.map(ok), now: 1000 });
  const again = await replayReviews(sql, { userId: "u1", events: events.map(ok), now: 2000 });
  expect(again[0]!.status).toBe("applied"); // replay still reports applied (idempotent)
  expect(await eventCount()).toBe(1); // but no duplicate event
});

test("delete wins: a queued rating for a tombstoned unit is rejected on flush", async () => {
  const a = await seedWord("alpha");
  await softDeleteWord(sql, "u1", a, 5);
  const res = await replayReviews(sql, { userId: "u1", events: [ok({ wordId: a, eventId: "e1", rating: 3, clientReviewTs: 1000 })], now: 1000 });
  expect(res[0]!.status).toBe("unit_deleted");
  expect(await eventCount()).toBe(0);
});

test("ENG-5 multi-device interleave: a late, earlier-timestamped offline event folds in order with elapsed floored to 0", async () => {
  // word created at t0=1. Device B (online) reviews at t=2000 and reaches the server first;
  // Device A reviewed earlier (t=1000) but was offline and flushes LATE (received at 3000).
  const w = await seedWord("interleave", 1);
  await replayReviews(sql, { userId: "u1", events: [ok({ wordId: w, eventId: "B", rating: 3, clientReviewTs: 2000 })], now: 2000 });
  await replayReviews(sql, { userId: "u1", events: [ok({ wordId: w, eventId: "A", rating: 3, clientReviewTs: 1000 })], now: 3000 });

  // ORDER is the server sequence (B=1, A=2); ELAPSED is clamped — A's review precedes the
  // applied fold clock (2000), so it contributes 0, never a negative interval.
  expect(await eventSeq("B")).toBe(1);
  expect(await eventSeq("A")).toBe(2);
  const evA = await sql.prepare(`SELECT clamped_elapsed FROM fsrs_events WHERE id = 'A'`).first<{ clamped_elapsed: number }>();
  expect(evA?.clamped_elapsed).toBe(0);
  const card = await sql.prepare(`SELECT reps, card_epoch FROM fsrs_cards WHERE word_id = ?`).bind(w).first<{ reps: number; card_epoch: number }>();
  expect(card?.reps).toBe(2); // both reviews folded, deterministically, in seq order
  expect(card?.card_epoch).toBe(0);
});

test("a structurally-bad event is reported `invalid` and does NOT sink the rest of the flush [review-fix: Codex P2]", async () => {
  const a = await seedWord("alpha");
  // Raw wire shape (snake_case), as it arrives off the JSON body, through the real parser.
  const raw = [
    { word_id: a, event_id: "good", rating: 3, client_review_ts: 1000 },
    { word_id: a, event_id: "bad", rating: 9, client_review_ts: 1000 }, // rating out of 1-4
    { word_id: a, rating: 3, client_review_ts: 1000 }, // missing event_id entirely
  ];
  const res = await replayReviews(sql, { userId: "u1", events: raw.map(parseSyncEvent), now: 1000 });

  expect(res.map((r) => r.status)).toEqual(["applied", "invalid", "invalid"]); // order preserved
  expect(res[1]!.eventId).toBe("bad"); // a bad-but-present event_id is echoed for correlation
  expect(res[2]!.eventId).toBe(""); // no usable event_id ⇒ client correlates by order
  expect(await eventCount()).toBe(1); // only the good event landed
  expect(await eventSeq("good")).toBe(1); // and the invalid events consumed no server_seq
});

test("parseSyncEvent classifies wire events and recovers the event id when present", async () => {
  expect(parseSyncEvent({ word_id: "w", event_id: "e", rating: 3, client_review_ts: 1 })).toEqual({
    ok: true,
    event: { wordId: "w", eventId: "e", rating: 3, clientReviewTs: 1, source: "app" }, // absent source → 'app'
  });
  // A provided source is carried through; an oversized/blank/non-string one degrades to 'app'.
  expect(parseSyncEvent({ word_id: "w", event_id: "e", rating: 3, client_review_ts: 1, source: "widget" })).toEqual({
    ok: true,
    event: { wordId: "w", eventId: "e", rating: 3, clientReviewTs: 1, source: "widget" },
  });
  expect(parseSyncEvent({ word_id: "w", event_id: "e", rating: 3, client_review_ts: 1, source: "x".repeat(64) })).toEqual({
    ok: true,
    event: { wordId: "w", eventId: "e", rating: 3, clientReviewTs: 1, source: "app" },
  });
  expect(parseSyncEvent({ word_id: "w", event_id: "e", rating: 0, client_review_ts: 1 })).toEqual({ ok: false, eventId: "e" }); // bad rating, id kept
  expect(parseSyncEvent({ word_id: "w", event_id: "e", rating: 2.5, client_review_ts: 1 })).toEqual({ ok: false, eventId: "e" }); // non-integer rating
  expect(parseSyncEvent({ word_id: "w", event_id: "e", rating: 3, client_review_ts: NaN })).toEqual({ ok: false, eventId: "e" }); // non-finite ts
  expect(parseSyncEvent({ word_id: "w", rating: 3, client_review_ts: 1 })).toEqual({ ok: false, eventId: "" }); // missing event_id
  expect(parseSyncEvent(null)).toEqual({ ok: false, eventId: "" });
});
