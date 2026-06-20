import { test, expect, beforeEach } from "bun:test";
import { freshDb, ids, seedAccount } from "./helpers/db.ts";
import { testCrypto } from "./helpers/crypto.ts";
import { saveWord, softDeleteWord } from "../src/words.ts";
import { createContext, editContextText, listContextsForWord, getContextRow, storeGloss, type StoredGloss } from "../src/contexts.ts";
import { countLiveReservations, reserveContextQuota } from "../src/quota.ts";
import { BudgetLedger, MemoryBudgetStore } from "../src/budget-logic.ts";
import { MockContextProvider } from "../src/providers/mock-context.ts";
import { explainContext, type ContextExplainDeps, type ContextExplainRequest } from "../src/explain-context.ts";
import { CONTEXT_PROMPT_VERSION } from "../src/context-provider.ts";
import { DEFAULT_COST_CONFIG, type CostConfig } from "../src/config.ts";
import type { Sql } from "../src/sql.ts";
import type { ContextGenerateResult } from "../src/context-provider.ts";

const DAY = "2026-05-27";

/** A clock that returns each value in turn (then sticks on the last) — for TTL tests. */
function seqClock(times: number[]): () => number {
  let i = 0;
  return () => times[Math.min(i++, times.length - 1)]!;
}

let sql: Sql;
let newId: () => string;
let ctxId: string;
let wordId: string;

beforeEach(async () => {
  ({ sql } = freshDb());
  newId = ids("x");
  await seedAccount(sql, "u1");
});

async function deps(over: Partial<ContextExplainDeps> = {}): Promise<ContextExplainDeps & { provider: MockContextProvider; budget: BudgetLedger }> {
  const provider = (over.provider as MockContextProvider) ?? new MockContextProvider();
  const budget = (over.budget as BudgetLedger) ?? new BudgetLedger(new MemoryBudgetStore());
  return {
    sql,
    crypto: await testCrypto(),
    provider,
    budget,
    config: DEFAULT_COST_CONFIG,
    now: () => 1000,
    newId,
    ...over,
  } as ContextExplainDeps & { provider: MockContextProvider; budget: BudgetLedger };
}

const req = (over: Partial<ContextExplainRequest> = {}): ContextExplainRequest => ({
  userId: "u1",
  wordContextId: ctxId,
  explanationLanguage: "en",
  quotaDay: DAY,
  budgetDayKey: DAY,
  cost: 1,
  ...over,
});

// NOTE: deps() builds its OWN crypto, so the context must be sealed with the SAME
// crypto the orchestration uses. We thread one crypto through both.

async function setup(over: Partial<ContextExplainDeps> = {}) {
  const d = await deps(over);
  // re-create the context under d.crypto so decrypt succeeds inside explainContext
  const w = await saveWord(sql, { userId: "u1", surfaceUnit: "cell", targetLanguage: "en", now: 1, newId });
  wordId = w.status === "created" || w.status === "deduped" ? w.word.id : "";
  const out = await createContext(sql, d.crypto, { userId: "u1", wordId, contextText: "The cell divides rapidly.", now: 2, newId });
  ctxId = out.status === "created" ? out.id : "";
  return d;
}

test("happy path: reserve → generate → store → commit; charged, quota+budget each consume one", async () => {
  const d = await setup();
  const r = await explainContext(d, req());
  expect(r.status).toBe("ready");
  if (r.status === "ready") expect(r.charged).toBe(true);
  expect(d.provider.calls).toBe(1);
  expect(await countLiveReservations(sql, "u1", DAY, 1000)).toBe(1);
  expect(await d.budget.spent(DAY)).toBe(1);
});

test("the provider receives the STORED context language verbatim — NULL never defaults to the target", async () => {
  // Guards the saved-layer call site at its historical bug location: it used to read
  // `row.context_language ?? word.target_language`. The context above is created WITHOUT a
  // language (the normal case), so the provider must see null — not "en".
  const d = await setup();
  const r = await explainContext(d, req());
  expect(r.status).toBe("ready");
  expect(d.provider.lastRequest).toMatchObject({
    unit: "cell",
    targetLanguage: "en",
    contextLanguage: null, // NOT word.target_language
  });
});

test("re-view: a stored gloss is served WITHOUT a reservation, generation, or charge (eng-review C5)", async () => {
  const d = await setup();
  const first = await explainContext(d, req());
  expect(first.status).toBe("ready");
  const second = await explainContext(d, req());
  expect(second.status).toBe("ready");
  if (second.status === "ready") expect(second.charged).toBe(false);
  expect(d.provider.calls).toBe(1); // not regenerated
  expect(await countLiveReservations(sql, "u1", DAY, 1000)).toBe(1); // still just the first
  expect(await d.budget.spent(DAY)).toBe(1);
});

