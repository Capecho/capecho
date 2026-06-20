import { test, expect, beforeEach } from "bun:test";
import { freshDb, ids, seedAccount } from "./helpers/db.ts";
import { testCrypto } from "./helpers/crypto.ts";
import { saveWord } from "../src/words.ts";
import { createContext, listContextsForWord } from "../src/contexts.ts";
import { claimRows } from "../src/claim.ts";
import { countLiveReservations } from "../src/quota.ts";
import { BudgetLedger, MemoryBudgetStore } from "../src/budget-logic.ts";
import { MockContextProvider } from "../src/providers/mock-context.ts";
import {
  explainContextPreview,
  adoptPreview,
  sweepExpiredPreviews,
  type ContextPreviewDeps,
  type ContextPreviewRequest,
  type ContextPreviewObservation,
} from "../src/context-preview.ts";
import { DEFAULT_COST_CONFIG } from "../src/config.ts";
import type { Sql } from "../src/sql.ts";
import type { EnvelopeCrypto } from "../src/crypto.ts";
import type { ContextGenerateResult } from "../src/context-provider.ts";

// E2 — the ephemeral context-explanation PREVIEW: meter-once on raw (word, sentence), store
// transiently, adopt onto the saved context with no recharge, dismiss = TTL-expire.

const DAY = "2026-05-27";
const SENTENCE = "The cell divides rapidly.";

let sql: Sql;
let crypto: EnvelopeCrypto; // ONE instance threaded through preview + save + adopt (decrypt must match)
let newId: () => string;

beforeEach(async () => {
  ({ sql } = freshDb());
  newId = ids("p");
  crypto = await testCrypto();
  await seedAccount(sql, "u1");
});

function deps(over: Partial<ContextPreviewDeps> = {}): ContextPreviewDeps & { provider: MockContextProvider; budget: BudgetLedger } {
  const provider = (over.provider as MockContextProvider) ?? new MockContextProvider();
  const budget = (over.budget as BudgetLedger) ?? new BudgetLedger(new MemoryBudgetStore());
  return {
    sql,
    crypto,
    provider,
    budget,
    config: DEFAULT_COST_CONFIG,
    now: () => 1000,
    newId,
    ...over,
  } as ContextPreviewDeps & { provider: MockContextProvider; budget: BudgetLedger };
}

const req = (over: Partial<ContextPreviewRequest> = {}): ContextPreviewRequest => ({
  userId: "u1",
  surfaceUnit: "cell",
  targetLanguage: "en",
  contextText: SENTENCE,
  explanationLanguage: "en",
  quotaDay: DAY,
  budgetDayKey: DAY,
  cost: 1,
  ...over,
});

/** Create the saved word + context (under the shared crypto) the adoption tests attach onto. */
async function saveContext(sentence: string): Promise<{ wordId: string; ctxId: string }> {
  const w = await saveWord(sql, { userId: "u1", surfaceUnit: "cell", targetLanguage: "en", now: 1, newId });
  const wordId = w.status === "created" || w.status === "deduped" ? w.word.id : "";
  const out = await createContext(sql, crypto, { userId: "u1", wordId, contextText: sentence, now: 2, newId });
  return { wordId, ctxId: out.status === "created" ? out.id : "" };
}

test("generates, meters once, stores, and returns a handle", async () => {
  const d = deps();
  const r = await explainContextPreview(d, req());
  expect(r.status).toBe("ready");
  if (r.status === "ready") {
    expect(r.previewHandle.length).toBeGreaterThan(0);
    expect(r.charged).toBe(true);
    expect(r.meaning.length).toBeGreaterThan(0);
  }
  expect(await countLiveReservations(sql, "u1", DAY, 1000)).toBe(1); // one slot spent
});

test("shares the daily cap with the saved context layer (one 10/day pool)", async () => {
  const d = deps({ config: { ...DEFAULT_COST_CONFIG, contextDailyCap: 1 } });
  expect((await explainContextPreview(d, req())).status).toBe("ready");
  const second = await explainContextPreview(d, req({ surfaceUnit: "atom", contextText: "An atom is tiny." }));
  expect(second.status).toBe("quota_exhausted"); // the 2nd preview exceeds the shared cap of 1
});

