import { test, expect, beforeEach } from "bun:test";
import { freshDb, ids, seedAccount } from "./helpers/db.ts";
import { testCrypto } from "./helpers/crypto.ts";
import { claimRows, type ClaimRowInput } from "../src/claim.ts";
import { saveWord, softDeleteWord, getWordById, listWords } from "../src/words.ts";
import { listContextsForWord, createContext } from "../src/contexts.ts";
import { ingestReview } from "../src/review.ts";
import type { Sql } from "../src/sql.ts";
import type { EnvelopeCrypto } from "../src/crypto.ts";

let sql: Sql;
let crypto: EnvelopeCrypto;
let newId: () => string;

const claim = (rows: ClaimRowInput[], installId = "i1", now = 1000) =>
  claimRows(sql, crypto, { userId: "u1", installId, rows, now, newId });

async function claimRecordCount(): Promise<number> {
  const r = await sql.prepare(`SELECT COUNT(*) AS n FROM claim_records`).first<{ n: number }>();
  return Number(r?.n ?? 0);
}

beforeEach(async () => {
  ({ sql } = freshDb());
  crypto = await testCrypto();
  newId = ids("k");
  await seedAccount(sql, "u1");
});

test("claims a new unit (+ encrypted context) and writes one claim-record", async () => {
  const [r] = await claim([
    { clientRowId: "row-1", surfaceUnit: "serendipity", targetLanguage: "en", context: { text: "a serendipity of events" } },
  ]);
  expect(r!.status).toBe("created");
  expect(r!.contextStored).toBe(true);
  expect(await listWords(sql, "u1")).toHaveLength(1);
  const ctx = await listContextsForWord(sql, crypto, "u1", r!.wordId!);
  expect(ctx[0]!.contextText).toBe("a serendipity of events"); // decrypts back
  expect(await claimRecordCount()).toBe(1);
});

test("claim carries capture-source metadata into the stored context (title encrypted, app/lang plaintext)", async () => {
  const [r] = await claim([
    {
      clientRowId: "row-1",
      surfaceUnit: "serendipity",
      targetLanguage: "en",
      context: {
        text: "a serendipity of events",
        sourceApp: "Books",
        sourceTitle: "Chapter 3 — my reading list",
        detectedLanguage: "en",
        detectedLanguageConfidence: 0.88,
      },
    },
  ]);
  expect(r!.status).toBe("created");
  expect(r!.contextStored).toBe(true);
  const ctx = (await listContextsForWord(sql, crypto, "u1", r!.wordId!))[0]!;
  expect(ctx.sourceApp).toBe("Books");
  expect(ctx.sourceTitle).toBe("Chapter 3 — my reading list"); // decrypts back
  expect(ctx.detectedLanguage).toBe("en");
  expect(ctx.detectedLanguageConfidence).toBe(0.88);
});

test("re-claiming the same (install, client_row_id) is an idempotent no-op", async () => {
  const first = await claim([{ clientRowId: "row-1", surfaceUnit: "ephemeral", targetLanguage: "en", context: { text: "an ephemeral moment" } }]);
  const retry = await claim([{ clientRowId: "row-1", surfaceUnit: "ephemeral", targetLanguage: "en", context: { text: "an ephemeral moment" } }]);
  expect(retry[0]!.status).toBe("replayed");
  expect(retry[0]!.wordId).toBe(first[0]!.wordId);
  expect(await listWords(sql, "u1")).toHaveLength(1); // no duplicate unit
  expect(await listContextsForWord(sql, crypto, "u1", first[0]!.wordId!)).toHaveLength(1); // no duplicate context
  expect(await claimRecordCount()).toBe(1);
});

test("active+active collision: claim onto an existing live unit DEDUPS (FSRS untouched) and ADDS the context (1:N)", async () => {
  const w = await saveWord(sql, { userId: "u1", surfaceUnit: "slide", targetLanguage: "en", now: 1, newId });
  const wid = w.status === "created" ? w.word.id : "";
  await ingestReview(sql, { userId: "u1", wordId: wid, eventId: "ev", rating: 3, clientReviewTs: 10, now: 10 }); // give it FSRS state

  const [r] = await claim([{ clientRowId: "row-1", surfaceUnit: "slide", targetLanguage: "en", context: { text: "down the slide" } }]);
  expect(r!.status).toBe("deduped");
  expect(r!.wordId).toBe(wid);
  expect((await getWordById(sql, "u1", wid))?.fsrs_epoch).toBe(0); // FSRS untouched (no resurrect)
  const card = await sql.prepare(`SELECT reps FROM fsrs_cards WHERE word_id = ?`).bind(wid).first<{ reps: number }>();
  expect(card?.reps).toBe(1); // existing card survives
  expect(await listContextsForWord(sql, crypto, "u1", wid)).toHaveLength(1); // context merged in
});

test("claim onto a TOMBSTONE resurrects: clears the delete, resets FSRS (epoch++), preserves contexts", async () => {
  const w = await saveWord(sql, { userId: "u1", surfaceUnit: "cleave", targetLanguage: "en", now: 1, newId });
  const wid = w.status === "created" ? w.word.id : "";
  await createContext(sql, crypto, { userId: "u1", wordId: wid, contextText: "cleave the wood", now: 2, newId }); // pre-existing context
  await softDeleteWord(sql, "u1", wid, 3);

  const [r] = await claim([{ clientRowId: "row-1", surfaceUnit: "cleave", targetLanguage: "en", context: { text: "cleave together" } }]);
  expect(r!.status).toBe("resurrected");
  const word = await getWordById(sql, "u1", wid);
  expect(word?.deleted_at).toBeNull(); // un-tombstoned
  expect(word?.fsrs_epoch).toBe(1); // FSRS reset to new-card
  expect(await listContextsForWord(sql, crypto, "u1", wid)).toHaveLength(2); // old preserved + new merged
});

