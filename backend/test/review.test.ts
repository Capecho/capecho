import { test, expect, beforeEach } from "bun:test";
import { freshDb, ids, seedAccount } from "./helpers/db.ts";
import { saveWord, softDeleteWord } from "../src/words.ts";
import { ingestReview, listDueReviews, DEFAULT_NEW_CARD_CAP } from "../src/review.ts";
import type { Sql } from "../src/sql.ts";

const DAY = 86_400_000;

let sql: Sql;
let newId: () => string;

async function seedWord(surface = "serendipity", createdAt = 1): Promise<string> {
  const w = await saveWord(sql, { userId: "u1", surfaceUnit: surface, targetLanguage: "en", now: createdAt, newId });
  return w.status === "created" || w.status === "resurrected" || w.status === "deduped" ? w.word.id : "";
}

async function eventRow(id: string): Promise<{ server_seq: number; card_epoch: number; clamped_elapsed: number } | null> {
  return sql.prepare(`SELECT server_seq, card_epoch, clamped_elapsed FROM fsrs_events WHERE id = ?`).bind(id).first();
}

beforeEach(async () => {
  ({ sql } = freshDb());
  newId = ids("r");
  await seedAccount(sql, "u1");
});

test("first review applies, persists a projection, and assigns server_seq 1", async () => {
  const wid = await seedWord("serendipity", 1);
  const out = await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "e1", rating: 3, clientReviewTs: 1000, now: 1000 });
  expect(out.status).toBe("applied");
  if (out.status === "applied") {
    expect(out.replay).toBe(false);
    expect(out.card.reps).toBe(1);
    expect(out.card.state).toBe("review"); // a first Good graduates past the single 10m step straight to review
  }
  expect((await eventRow("e1"))?.server_seq).toBe(1);
  const card = await sql.prepare(`SELECT reps, last_applied_seq FROM fsrs_cards WHERE word_id = ?`).bind(wid).first<{ reps: number; last_applied_seq: number }>();
  expect(card?.reps).toBe(1);
  expect(card?.last_applied_seq).toBe(1);
});

test("ingest is idempotent on the event id (a retry replays, never double-applies)", async () => {
  const wid = await seedWord();
  const first = await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "dup", rating: 3, clientReviewTs: 1000, now: 1000 });
  const retry = await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "dup", rating: 3, clientReviewTs: 1000, now: 1000 });
  expect(retry.status).toBe("applied");
  if (retry.status === "applied") expect(retry.replay).toBe(true);
  const n = await sql.prepare(`SELECT COUNT(*) AS n FROM fsrs_events WHERE word_id = ?`).bind(wid).first<{ n: number }>();
  expect(Number(n?.n)).toBe(1); // only one event row
  if (first.status === "applied" && retry.status === "applied") expect(retry.card).toEqual(first.card);
});

test("server_seq is per-user monotonic across units", async () => {
  const a = await seedWord("alpha");
  const b = await seedWord("beta");
  await ingestReview(sql, { userId: "u1", wordId: a, eventId: "e1", rating: 3, clientReviewTs: 1000, now: 1000 });
  await ingestReview(sql, { userId: "u1", wordId: b, eventId: "e2", rating: 3, clientReviewTs: 1000, now: 1000 });
  expect((await eventRow("e1"))?.server_seq).toBe(1);
  expect((await eventRow("e2"))?.server_seq).toBe(2);
});

test("a future-dated review is clamped to the server receive time (skew can't inflate elapsed)", async () => {
  const wid = await seedWord("serendipity", 1000);
  await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "e1", rating: 3, clientReviewTs: 999_999_999, now: 5000 });
  expect((await eventRow("e1"))?.clamped_elapsed).toBe(4000); // min(future, now=5000) - created(1000)
});

test("an out-of-order (earlier) event is floored to 0 elapsed (eng-review C4)", async () => {
  const wid = await seedWord("serendipity", 1);
  await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "e1", rating: 3, clientReviewTs: 10_000, now: 10_000 });
  await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "e2", rating: 3, clientReviewTs: 9_000, now: 10_000 });
  expect((await eventRow("e2"))?.clamped_elapsed).toBe(0); // 9000 precedes the last applied review (10000)
});