test("Pro bypasses the shared cap: isPro=true previews past the limit", async () => {
  const d = deps({ config: { ...DEFAULT_COST_CONFIG, contextDailyCap: 1 } });
  expect((await explainContextPreview(d, req({ isPro: true }))).status).toBe("ready");
  // For a free user this 2nd preview is quota_exhausted; Pro has no cap.
  const second = await explainContextPreview(d, req({ surfaceUnit: "atom", contextText: "An atom is tiny.", isPro: true }));
  expect(second.status).toBe("ready");
});

test("budget fail-closed refunds the per-user slot (not consumed)", async () => {
  const budget = new BudgetLedger(new MemoryBudgetStore());
  await budget.reserve(DAY, DEFAULT_COST_CONFIG.globalDailyBudgetUnits, DEFAULT_COST_CONFIG.globalDailyBudgetUnits);
  const d = deps({ budget });
  expect((await explainContextPreview(d, req())).status).toBe("budget_exhausted");
  expect(await countLiveReservations(sql, "u1", DAY, 1000)).toBe(0); // slot refunded
});

test("a provider transport error refunds BOTH the slot and the budget (no spend)", async () => {
  const provider = new MockContextProvider(() => {
    throw new Error("timeout");
  });
  const budget = new BudgetLedger(new MemoryBudgetStore());
  const d = deps({ provider, budget });
  const r = await explainContextPreview(d, req());
  expect(r.status).toBe("failed");
  expect(await countLiveReservations(sql, "u1", DAY, 1000)).toBe(0);
  expect(await budget.spent(DAY)).toBe(0);
});

test("a rejected (refusal) generation refunds the slot; global spend stands", async () => {
  const provider = new MockContextProvider(
    (): ContextGenerateResult => ({ raw: { meaning: "As an AI I cannot help." } }),
  );
  const budget = new BudgetLedger(new MemoryBudgetStore());
  const d = deps({ provider, budget });
  const r = await explainContextPreview(d, req());
  expect(r.status).toBe("failed");
  expect(await countLiveReservations(sql, "u1", DAY, 1000)).toBe(0); // not charged for a non-answer
  expect(await budget.spent(DAY)).toBe(1); // the model was paid
});

test("validates the raw input (invalid unit / empty / oversized context)", async () => {
  expect((await explainContextPreview(deps(), req({ surfaceUnit: "   " }))).status).toBe("invalid_unit");
  expect(
    (await explainContextPreview(deps(), req({ surfaceUnit: "this is a whole sentence not a word to look up here" }))).status,
  ).toBe("invalid_unit");
  expect((await explainContextPreview(deps(), req({ contextText: "   " }))).status).toBe("empty_context");
  expect((await explainContextPreview(deps(), req({ contextText: "x".repeat(2001) }))).status).toBe("context_too_large");
});

test("Save adopts the preview's gloss onto the new context — NO recharge", async () => {
  const d = deps();
  const preview = await explainContextPreview(d, req());
  const handle = preview.status === "ready" ? preview.previewHandle : "";
  const m = preview.status === "ready" ? preview.meaning : "";

  const { wordId, ctxId } = await saveContext(SENTENCE);
  const adopted = await adoptPreview(sql, crypto, { userId: "u1", previewHandle: handle, contextId: ctxId, now: 3 });
  expect(adopted).toBe(true);

  const contexts = await listContextsForWord(sql, crypto, "u1", wordId);
  expect(contexts[0]!.meaning).toBe(m); // the adopted gloss is now on the saved context
  expect(await countLiveReservations(sql, "u1", DAY, 1000)).toBe(1); // still just the ONE preview charge
});

test("adoption refuses a gloss generated for a DIFFERENT sentence", async () => {
  const d = deps();
  const preview = await explainContextPreview(d, req());
  const handle = preview.status === "ready" ? preview.previewHandle : "";
  const { wordId, ctxId } = await saveContext("A prison cell is small."); // different sentence
  expect(await adoptPreview(sql, crypto, { userId: "u1", previewHandle: handle, contextId: ctxId, now: 3 })).toBe(false);
  const contexts = await listContextsForWord(sql, crypto, "u1", wordId);
  expect(contexts[0]!.meaning).toBeNull(); // not adopted
});