test("re-view IGNORES a stale wrong-shape gloss (shape guard) and regenerates the combined answer", async () => {
  // A stored payload can match the CURRENT prompt version yet carry the wrong SHAPE (an old two-field
  // sentenceMeaning/wordMeaning payload, or a single `gloss`). The re-view must guard on the SHAPE and
  // regenerate, never hand the client an undefined field.
  const d = await setup();
  const row = (await getContextRow(sql, "u1", ctxId))!;
  const stale = {
    sentenceMeaning: "the old whole-sentence meaning",
    wordMeaning: "the old word sense",
    promptVersion: CONTEXT_PROMPT_VERSION,
    explanationLanguage: "en",
  } as unknown as StoredGloss;
  await storeGloss(sql, d.crypto, "u1", ctxId, stale, row.context_nonce!);

  const r = await explainContext(d, req());
  expect(r.status).toBe("ready");
  if (r.status === "ready") {
    expect(r.meaning.length).toBeGreaterThan(0);
    expect(r.charged).toBe(true); // regenerated, not served from the stale payload
  }
  expect(d.provider.calls).toBe(1); // the stale payload did NOT short-circuit
});

test("unknown context id → not_found, nothing reserved or spent", async () => {
  const d = await setup();
  const r = await explainContext(d, req({ wordContextId: "no-such-context" }));
  expect(r.status).toBe("not_found");
  expect(d.provider.calls).toBe(0);
  expect(await countLiveReservations(sql, "u1", DAY, 1000)).toBe(0);
});

test("daily cap is hard: once the slot is committed, a DIFFERENT context is quota_exhausted", async () => {
  const cfg: CostConfig = { ...DEFAULT_COST_CONFIG, contextDailyCap: 1 };
  const d = await setup({ config: cfg });
  expect((await explainContext(d, req())).status).toBe("ready"); // uses the only slot

  // a second context, same day → reservation blocked by the cap
  const w2 = await saveWord(sql, { userId: "u1", surfaceUnit: "mitochondria", targetLanguage: "en", now: 1, newId });
  const c2 = await createContext(sql, d.crypto, {
    userId: "u1",
    wordId: w2.status === "created" ? w2.word.id : "",
    contextText: "another sentence",
    now: 2,
    newId,
  });
  const r2 = await explainContext(d, req({ wordContextId: c2.status === "created" ? c2.id : "" }));
  expect(r2.status).toBe("quota_exhausted");
  expect(d.provider.calls).toBe(1); // the blocked one never generated
});

test("Pro bypasses the daily cap: isPro=true generates past the limit (unlimited in-context explanations)", async () => {
  const cfg: CostConfig = { ...DEFAULT_COST_CONFIG, contextDailyCap: 1 };
  const d = await setup({ config: cfg });
  expect((await explainContext(d, req({ isPro: true }))).status).toBe("ready"); // uses the only free slot

  // a second context the same day would be quota_exhausted for a free user — but Pro has no cap.
  const w2 = await saveWord(sql, { userId: "u1", surfaceUnit: "mitochondria", targetLanguage: "en", now: 1, newId });
  const c2 = await createContext(sql, d.crypto, {
    userId: "u1",
    wordId: w2.status === "created" ? w2.word.id : "",
    contextText: "another sentence",
    now: 2,
    newId,
  });
  const r2 = await explainContext(d, req({ wordContextId: c2.status === "created" ? c2.id : "", isPro: true }));
  expect(r2.status).toBe("ready");
  expect(d.provider.calls).toBe(2); // both generated — the cap never blocked Pro
});

test("global budget exhausted: per-user slot is REFUNDED, nothing charged", async () => {
  const cfg: CostConfig = { ...DEFAULT_COST_CONFIG, globalDailyBudgetUnits: 5 };
  const budget = new BudgetLedger(new MemoryBudgetStore());
  await budget.reserve(DAY, 5, 5); // exhaust the global day
  const d = await setup({ config: cfg, budget });
  const r = await explainContext(d, req());
  expect(r.status).toBe("budget_exhausted");
  expect(await countLiveReservations(sql, "u1", DAY, 1000)).toBe(0); // reservation refunded
});

test("provider transport error: BOTH the reservation and the global budget are refunded", async () => {
  const provider = new MockContextProvider(() => {
    throw new Error("upstream timeout");
  });
  const d = await setup({ provider });
  const r = await explainContext(d, req());
  expect(r.status).toBe("failed");
  if (r.status === "failed") expect(r.reason).toBe("provider_error");
  expect(await countLiveReservations(sql, "u1", DAY, 1000)).toBe(0); // refunded
  expect(await d.budget.spent(DAY)).toBe(0); // refunded — no spend happened
});

test("refusal/invalid gloss: user slot REFUNDED, but the global spend STANDS (model was paid)", async () => {
  const provider = new MockContextProvider(
    (): ContextGenerateResult => ({ raw: { meaning: "I'm sorry, but I can't help." } }),
  );
  const d = await setup({ provider });
  const r = await explainContext(d, req());
  expect(r.status).toBe("failed");
  if (r.status === "failed") expect(r.reason).toBe("refusal");
  expect(await countLiveReservations(sql, "u1", DAY, 1000)).toBe(0); // user not charged for a non-answer
  expect(await d.budget.spent(DAY)).toBe(1); // but the AI call was paid
});

