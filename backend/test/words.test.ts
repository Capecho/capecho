import { test, expect, beforeEach } from "bun:test";
import { freshDb, ids, seedAccount } from "./helpers/db.ts";
import {
  saveWord,
  listWords,
  softDeleteWord,
  restoreWord,
  getWordById,
  markExplanationReady,
} from "../src/words.ts";
import type { Sql } from "../src/sql.ts";

let sql: Sql;
let newId: () => string;

beforeEach(async () => {
  ({ sql } = freshDb());
  newId = ids("w");
  await seedAccount(sql, "u1");
  await seedAccount(sql, "u2");
});

const save = (over: Partial<Parameters<typeof saveWord>[1]> = {}) =>
  saveWord(sql, { userId: "u1", surfaceUnit: "Running", targetLanguage: "en", now: 1000, newId, ...over });

test("create then dedup: a resave of an ACTIVE unit returns the same row, not a new one", async () => {
  const a = await save();
  expect(a.status).toBe("created");
  const b = await save();
  expect(b.status).toBe("deduped");
  if (a.status !== "invalid_target_language" && a.status !== "empty_unit" && b.status === "deduped") {
    expect(b.word.id).toBe(a.word.id);
  }
  expect(await listWords(sql, "u1")).toHaveLength(1);
});

test("a sentence is rejected as unit_too_large — the save layer is words/short phrases, not paragraphs (§13)", async () => {
  const out = await save({
    surfaceUnit: "this is clearly a whole sentence and not a single vocabulary unit at all",
  });
  expect(out.status).toBe("unit_too_large");
  expect(await listWords(sql, "u1")).toHaveLength(0); // nothing stored
});

test("a short phrase is still allowed (the bound rejects sentences, not phrases)", async () => {
  const out = await save({ surfaceUnit: "out of the blue" });
  expect(out.status).toBe("created");
});

test("server-authoritative dedup key: 'Running' → lowercased deterministic key (no lemmatization)", async () => {
  const a = await save({ surfaceUnit: "Running" });
  expect(a.status).toBe("created");
  if (a.status !== "created") return; // narrow the union
  // dedupKey lowercases + trims; it does NOT lemmatize — 'running' stays 'running', never 'run' (T21).
  expect(a.word.normalized_unit).toBe("running");
  expect(a.word.surface_unit).toBe("Running");
  expect(a.word.target_language).toBe("en");
  expect(a.word.explanation_state).toBe("pending");
  expect(a.word.fsrs_epoch).toBe(0);
});

test("no lemmatization: inflections are DISTINCT words at the save level ('studied' ≠ 'study', T21)", async () => {
  const a = await save({ surfaceUnit: "study" });
  const b = await save({ surfaceUnit: "studied" });
  expect(a.status).toBe("created");
  expect(b.status).toBe("created"); // 'studied' is a NEW row, not a dedup onto 'study'
  if (a.status !== "created" || b.status !== "created") return;
  expect(a.word.normalized_unit).toBe("study");
  expect(b.word.normalized_unit).toBe("studied");
  expect(a.word.id).not.toBe(b.word.id); // two cards, one per inflection — the accepted T21 trade
});

test("dedup is per (user, target_language, normalized_unit): same string, different target = distinct", async () => {
  await save({ surfaceUnit: "pain", targetLanguage: "en" });
  const fr = await save({ surfaceUnit: "pain", targetLanguage: "fr" });
  expect(fr.status).toBe("created");
  expect(await listWords(sql, "u1")).toHaveLength(2);
});

test("dedup is per-user: two users saving the same unit get distinct rows", async () => {
  await save({ userId: "u1", surfaceUnit: "apple" });
  const other = await save({ userId: "u2", surfaceUnit: "apple" });
  expect(other.status).toBe("created");
  expect(await listWords(sql, "u1")).toHaveLength(1);
  expect(await listWords(sql, "u2")).toHaveLength(1);
});

test("resurrect-on-resave: a resave onto a TOMBSTONE revives the row and bumps fsrs_epoch", async () => {
  const a = await save();
  const id = a.status === "created" ? a.word.id : "";
  expect(await softDeleteWord(sql, "u1", id, 2000)).toBe(true);
  expect(await listWords(sql, "u1")).toHaveLength(0); // tombstoned

  const r = await save({ now: 3000 });
  expect(r.status).toBe("resurrected");
  if (r.status === "resurrected") {
    expect(r.word.id).toBe(id); // same row, not a new one
    expect(r.word.fsrs_epoch).toBe(1); // FSRS reset to new-card
    expect(r.word.deleted_at).toBeNull();
  }
  expect(await listWords(sql, "u1")).toHaveLength(1);
});