test("adoption is idempotent — a second adopt is a no-op", async () => {
  const d = deps();
  const preview = await explainContextPreview(d, req());
  const handle = preview.status === "ready" ? preview.previewHandle : "";
  const { ctxId } = await saveContext(SENTENCE);
  expect(await adoptPreview(sql, crypto, { userId: "u1", previewHandle: handle, contextId: ctxId, now: 3 })).toBe(true);
  expect(await adoptPreview(sql, crypto, { userId: "u1", previewHandle: handle, contextId: ctxId, now: 4 })).toBe(false);
});

test("a preview is owner-scoped — another user cannot adopt it", async () => {
  await seedAccount(sql, "u2");
  const preview = await explainContextPreview(deps(), req());
  const handle = preview.status === "ready" ? preview.previewHandle : "";
  // u2 saves their own context with the same sentence and tries to adopt u1's handle.
  const w = await saveWord(sql, { userId: "u2", surfaceUnit: "cell", targetLanguage: "en", now: 1, newId });
  const wordId = w.status === "created" || w.status === "deduped" ? w.word.id : "";
  const out = await createContext(sql, crypto, { userId: "u2", wordId, contextText: SENTENCE, now: 2, newId });
  const ctxId = out.status === "created" ? out.id : "";
  expect(await adoptPreview(sql, crypto, { userId: "u2", previewHandle: handle, contextId: ctxId, now: 3 })).toBe(false);
});

test("dismiss = TTL-expire: the sweep deletes an expired preview, keeps a live one", async () => {
  const d = deps({ config: { ...DEFAULT_COST_CONFIG, previewTtlMs: 100 }, now: () => 1000 });
  await explainContextPreview(d, req()); // expires_at = 1000 + 100 = 1100
  expect(await sweepExpiredPreviews(sql, 1050)).toBe(0); // not yet expired
  expect(await sweepExpiredPreviews(sql, 1200)).toBe(1); // expired → deleted
});

test("adoption refuses an EXPIRED preview even before the sweep runs (TTL enforced at read time)", async () => {
  // The sweep cron runs only once a day, so an expired row can linger ~hours. Adoption must enforce
  // the TTL itself — otherwise a preview saved long after its 30-min window would silently adopt a
  // stale gloss. Shrink the TTL so a realistic test `now` outlives it.
  const d = deps({ config: { ...DEFAULT_COST_CONFIG, previewTtlMs: 100 }, now: () => 1000 });
  const preview = await explainContextPreview(d, req()); // expires_at = 1100
  const handle = preview.status === "ready" ? preview.previewHandle : "";
  const { wordId, ctxId } = await saveContext(SENTENCE);
  // now (5000) is past expires_at (1100); the row is NOT swept yet — adoption must still refuse it.
  expect(await adoptPreview(sql, crypto, { userId: "u1", previewHandle: handle, contextId: ctxId, now: 5000 })).toBe(false);
  const contexts = await listContextsForWord(sql, crypto, "u1", wordId);
  expect(contexts[0]!.meaning).toBeNull(); // the expired gloss was NOT adopted
});

// The macOS overlay's "Explain in this sentence" Save lands through the pre-login CLAIM path, not the
// direct adoptPreview call above — the word + context are created server-side by claimRows, which then
// adopts the carried handle onto that just-created context. These cover that wiring end-to-end.

test("claim adopts a carried preview handle onto the claimed context (overlay Save path — no recharge)", async () => {
  const d = deps();
  const preview = await explainContextPreview(d, req());
  const handle = preview.status === "ready" ? preview.previewHandle : "";
  const m = preview.status === "ready" ? preview.meaning : "";
  expect(handle.length).toBeGreaterThan(0);

  // Save → immediate auto-claim carries the SAME sentence + the preview handle.
  const [r] = await claimRows(sql, crypto, {
    userId: "u1",
    installId: "i1",
    rows: [{ clientRowId: "row-1", surfaceUnit: "cell", targetLanguage: "en", context: { text: SENTENCE, previewHandle: handle } }],
    now: 1001,
    newId,
  });
  expect(r!.status).toBe("created");
  expect(r!.glossAdopted).toBe(true);
  const contexts = await listContextsForWord(sql, crypto, "u1", r!.wordId!);
  expect(contexts[0]!.meaning).toBe(m); // the paid gloss is persisted on the claimed context
  expect(await countLiveReservations(sql, "u1", DAY, 1000)).toBe(1); // still the ONE preview charge — no recharge
});