test("elapsed after an out-of-order event measures from the HELD fold clock, not the late event's ts [review-fix: Codex P1]", async () => {
  const wid = await seedWord("serendipity", 1);
  // e1 applied at 1000; e2 arrives late (review @500, before e1) → floored to 0, fold clock stays at 1000
  await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "e1", rating: 3, clientReviewTs: 1000, now: 1000 });
  await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "e2", rating: 3, clientReviewTs: 500, now: 1100 });
  expect((await eventRow("e2"))?.clamped_elapsed).toBe(0);
  // e3 @1100 must measure from the held fold clock (1000), i.e. 100 — NOT from e2's earlier ts (which gave 600)
  await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "e3", rating: 3, clientReviewTs: 1100, now: 1100 });
  expect((await eventRow("e3"))?.clamped_elapsed).toBe(100);
});

test("a rating on a soft-deleted unit is rejected — delete wins", async () => {
  const wid = await seedWord();
  await softDeleteWord(sql, "u1", wid, 2000);
  const out = await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "e1", rating: 3, clientReviewTs: 3000, now: 3000 });
  expect(out.status).toBe("unit_deleted");
});

test("reusing an event id for a DIFFERENT unit is a conflict (the id is global)", async () => {
  const a = await seedWord("alpha");
  const b = await seedWord("beta");
  await ingestReview(sql, { userId: "u1", wordId: a, eventId: "shared", rating: 3, clientReviewTs: 1000, now: 1000 });
  const out = await ingestReview(sql, { userId: "u1", wordId: b, eventId: "shared", rating: 3, clientReviewTs: 1000, now: 1000 });
  expect(out.status).toBe("id_conflict");
});

test("a review for a non-existent unit is not_found", async () => {
  const out = await ingestReview(sql, { userId: "u1", wordId: "nope", eventId: "e1", rating: 3, clientReviewTs: 1000, now: 1000 });
  expect(out.status).toBe("not_found");
});

test("resurrect bumps the epoch: the new card folds only the new-epoch events (resets to new-card)", async () => {
  const wid = await seedWord("serendipity", 1);
  await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "e1", rating: 3, clientReviewTs: 1000, now: 1000 });
  await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "e2", rating: 3, clientReviewTs: 2000, now: 2000 });
  await softDeleteWord(sql, "u1", wid, 3000);
  const re = await saveWord(sql, { userId: "u1", surfaceUnit: "serendipity", targetLanguage: "en", now: 4000, newId });
  expect(re.status).toBe("resurrected");
  if (re.status === "resurrected") expect(re.word.fsrs_epoch).toBe(1);

  const out = await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "e3", rating: 3, clientReviewTs: 5000, now: 5000 });
  expect(out.status).toBe("applied");
  if (out.status === "applied") expect(out.card.reps).toBe(1); // fresh card — pre-delete reviews ignored
  const card = await sql.prepare(`SELECT card_epoch FROM fsrs_cards WHERE word_id = ?`).bind(wid).first<{ card_epoch: number }>();
  expect(card?.card_epoch).toBe(1);
});

test("a stale-epoch event replay does NOT revert a resurrected card [review-fix: Claude HIGH/Codex P2]", async () => {
  const wid = await seedWord("serendipity", 1);
  await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "old", rating: 3, clientReviewTs: 1000, now: 1000 }); // epoch 0
  await softDeleteWord(sql, "u1", wid, 2000);
  expect((await saveWord(sql, { userId: "u1", surfaceUnit: "serendipity", targetLanguage: "en", now: 3000, newId })).status).toBe("resurrected");
  await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "new", rating: 3, clientReviewTs: 4000, now: 4000 }); // epoch 1

  // a late duplicate delivery of the OLD (epoch-0) event must not touch the live card
  const replay = await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "old", rating: 3, clientReviewTs: 1000, now: 5000 });
  expect(replay.status).toBe("applied");
  if (replay.status === "applied") expect(replay.replay).toBe(true);

  const card = await sql.prepare(`SELECT card_epoch, reps FROM fsrs_cards WHERE word_id = ?`).bind(wid).first<{ card_epoch: number; reps: number }>();
  expect(card?.card_epoch).toBe(1); // still the live epoch, not reverted to 0
  expect(card?.reps).toBe(1);
  const due = await listDueReviews(sql, "u1", 1 + 100 * DAY, "UTC");
  expect(due.due.some((c) => c.wordId === wid)).toBe(true);
  expect(due.newCards.some((c) => c.wordId === wid)).toBe(false); // not re-surfaced as new
});