test("resurrect is idempotent: a second resurrect-path call falls through to dedup (epoch bumps once)", async () => {
  const a = await save();
  const id = a.status === "created" ? a.word.id : "";
  await softDeleteWord(sql, "u1", id, 2000);
  const r1 = await save({ now: 3000 });
  const r2 = await save({ now: 4000 });
  expect(r1.status).toBe("resurrected");
  expect(r2.status).toBe("deduped");
  const w = await getWordById(sql, "u1", id);
  expect(w?.fsrs_epoch).toBe(1); // not 2
});

test("rejects an invalid target language and an empty/punctuation-only unit", async () => {
  expect((await save({ targetLanguage: "not a tag!!" })).status).toBe("invalid_target_language");
  expect((await save({ surfaceUnit: "   " })).status).toBe("empty_unit");
  expect((await save({ surfaceUnit: "!!!" })).status).toBe("empty_unit");
});

test("soft-delete only affects the owner's live row", async () => {
  const a = await save();
  const id = a.status === "created" ? a.word.id : "";
  expect(await softDeleteWord(sql, "u2", id, 2000)).toBe(false); // not the owner
  expect(await softDeleteWord(sql, "u1", id, 2000)).toBe(true);
  expect(await softDeleteWord(sql, "u1", id, 2000)).toBe(false); // already tombstoned
});

test("markExplanationReady stores the cache-key pointer + flips state", async () => {
  const a = await save();
  const id = a.status === "created" ? a.word.id : "";
  await markExplanationReady(sql, "u1", id, "explain/word/en/en/v1/v1/running", 5000);
  const w = await getWordById(sql, "u1", id);
  expect(w?.explanation_state).toBe("ready");
  expect(w?.explanation_cache_key).toBe("explain/word/en/en/v1/v1/running");
});

// --- restoreWord (POST /words/:id/restore) -----------------------------------

test("restoreWord un-deletes a tombstone, PRESERVING fsrs_epoch (unlike resurrect-on-resave)", async () => {
  const a = await save();
  const id = a.status === "created" ? a.word.id : "";
  expect(await softDeleteWord(sql, "u1", id, 2000)).toBe(true);
  expect(await listWords(sql, "u1")).toHaveLength(0);

  expect(await restoreWord(sql, "u1", id, 3000)).toBe(true);
  const rows = await listWords(sql, "u1");
  expect(rows).toHaveLength(1);
  expect(rows[0]!.id).toBe(id); // same row reappears
  const w = await getWordById(sql, "u1", id);
  expect(w?.deleted_at).toBeNull();
  expect(w?.fsrs_epoch).toBe(0); // NOT bumped — restore resumes the card; a resave would reset to new (epoch 1)
});

test("restoreWord returns false for an active row, a missing id, and another user's tombstone", async () => {
  const a = await save();
  const id = a.status === "created" ? a.word.id : "";
  expect(await restoreWord(sql, "u1", id, 3000)).toBe(false); // already active
  expect(await restoreWord(sql, "u1", "no-such-id", 3000)).toBe(false); // missing
  await softDeleteWord(sql, "u1", id, 2000);
  expect(await restoreWord(sql, "u2", id, 3000)).toBe(false); // not the owner
  expect(await restoreWord(sql, "u1", id, 3000)).toBe(true); // owner can
});

// --- listWords FSRS exposure (the Word Book memory meter) --------------------

test("listWords surfaces the FSRS projection at the unit's epoch; null for a never-reviewed card", async () => {
  const a = await save();
  const id = a.status === "created" ? a.word.id : "";

  // A new card has no fsrs_cards row → fsrs is null (the meter renders "not yet scheduled").
  let rows = await listWords(sql, "u1");
  expect(rows[0]!.fsrs).toBeNull();

  // Seed a projection at the matching epoch (0) → it's exposed.
  await sql
    .prepare(
      `INSERT INTO fsrs_cards (word_id, user_id, card_epoch, stability, difficulty, due_at, last_review_at, reps, lapses, state, last_applied_seq)
       VALUES (?, 'u1', 0, 12.5, 5.0, 9999, 8000, 3, 1, 'review', 1)`,
    )
    .bind(id)
    .run();
  rows = await listWords(sql, "u1");
  expect(rows[0]!.fsrs).not.toBeNull();
  expect(rows[0]!.fsrs!.stability).toBe(12.5);
  expect(rows[0]!.fsrs!.due_at).toBe(9999);
  expect(rows[0]!.fsrs!.state).toBe("review");
  expect(rows[0]!.fsrs!.reps).toBe(3);
  expect(rows[0]!.fsrs!.lapses).toBe(1);
});