test("a partial-failure retry (claim-record missing) re-claims without duplicating the context or resurrecting", async () => {
  const first = await claim([{ clientRowId: "row-1", surfaceUnit: "limpid", targetLanguage: "en", context: { text: "a limpid pool" } }]);
  const wid = first[0]!.wordId!;
  // simulate the claim-record never landing (crash after word+context, before the marker)
  await sql.prepare(`DELETE FROM claim_records WHERE client_row_id = ?`).bind("row-1").run();

  const retry = await claim([{ clientRowId: "row-1", surfaceUnit: "limpid", targetLanguage: "en", context: { text: "a limpid pool" } }]);
  expect(retry[0]!.status).toBe("deduped"); // word already active → not resurrected
  expect(retry[0]!.wordId).toBe(wid);
  expect(await listContextsForWord(sql, crypto, "u1", wid)).toHaveLength(1); // deterministic id ⇒ no duplicate
  expect(await claimRecordCount()).toBe(1); // marker re-written
});

test("the same client_row_id under a DIFFERENT install is a separate claim (install-scoped, eng-review C6)", async () => {
  await claim([{ clientRowId: "row-1", surfaceUnit: "alpha", targetLanguage: "en" }], "install-A");
  const second = await claim([{ clientRowId: "row-1", surfaceUnit: "beta", targetLanguage: "en" }], "install-B");
  expect(second[0]!.status).toBe("created"); // NOT a replay — different install
  expect(await claimRecordCount()).toBe(2);
  expect(await listWords(sql, "u1")).toHaveLength(2);
});

test("a row with a bad target is rejected and NOT claimed (the client keeps it to fix/resend)", async () => {
  const [r] = await claim([{ clientRowId: "row-1", surfaceUnit: "hello", targetLanguage: "" }]);
  expect(r!.status).toBe("invalid_target_language");
  expect(r!.wordId).toBeUndefined();
  expect(await claimRecordCount()).toBe(0); // no marker → resendable
});

test("context ids are collision-safe across ':'-containing components [review-fix: Codex P2]", async () => {
  // Under a naive `claim:<install>:<rowid>` scheme these two collide (both "claim:a:b:c")
  // and the second context would be silently dropped. Percent-encoding keeps them distinct.
  const [r1] = await claim([{ clientRowId: "c", surfaceUnit: "one", targetLanguage: "en", context: { text: "ctx-one" } }], "a:b");
  const [r2] = await claim([{ clientRowId: "b:c", surfaceUnit: "two", targetLanguage: "en", context: { text: "ctx-two" } }], "a");
  expect(r1!.contextStored).toBe(true);
  expect(r2!.contextStored).toBe(true);
  expect((await listContextsForWord(sql, crypto, "u1", r1!.wordId!))[0]!.contextText).toBe("ctx-one");
  expect((await listContextsForWord(sql, crypto, "u1", r2!.wordId!))[0]!.contextText).toBe("ctx-two"); // not dropped
});

test("context ids are cross-tenant safe (same install+row under two accounts don't collide) [review-fix]", async () => {
  await seedAccount(sql, "u2");
  const [a] = await claimRows(sql, crypto, { userId: "u1", installId: "i", rows: [{ clientRowId: "r", surfaceUnit: "shared", targetLanguage: "en", context: { text: "u1-secret" } }], now: 1, newId });
  const [b] = await claimRows(sql, crypto, { userId: "u2", installId: "i", rows: [{ clientRowId: "r", surfaceUnit: "shared", targetLanguage: "en", context: { text: "u2-secret" } }], now: 1, newId });
  expect((await listContextsForWord(sql, crypto, "u1", a!.wordId!))[0]!.contextText).toBe("u1-secret");
  expect((await listContextsForWord(sql, crypto, "u2", b!.wordId!))[0]!.contextText).toBe("u2-secret"); // u2's context not lost to a PK collision
});

test("a malformed captured span is dropped (context kept, no highlight) — never a 500 [review-fix: Codex P2]", async () => {
  const [r] = await claim([
    { clientRowId: "r", surfaceUnit: "slide", targetLanguage: "en", context: { text: "down the slide", spanStart: 10, spanEnd: 5 } }, // inverted span
  ]);
  expect(r!.status).toBe("created");
  expect(r!.contextStored).toBe(true); // context preserved
  const ctx = await listContextsForWord(sql, crypto, "u1", r!.wordId!);
  expect(ctx[0]!.contextText).toBe("down the slide");
  expect(ctx[0]!.spanStart).toBeNull(); // bad span normalized away
  expect(ctx[0]!.spanEnd).toBeNull();
});

test("a row whose unit is a whole sentence is rejected as unit_too_large", async () => {
  const [r] = await claim([
    { clientRowId: "row-1", surfaceUnit: "this is clearly a whole sentence and not a single vocabulary unit at all", targetLanguage: "en" },
  ]);
  expect(r!.status).toBe("unit_too_large");
  expect(await claimRecordCount()).toBe(0);
});