test("elapsed baselines on the previous APPLIED (clamped) time, not its raw skewed client ts [review-fix: Codex P1]", async () => {
  const wid = await seedWord("serendipity", 1);
  // A's client clock runs 1h fast → clamped down to the server receive time (now=1000)
  await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "a", rating: 3, clientReviewTs: 3_601_000, now: 1000 });
  // B happens exactly one real day after A's APPLIED time
  await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "b", rating: 3, clientReviewTs: 86_401_000, now: 86_401_000 });
  // full day, measured from A's applied time (1000) — NOT reduced by A's 1h forward skew
  expect((await eventRow("b"))?.clamped_elapsed).toBe(86_400_000);
});

// --- due selection ----------------------------------------------------------

test("due: never-reviewed units surface as new cards; a reviewed card leaves the new set", async () => {
  const a = await seedWord("alpha");
  const b = await seedWord("beta");
  const before = await listDueReviews(sql, "u1", 10_000, "UTC");
  expect(before.newCards.map((c) => c.wordId).sort()).toEqual([a, b].sort());
  expect(before.due).toHaveLength(0);

  await ingestReview(sql, { userId: "u1", wordId: a, eventId: "e1", rating: 1, clientReviewTs: 1, now: 1 });
  const after = await listDueReviews(sql, "u1", 1 + 100 * DAY, "UTC"); // far future so the reviewed card is due
  expect(after.due.some((c) => c.wordId === a)).toBe(true);
  expect(after.newCards.some((c) => c.wordId === a)).toBe(false); // no longer new
  expect(after.newCards.some((c) => c.wordId === b)).toBe(true);
});

test("due: a new card rated Good echoes back DAYS later, not the same session [grade-not-sticking fix]", async () => {
  // Regression for "I rated Good but reopening keeps re-prompting it": the ts-fsrs learning-step
  // DEFAULT (["1m","10m"]) scheduled new+Good only ~10 minutes out (state `learning`), so any reopen
  // inside that window re-surfaced the SAME word. With a single 10m step (fsrs.ts) Good graduates past
  // it and is due ~2 days out — so it leaves the queue for the rest of the session.
  const MIN = 60_000;
  const t = 1_000_000; // ~11 days after the seed's created_at (1), so nothing is skew-clamped
  const w = await seedWord("serendipity");
  await ingestReview(sql, { userId: "u1", wordId: w, eventId: "g1", rating: 3, clientReviewTs: t, now: t });
  // Ten minutes later — the OLD learning step. Must be neither due nor new (it's scheduled, just not yet).
  const soon = await listDueReviews(sql, "u1", t + 10 * MIN, "UTC");
  expect(soon.due.some((c) => c.wordId === w)).toBe(false);
  expect(soon.newCards.some((c) => c.wordId === w)).toBe(false);
  // A day later it's still resting (the interval is multi-day, not intra-session).
  expect((await listDueReviews(sql, "u1", t + 1 * DAY, "UTC")).due.some((c) => c.wordId === w)).toBe(false);
  // Three days out it echoes back.
  expect((await listDueReviews(sql, "u1", t + 3 * DAY, "UTC")).due.some((c) => c.wordId === w)).toBe(true);
});

test("due: a soft-deleted unit never surfaces (neither due nor new)", async () => {
  const a = await seedWord("alpha");
  await ingestReview(sql, { userId: "u1", wordId: a, eventId: "e1", rating: 1, clientReviewTs: 1, now: 1 });
  await softDeleteWord(sql, "u1", a, 2000);
  const out = await listDueReviews(sql, "u1", 1 + 100 * DAY, "UTC");
  expect(out.due.some((c) => c.wordId === a)).toBe(false);
  expect(out.newCards.some((c) => c.wordId === a)).toBe(false);
});

test("due: new cards honor the soft cap", async () => {
  for (let i = 0; i < DEFAULT_NEW_CARD_CAP + 5; i++) await seedWord(`word${i}`);
  const out = await listDueReviews(sql, "u1", 10_000, "UTC");
  expect(out.newCards).toHaveLength(DEFAULT_NEW_CARD_CAP);
  const limited = await listDueReviews(sql, "u1", 10_000, "UTC", 3);
  expect(limited.newCards).toHaveLength(3);
});

// --- per-account-DAY new-card cap (US-1.2: 20 new/day, account-tz local midnight) -------