test("listWords HIDES a stale FSRS projection (card_epoch != the unit's current fsrs_epoch)", async () => {
  const a = await save();
  const id = a.status === "created" ? a.word.id : "";
  // A projection from BEFORE a resurrect (epoch 0)...
  await sql
    .prepare(
      `INSERT INTO fsrs_cards (word_id, user_id, card_epoch, stability, difficulty, due_at, reps, lapses, state, last_applied_seq)
       VALUES (?, 'u1', 0, 20, 5, 1, 2, 0, 'review', 1)`,
    )
    .bind(id)
    .run();
  await softDeleteWord(sql, "u1", id, 2000);
  await save({ now: 3000 }); // resurrect → fsrs_epoch becomes 1

  const rows = await listWords(sql, "u1");
  expect(rows).toHaveLength(1);
  expect(rows[0]!.fsrs).toBeNull(); // the epoch-0 projection is stale → read as a fresh new card
});

// --- free saved-word cap (the Pro lever) -------------------------------------

test("free cap: a net-new save past N returns cap_reached and stores nothing new", async () => {
  expect((await save({ surfaceUnit: "alpha", freeWordCap: 2 })).status).toBe("created");
  expect((await save({ surfaceUnit: "beta", freeWordCap: 2 })).status).toBe("created");
  const blocked = await save({ surfaceUnit: "gamma", freeWordCap: 2 });
  expect(blocked.status).toBe("cap_reached");
  expect(await listWords(sql, "u1")).toHaveLength(2); // gamma not stored; existing words untouched
});

test("free cap is EXEMPT for dedup: re-saving an existing active word at the cap still dedups", async () => {
  await save({ surfaceUnit: "alpha", freeWordCap: 1 });
  const again = await save({ surfaceUnit: "alpha", freeWordCap: 1 }); // existing row, not a net-new insert
  expect(again.status).toBe("deduped");
});

test("free cap is EXEMPT for resurrect: re-saving a tombstoned word at the cap resurrects it (count can exceed N)", async () => {
  const a = await save({ surfaceUnit: "alpha", freeWordCap: 5 });
  const id = a.status === "created" ? a.word.id : "";
  await softDeleteWord(sql, "u1", id, 2000); // alpha → tombstone (0 active)
  expect((await save({ surfaceUnit: "beta", freeWordCap: 1, now: 2500 })).status).toBe("created"); // active = 1 = cap
  const res = await save({ surfaceUnit: "alpha", freeWordCap: 1, now: 3000 }); // at cap, but alpha is a tombstone
  expect(res.status).toBe("resurrected");
  expect(await listWords(sql, "u1")).toHaveLength(2); // beta + resurrected alpha — exceeds cap via the exemption
});

test("Pro bypasses the cap: with pro_until in the future, net-new saves past N still create", async () => {
  await sql.prepare(`UPDATE accounts SET pro_until = ? WHERE id = 'u1'`).bind(9_000_000).run();
  expect((await save({ surfaceUnit: "alpha", freeWordCap: 1, now: 1000 })).status).toBe("created");
  expect((await save({ surfaceUnit: "beta", freeWordCap: 1, now: 1000 })).status).toBe("created"); // would be capped if free
  expect(await listWords(sql, "u1")).toHaveLength(2);
});

test("an EXPIRED Pro (pro_until in the past) does NOT bypass the cap", async () => {
  await sql.prepare(`UPDATE accounts SET pro_until = ? WHERE id = 'u1'`).bind(500).run(); // past horizon
  expect((await save({ surfaceUnit: "alpha", freeWordCap: 1, now: 1000 })).status).toBe("created");
  expect((await save({ surfaceUnit: "beta", freeWordCap: 1, now: 1000 })).status).toBe("cap_reached");
});

test("the cap is per-account: u1 at its cap does not block u2", async () => {
  expect((await save({ userId: "u1", surfaceUnit: "alpha", freeWordCap: 1 })).status).toBe("created");
  expect((await save({ userId: "u1", surfaceUnit: "beta", freeWordCap: 1 })).status).toBe("cap_reached");
  expect((await save({ userId: "u2", surfaceUnit: "alpha", freeWordCap: 1 })).status).toBe("created");
});

test("no configured cap ⇒ unlimited (the fail-open default for callers that omit it)", async () => {
  for (let i = 0; i < 5; i++) {
    expect((await save({ surfaceUnit: `word${i}`, now: 1000 + i })).status).toBe("created");
  }
  expect(await listWords(sql, "u1")).toHaveLength(5);
});