test("claim WITHOUT a preview handle stores the context but adopts nothing (backlog rows)", async () => {
  const [r] = await claimRows(sql, crypto, {
    userId: "u1",
    installId: "i1",
    rows: [{ clientRowId: "row-1", surfaceUnit: "cell", targetLanguage: "en", context: { text: SENTENCE } }],
    now: 1001,
    newId,
  });
  expect(r!.status).toBe("created");
  expect(r!.glossAdopted).toBeUndefined(); // no handle carried → adopt never attempted/reported
  expect((await listContextsForWord(sql, crypto, "u1", r!.wordId!))[0]!.meaning).toBeNull();
});

test("claim with a stale/foreign preview handle doesn't adopt — falls back to re-explain (no error)", async () => {
  const [r] = await claimRows(sql, crypto, {
    userId: "u1",
    installId: "i1",
    rows: [
      { clientRowId: "row-1", surfaceUnit: "cell", targetLanguage: "en", context: { text: SENTENCE, previewHandle: "does-not-exist" } },
    ],
    now: 1001,
    newId,
  });
  expect(r!.status).toBe("created");
  expect(r!.glossAdopted).toBe(false); // handle present but invalid → reported false, not adopted
  expect((await listContextsForWord(sql, crypto, "u1", r!.wordId!))[0]!.meaning).toBeNull();
});

test("claim adopts onto a DEDUPED context when the word is already in the book (1:N, no recharge)", async () => {
  // Word already active in the account → a claim of the same unit DEDUPS, but the new sentence context
  // is still created (1:N) and the preview gloss adopts onto THAT context.
  await saveWord(sql, { userId: "u1", surfaceUnit: "cell", targetLanguage: "en", now: 1, newId });
  const preview = await explainContextPreview(deps(), req());
  const handle = preview.status === "ready" ? preview.previewHandle : "";
  const [r] = await claimRows(sql, crypto, {
    userId: "u1",
    installId: "i1",
    rows: [{ clientRowId: "row-1", surfaceUnit: "cell", targetLanguage: "en", context: { text: SENTENCE, previewHandle: handle } }],
    now: 1001,
    newId,
  });
  expect(r!.status).toBe("deduped"); // the word already existed
  expect(r!.glossAdopted).toBe(true);
  const contexts = await listContextsForWord(sql, crypto, "u1", r!.wordId!);
  expect(contexts.some((c) => c.meaning !== null)).toBe(true); // the paid gloss landed on the new context
});

test("adoption refuses a handle whose previewed UNIT differs from the context's word (same sentence)", async () => {
  // Preview is for "cell"; the target context belongs to a DIFFERENT word ("atom") in the SAME sentence.
  // the meaning is unit-specific, so adoption must refuse even though owner + sentence + TTL all pass.
  const preview = await explainContextPreview(deps(), req()); // unit "cell"
  const handle = preview.status === "ready" ? preview.previewHandle : "";
  const w = await saveWord(sql, { userId: "u1", surfaceUnit: "atom", targetLanguage: "en", now: 1, newId });
  const wordId = w.status === "created" ? w.word.id : "";
  const out = await createContext(sql, crypto, { userId: "u1", wordId, contextText: SENTENCE, now: 2, newId });
  const ctxId = out.status === "created" ? out.id : "";
  expect(await adoptPreview(sql, crypto, { userId: "u1", previewHandle: handle, contextId: ctxId, now: 3 })).toBe(false);
  expect((await listContextsForWord(sql, crypto, "u1", wordId))[0]!.meaning).toBeNull(); // not adopted
});