test("editing the context invalidates the gloss, so the next explain regenerates and re-charges", async () => {
  const d = await setup();
  await explainContext(d, req());
  expect(d.provider.calls).toBe(1);

  await editContextText(sql, d.crypto, "u1", ctxId, "The prison cell was cold.");

  const again = await explainContext(d, req());
  expect(again.status).toBe("ready");
  if (again.status === "ready") expect(again.charged).toBe(true);
  expect(d.provider.calls).toBe(2); // regenerated for the new sentence
  expect(await countLiveReservations(sql, "u1", DAY, 1000)).toBe(2); // a second slot consumed
});

// --- review-fix regressions (two-model review of the T8 block) ----------------

test("a generation that outruns the TTL commits=false (not charged) but stores a re-viewable gloss [Codex P1]", async () => {
  const clock = seqClock([1000, 1000 + DEFAULT_COST_CONFIG.reservationTtlMs + 1]); // reserve, then commit past expiry
  const d = await setup({ now: clock });
  const r = await explainContext(d, req());
  expect(r.status).toBe("ready");
  if (r.status === "ready") expect(r.charged).toBe(false); // commit refused on fresh time
  expect(await d.budget.spent(DAY)).toBe(1); // global spend stands (model was paid)
  // the gloss is stored, so a re-view serves it free (no regeneration)
  const again = await explainContext(d, req());
  expect(again.status).toBe("ready");
  if (again.status === "ready") expect(again.charged).toBe(false);
  expect(d.provider.calls).toBe(1);
});

test("a replay under a still-live idempotency key is in_progress — never a second generation [Codex P1]", async () => {
  const d = await setup();
  const key = "dup-key";
  // simulate the first attempt already holding the slot (in flight)
  await reserveContextQuota(sql, {
    userId: "u1",
    wordContextId: null,
    requestFingerprint: `ctx:${ctxId}:${CONTEXT_PROMPT_VERSION}`,
    quotaDay: DAY,
    idempotencyKey: key,
    dailyCap: 10,
    ttlMs: 60_000,
    now: 1000,
    newId,
  });
  const r = await explainContext(d, req({ idempotencyKey: key }));
  expect(r.status).toBe("conflict");
  if (r.status === "conflict") expect(r.reason).toBe("in_progress");
  expect(d.provider.calls).toBe(0); // did NOT regenerate
  expect(await d.budget.spent(DAY)).toBe(0); // did NOT reserve global a second time
});

test("switching the gloss language regenerates rather than serving the stored gloss [Codex P2]", async () => {
  const d = await setup();
  const en = await explainContext(d, req({ explanationLanguage: "en" }));
  expect(en.status).toBe("ready");
  if (en.status === "ready") expect(en.charged).toBe(true);

  const es = await explainContext(d, req({ explanationLanguage: "es" })); // different language ⇒ not a re-view
  expect(es.status).toBe("ready");
  if (es.status === "ready") expect(es.charged).toBe(true);
  expect(d.provider.calls).toBe(2);

  // re-requesting es now IS a free re-view (matches the stored language)
  const esAgain = await explainContext(d, req({ explanationLanguage: "es" }));
  if (esAgain.status === "ready") expect(esAgain.charged).toBe(false);
  expect(d.provider.calls).toBe(2);
});

test("an edit during generation aborts the gloss store (context_changed) and refunds the slot [Codex P2]", async () => {
  const crypto = await testCrypto();
  const budget = new BudgetLedger(new MemoryBudgetStore());
  const w = await saveWord(sql, { userId: "u1", surfaceUnit: "cell", targetLanguage: "en", now: 1, newId });
  const wid = w.status === "created" ? w.word.id : "";
  const c = await createContext(sql, crypto, { userId: "u1", wordId: wid, contextText: "original sentence", now: 2, newId });
  const cid = c.status === "created" ? c.id : "";
  // the provider "takes a while" — and a concurrent edit lands mid-flight (new nonce, gloss cleared)
  const provider = new MockContextProvider(async () => {
    await editContextText(sql, crypto, "u1", cid, "edited mid-flight");
    return { raw: { meaning: "the STALE answer for the old sentence" } };
  });
  const r = await explainContext(
    { sql, crypto, provider, budget, config: DEFAULT_COST_CONFIG, now: () => 1000, newId },
    { userId: "u1", wordContextId: cid, explanationLanguage: "en", quotaDay: DAY, budgetDayKey: DAY },
  );
  expect(r.status).toBe("conflict");
  if (r.status === "conflict") expect(r.reason).toBe("context_changed");
  expect(await countLiveReservations(sql, "u1", DAY, 1000)).toBe(0); // slot refunded
  expect(await budget.spent(DAY)).toBe(1); // model was paid → global stands
  const list = await listContextsForWord(sql, crypto, "u1", wid);
  expect(list[0]!.meaning).toBeNull(); // stale gloss was NOT written onto the new ciphertext
});

test("a context under a soft-deleted unit is not_found — no slot burned [Claude MED]", async () => {
  const d = await setup();
  await softDeleteWord(sql, "u1", wordId, 5);
  const r = await explainContext(d, req());
  expect(r.status).toBe("not_found");
  expect(await countLiveReservations(sql, "u1", DAY, 1000)).toBe(0);
  expect(d.provider.calls).toBe(0);
});