test("due: introducing the full daily cap holds back further new cards the same day", async () => {
  const words: string[] = [];
  for (let i = 0; i < DEFAULT_NEW_CARD_CAP + 5; i++) words.push(await seedWord(`w${i}`));
  const today = Date.parse("2026-05-27T12:00:00Z");
  // First-review the full daily cap today → all 20 slots spent.
  for (let i = 0; i < DEFAULT_NEW_CARD_CAP; i++) {
    await ingestReview(sql, { userId: "u1", wordId: words[i], eventId: `today-${words[i]}`, rating: 3, clientReviewTs: today, now: today });
  }
  const out = await listDueReviews(sql, "u1", today, "UTC");
  // 20 introduced today == cap; the 5 still-new words are withheld until tomorrow (not a per-request 20).
  expect(out.newCards).toHaveLength(0);
});

test("due: re-fetching mid-day does not re-spend the budget (introductions are counted, not surfaced count)", async () => {
  const words: string[] = [];
  for (let i = 0; i < DEFAULT_NEW_CARD_CAP + 3; i++) words.push(await seedWord(`w${i}`));
  const today = Date.parse("2026-05-27T09:00:00Z");
  // Introduce 5 today, then ask again the same day: only 15 of the remaining new cards surface.
  for (let i = 0; i < 5; i++) {
    await ingestReview(sql, { userId: "u1", wordId: words[i], eventId: `today-${words[i]}`, rating: 3, clientReviewTs: today, now: today });
  }
  const out = await listDueReviews(sql, "u1", today, "UTC");
  expect(out.newCards).toHaveLength(DEFAULT_NEW_CARD_CAP - 5); // max(0, 20 - 5 introduced today)
});

test("due: the new-card budget refills after the account-tz day rolls over", async () => {
  const words: string[] = [];
  for (let i = 0; i < DEFAULT_NEW_CARD_CAP * 2 + 5; i++) words.push(await seedWord(`w${i}`));
  const day1 = Date.parse("2026-05-27T12:00:00Z");
  for (let i = 0; i < DEFAULT_NEW_CARD_CAP; i++) {
    await ingestReview(sql, { userId: "u1", wordId: words[i], eventId: `d1-${words[i]}`, rating: 3, clientReviewTs: day1, now: day1 });
  }
  expect((await listDueReviews(sql, "u1", day1, "UTC")).newCards).toHaveLength(0); // cap spent

  const day2 = Date.parse("2026-05-28T08:00:00Z"); // next UTC day
  const refilled = await listDueReviews(sql, "u1", day2, "UTC");
  expect(refilled.newCards).toHaveLength(DEFAULT_NEW_CARD_CAP); // yesterday's introductions don't count → full budget
});

test("due: introduction accounting follows the account IANA tz (travel) — same instant, different day boundary", async () => {
  // Mirrors time.test.ts: 2026-05-27T03:00:00Z is still 05-26 in New York but already 05-27 in Shanghai.
  const introducedAt = Date.parse("2026-05-27T03:00:00Z");
  const now = Date.parse("2026-05-27T05:00:00Z");
  const words: string[] = [];
  for (let i = 0; i < 5; i++) words.push(await seedWord(`tw${i}`));
  await ingestReview(sql, { userId: "u1", wordId: words[0], eventId: "trav", rating: 3, clientReviewTs: introducedAt, now: introducedAt });

  // New York: the introduction landed YESTERDAY (05-26 local) → today's budget is untouched.
  const ny = await listDueReviews(sql, "u1", now, "America/New_York", 3);
  expect(ny.newCards).toHaveLength(3); // full cap of 3

  // Shanghai: the SAME event already landed TODAY (05-27 local) → one slot is spent.
  const sh = await listDueReviews(sql, "u1", now, "Asia/Shanghai", 3);
  expect(sh.newCards).toHaveLength(2); // 3 − 1 introduced today
});

test("due: a resurrect resets the daily count — a pre-delete introduction doesn't bind the new epoch", async () => {
  const today = Date.parse("2026-05-27T12:00:00Z");
  const wid = await seedWord("ephemeral", 1);
  // Introduce + delete + resurrect, all today. The resurrected unit has NO current-epoch event,
  // so it is "new" again and its old-epoch introduction must NOT count against today's budget.
  await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "pre", rating: 3, clientReviewTs: today, now: today });
  await softDeleteWord(sql, "u1", wid, today + 1);
  expect((await saveWord(sql, { userId: "u1", surfaceUnit: "ephemeral", targetLanguage: "en", now: today + 2, newId })).status).toBe("resurrected");

  const out = await listDueReviews(sql, "u1", today + 3, "UTC");
  expect(out.newCards.some((c) => c.wordId === wid)).toBe(true); // surfaces as new again
  expect(out.newCards).toHaveLength(1); // and the stale-epoch introduction spent no budget
});