test("the provider receives the axes VERBATIM — contextLanguage NEVER defaults to the target", async () => {
  // Guards this PR's headline invariant at its historical bug location: the generate() call site
  // used to read `req.contextLanguage ?? req.targetLanguage`. Reintroducing any default would pass
  // the type checker (string is assignable to string|null) and every other test.
  const d = deps();
  await explainContextPreview(d, req({ spanStart: 4, spanEnd: 8 })); // no ctxLang sent
  expect(d.provider.lastRequest).toMatchObject({
    unit: "cell",
    targetLanguage: "en",
    contextLanguage: null, // NOT "en"
    spanStart: 4,
    spanEnd: 8,
  });
  // A sent value arrives canonicalized; junk degrades to unknown — never a wrong label.
  await explainContextPreview(d, req({ surfaceUnit: "atom", contextText: "An atom is tiny.", contextLanguage: "EN" }));
  expect(d.provider.lastRequest?.contextLanguage).toBe("en");
  await explainContextPreview(d, req({ surfaceUnit: "gene", contextText: "A gene is code.", contextLanguage: "not a tag!!" }));
  expect(d.provider.lastRequest?.contextLanguage).toBeNull();
});

test("the reservation fingerprint covers EVERY answer-changing axis (span / context language / target)", async () => {
  const d = deps();
  // "The cell divides rapidly." → "cell" sits at UTF-16 [4, 8).
  expect((await explainContextPreview(d, req({ idempotencyKey: "tap-1", spanStart: 4, spanEnd: 8 }))).status).toBe("ready");

  // The SAME tap retried verbatim is recognized as a replay of the live key — never a mismatch.
  const replay = await explainContextPreview(d, req({ idempotencyKey: "tap-1", spanStart: 4, spanEnd: 8 }));
  expect(replay.status).toBe("conflict");
  if (replay.status === "conflict") expect(replay.reason).toBe("in_progress");

  // Reusing the key for a request that differs ONLY in one new axis is a different answer — caught.
  const variants: Partial<ContextPreviewRequest>[] = [
    { spanStart: 0, spanEnd: 3 }, // a different marked occurrence
    { spanStart: 4, spanEnd: 8, contextLanguage: "en" }, // a labeled text language
    { spanStart: 4, spanEnd: 8, targetLanguage: "fr" }, // a different unit language
  ];
  for (const over of variants) {
    const r = await explainContextPreview(d, req({ idempotencyKey: "tap-1", ...over }));
    expect(r.status).toBe("conflict");
    if (r.status === "conflict") expect(r.reason).toBe("fingerprint_mismatch");
  }
});

test("persists canonical context language + the normalized span; junk degrades to NULL, never a wrong label", async () => {
  const d = deps();
  expect((await explainContextPreview(d, req({ contextLanguage: "EN", spanStart: 4, spanEnd: 8 }))).status).toBe("ready");
  const first = await sql
    .prepare("SELECT context_language, span_start, span_end FROM context_previews ORDER BY created_at, id LIMIT 1")
    .first<{ context_language: string | null; span_start: number | null; span_end: number | null }>();
  expect(first).toEqual({ context_language: "en", span_start: 4, span_end: 8 }); // canonicalized, not raw "EN"

  const second = await explainContextPreview(
    d,
    req({ surfaceUnit: "atom", contextText: "An atom is tiny.", contextLanguage: "not a tag!!", spanStart: -5, spanEnd: 2 }),
  );
  expect(second.status).toBe("ready"); // junk axes never fail the preview — they degrade
  const rows = await sql
    .prepare("SELECT context_language, span_start, span_end FROM context_previews ORDER BY created_at, id")
    .all<{ context_language: string | null; span_start: number | null; span_end: number | null }>();
  expect(rows[1]).toEqual({ context_language: null, span_start: null, span_end: null });
});

test("emits a PII-free observation on success and on failure (E8 parity with /explain)", async () => {
  const seen: ContextPreviewObservation[] = [];
  const observe = (o: ContextPreviewObservation) => seen.push(o);

  await explainContextPreview(deps({ observe }), req());
  expect(seen.at(-1)).toEqual({ outcome: "generated", target: "en", gloss: "en", charged: true });

  const provider = new MockContextProvider(() => {
    throw new Error("timeout");
  });
  await explainContextPreview(deps({ provider, observe }), req());
  expect(seen.at(-1)).toEqual({ outcome: "failed", target: "en", gloss: "en", reason: "provider_error" });

  // The sink carries only public axes — never the unit ("cell") or the sentence text (T8).
  const serialized = JSON.stringify(seen);
  expect(serialized).not.toContain("cell");
  expect(serialized).not.toContain(SENTENCE);
});
