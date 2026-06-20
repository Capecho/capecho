import { test, expect } from "bun:test";
import { getWordExplanation, type ExplainDeps, type ExplainRequest } from "../src/explain.ts";
import { MemoryCache } from "../src/cache.ts";
import { BudgetLedger, MemoryBudgetStore } from "../src/budget-logic.ts";
import { Coalescer } from "../src/single-flight.ts";
import { MockExplanationProvider } from "../src/providers/mock.ts";
import { UnconfiguredProvider } from "../src/providers/null.ts";
import type { GenerateResult } from "../src/provider.ts";

function deps(over: Partial<ExplainDeps> = {}): ExplainDeps & { cache: MemoryCache; provider: MockExplanationProvider } {
  const cache = new MemoryCache();
  const provider = new MockExplanationProvider();
  return {
    cache,
    provider,
    budget: new BudgetLedger(new MemoryBudgetStore()),
    singleFlight: new Coalescer(),
    ...over,
  } as ExplainDeps & { cache: MemoryCache; provider: MockExplanationProvider };
}

const req = (over: Partial<ExplainRequest> = {}): ExplainRequest => ({
  surfaceUnit: "serendipity",
  targetLanguage: "en",
  explanationLanguage: "en",
  account: "user",
  budgetDayKey: "2026-05-27",
  globalCap: 1000,
  ...over,
});

test("cache miss for a user generates, validates, caches, and serves", async () => {
  const d = deps();
  const r = await getWordExplanation(d, req());
  expect(r.status).toBe("generated");
  expect(d.provider.calls).toBe(1);
  expect(d.cache.size).toBe(1);
});

test("a second request for the same unit is served from cache (no second generation)", async () => {
  const d = deps();
  await getWordExplanation(d, req());
  const second = await getWordExplanation(d, req());
  expect(second.status).toBe("hit");
  expect(d.provider.calls).toBe(1);
});

test("non-allowlisted target is language_unsupported — never generates, never caches", async () => {
  const d = deps();
  const r = await getWordExplanation(d, req({ targetLanguage: "es", surfaceUnit: "casa" }));
  expect(r.status).toBe("language_unsupported");
  expect(d.provider.calls).toBe(0);
  expect(d.cache.size).toBe(0);
});

test("anonymous + cache MISS is HIT-only (no generation) by default", async () => {
  const d = deps();
  const r = await getWordExplanation(d, req({ account: "anon" }));
  expect(r.status).toBe("anon_miss");
  expect(d.provider.calls).toBe(0);
});

test("anonymous IS served an existing cache HIT", async () => {
  const d = deps();
  await getWordExplanation(d, req({ account: "user" })); // warm the cache
  const r = await getWordExplanation(d, req({ account: "anon" }));
  expect(r.status).toBe("hit");
  expect(d.provider.calls).toBe(1); // only the warming call
});

test("anonymous + cache MISS GENERATES when a bounded anon sub-cap is open (US-3.1)", async () => {
  // Word lookup is free for everyone: with ANON_DAILY_GENERATION_UNITS > 0 the account-less
  // miss path generates instead of returning anon_miss. (Only the paid context layer is gated.)
  const d = deps();
  const r = await getWordExplanation(d, req({ account: "anon", budgetDayKey: "2026-05-27", anonDayKey: "anon:2026-05-27", anonCap: 5 }));
  expect(r.status).toBe("generated");
  expect(d.provider.calls).toBe(1);
  // The anon generation is debited from BOTH the shared global budget AND the anon sub-cap. Anon
  // spend is NOT a separate pool — that shared-pool property is what bounds a forged-id flood.
  expect(await d.budget.spent("2026-05-27")).toBe(1);
  expect(await d.budget.spent("anon:2026-05-27")).toBe(1);
});

test("the anon sub-cap is a hard ceiling — generation past it fails closed (anon cap binds)", async () => {
  // anonCap is the binding constraint here (1, vs the roomy default globalCap): a forged-id flood
  // can spend at most anonCap units/day; the next anon miss fails closed rather than continuing.
  const d = deps();
  const first = await getWordExplanation(d, req({ account: "anon", surfaceUnit: "serendipity", anonDayKey: "anon:2026-05-27", anonCap: 1 }));
  expect(first.status).toBe("generated");
  const second = await getWordExplanation(d, req({ account: "anon", surfaceUnit: "ephemeral", anonDayKey: "anon:2026-05-27", anonCap: 1 }));
  expect(second.status).toBe("budget_exhausted");
  expect(d.provider.calls).toBe(1); // the second never reached the provider
});

test("anon generation draws from the SHARED global budget, so the global cap bounds it too (blast-radius)", async () => {
  // Make the GLOBAL cap the binding constraint (1) with a roomy anon sub-cap (500): one anon
  // generation exhausts the GLOBAL pool, so the next anon miss fails closed on the global cap even
  // though the anon sub-cap still has room — proving anon spend lands in the shared global budget
  // and a forged-id flood can never exceed it (the load-bearing budget-DoS guarantee, US-3.1).
  const d = deps();
  const first = await getWordExplanation(d, req({ account: "anon", surfaceUnit: "serendipity", budgetDayKey: "2026-05-27", globalCap: 1, anonDayKey: "anon:2026-05-27", anonCap: 500 }));
  expect(first.status).toBe("generated");
  expect(await d.budget.spent("2026-05-27")).toBe(1); // the anon gen landed in the GLOBAL pool
  const second = await getWordExplanation(d, req({ account: "anon", surfaceUnit: "ephemeral", budgetDayKey: "2026-05-27", globalCap: 1, anonDayKey: "anon:2026-05-27", anonCap: 500 }));
  expect(second.status).toBe("budget_exhausted");
  expect(d.provider.calls).toBe(1); // global exhausted → second never reached the provider
});

test("once the anon sub-cap is exhausted, a further anon miss NEVER reserves the global budget (no leak vector)", async () => {
  // Reserve-anon-first ordering: when the anon bucket is full the request fails closed on the anon
  // reserve and never touches global — so a sustained account-less flood can't reserve+best-effort-
  // refund (and, on a refund failure, LEAK) shared global units that signed-in users depend on.
  const d = deps();
  const reserved: string[] = [];
  const base = d.budget;
  d.budget = {
    reserve: (k, c, cap) => {
      reserved.push(k);
      return base.reserve(k, c, cap);
    },
    refund: (k, c) => base.refund(k, c),
    spent: (k) => base.spent(k),
  };
  // First miss exhausts the anon bucket (cap 1); global has ample room.
  const first = await getWordExplanation(d, req({ account: "anon", surfaceUnit: "serendipity", budgetDayKey: "2026-05-27", globalCap: 5000, anonDayKey: "anon:2026-05-27", anonCap: 1 }));
  expect(first.status).toBe("generated");
  reserved.length = 0; // ignore the first (allowed) generation's reservations
  // Second anon miss with the anon bucket full: must fail closed touching ONLY the anon key.
  const second = await getWordExplanation(d, req({ account: "anon", surfaceUnit: "ephemeral", budgetDayKey: "2026-05-27", globalCap: 5000, anonDayKey: "anon:2026-05-27", anonCap: 1 }));
  expect(second.status).toBe("budget_exhausted");
  expect(reserved).toEqual(["anon:2026-05-27"]); // global ("2026-05-27") was NEVER reserved
  expect(await d.budget.spent("2026-05-27")).toBe(1); // global unchanged since the one allowed gen
});

test("ENG-6 single-flight: concurrent misses for one key trigger ONE generation", async () => {
  const d = deps();
  const [a, b, c] = await Promise.all([
    getWordExplanation(d, req()),
    getWordExplanation(d, req()),
    getWordExplanation(d, req()),
  ]);
  expect(d.provider.calls).toBe(1);
  expect([a.status, b.status, c.status].filter((s) => s === "generated" || s === "hit")).toHaveLength(3);
  expect(d.cache.size).toBe(1);
});

test("global budget fail-closed: at cap, no generation happens", async () => {
  const budget = new BudgetLedger(new MemoryBudgetStore());
  await budget.reserve("2026-05-27", 1000, 1000); // exhaust the day
  const d = deps({ budget });
  const r = await getWordExplanation(d, req({ globalCap: 1000 }));
  expect(r.status).toBe("budget_exhausted");
  expect(d.provider.calls).toBe(0);
  expect(d.cache.size).toBe(0);
});

test("invalid model output => failed, spend STANDS, cache not poisoned", async () => {
  const provider = new MockExplanationProvider((): GenerateResult => ({ raw: { readings: [] } }));
  const budget = new BudgetLedger(new MemoryBudgetStore());
  const d = deps({ provider, budget });
  const r = await getWordExplanation(d, req());
  expect(r.status).toBe("failed");
  if (r.status === "failed") expect(r.reason).toBe("missing_sense");
  expect(d.cache.size).toBe(0); // never cached
  expect(await budget.spent("2026-05-27")).toBe(1); // the model was paid — spend stands
});

test("provider transport error => failed + budget REFUNDED (no spend)", async () => {
  const provider = new MockExplanationProvider(() => {
    throw new Error("timeout");
  });
  const budget = new BudgetLedger(new MemoryBudgetStore());
  const d = deps({ provider, budget });
  const r = await getWordExplanation(d, req());
  expect(r.status).toBe("failed");
  if (r.status === "failed") expect(r.reason).toBe("provider_error");
  expect(await budget.spent("2026-05-27")).toBe(0); // refunded
});

test("anon sub-cap, when opened, allows bounded generation and is itself capped", async () => {
  const d = deps();
  const base = req({ account: "anon", anonDayKey: "anon:2026-05-27", anonCap: 1, globalCap: 1000 });
  const first = await getWordExplanation(d, base);
  expect(first.status).toBe("generated"); // sub-cap open → generated
  // a DIFFERENT unit by anon now exceeds the sub-cap of 1
  const second = await getWordExplanation(d, req({ ...base, surfaceUnit: "ephemeral" }));
  expect(second.status).toBe("budget_exhausted");
});

test("explanation language is part of the identity (en vs es glosses are separate blobs)", async () => {
  const d = deps();
  await getWordExplanation(d, req({ explanationLanguage: "en" }));
  await getWordExplanation(d, req({ explanationLanguage: "es" }));
  expect(d.provider.calls).toBe(2);
  expect(d.cache.size).toBe(2);
});

test("target is canonicalized ONCE: 'EN' and 'en-US' collapse to one key + share one blob", async () => {
  const d = deps();
  const a = await getWordExplanation(d, req({ targetLanguage: "EN" }));
  expect(a.status).toBe("generated");
  if (a.status === "generated") {
    expect(a.key).toContain("/en/"); // collapsed in the key — the canonical target lives in the key, not the blob
  }
  // A differently-cased request for the same word hits the SAME cached blob — no second gen.
  const b = await getWordExplanation(d, req({ targetLanguage: "en-US" }));
  expect(b.status).toBe("hit");
  expect(d.provider.calls).toBe(1);
});

test("a full sentence is unit_too_large — never keyed, never generated, never cached (§13)", async () => {
  const d = deps();
  const r = await getWordExplanation(
    d,
    req({ surfaceUnit: "this is a whole sentence that must never become a free word cache key" }),
  );
  expect(r.status).toBe("unit_too_large");
  expect(d.provider.calls).toBe(0);
  expect(d.cache.size).toBe(0);
});

test("degenerate junk is not_a_word — never keyed, never generated, never cached (RFC §B)", async () => {
  const d = deps();
  for (const junk of ["→", "42", "...", "https://example.com", "a@b.com"]) {
    const r = await getWordExplanation(d, req({ surfaceUnit: junk }));
    expect(r.status).toBe("not_a_word");
  }
  expect(d.provider.calls).toBe(0); // no junk ever spent a generation
  expect(d.cache.size).toBe(0);
});

test("single-token keyboard-mash / repeats are not_a_word — never generated, never cached (L1)", async () => {
  const d = deps();
  for (const g of ["asdfgh", "qwerty", "aaaa", "loooool"]) {
    const r = await getWordExplanation(d, req({ surfaceUnit: g }));
    expect(r.status).toBe("not_a_word");
  }
  expect(d.provider.calls).toBe(0); // no mash ever spent a generation
  expect(d.cache.size).toBe(0);
});

test("an OCR-corrupted real word still generates — the junk gate must NOT false-reject (eng-review)", async () => {
  const d = deps();
  const r = await getWordExplanation(d, req({ surfaceUnit: "serendipily" })); // OCR typo of 'serendipity'
  expect(r.status).toBe("generated"); // a real (mis-OCR'd) word reaches the model; the AI can fix it
  expect(d.provider.calls).toBe(1);
});

test("a word-shaped non-word reaches the model, which declines it → not_a_word: spend stands, nothing cached (L3)", async () => {
  // "blorp" is pronounceable, so it passes the local + server junk/gibberish gates and DOES reach the
  // model. The model returns {"notAWord": true}; that is a non-word verdict, NOT a failed generation —
  // distinct status, spend stands (it was paid), and it must never be cached.
  let calls = 0;
  const provider = {
    async generate(): Promise<GenerateResult> {
      calls++;
      return { raw: { notAWord: true } };
    },
  };
  const d = deps({ provider });
  const r = await getWordExplanation(d, req({ surfaceUnit: "blorp" }));
  expect(r.status).toBe("not_a_word");
  expect(calls).toBe(1); // the model WAS called — spend stands
  expect(d.cache.size).toBe(0); // a non-word verdict is never cached
});

test("fail-closed provider (none configured): generation throws → failed, nothing cached, budget refunded", async () => {
  const budget = new BudgetLedger(new MemoryBudgetStore());
  const d = deps({ provider: new UnconfiguredProvider(), budget });
  const r = await getWordExplanation(d, req());
  expect(r.status).toBe("failed");
  if (r.status === "failed") expect(r.reason).toBe("provider_error");
  expect(d.cache.size).toBe(0); // a mock blob never reaches the shared cache
  expect(await budget.spent("2026-05-27")).toBe(0); // no spend leaked
});

// --- E8: per-generation observability sink ---------------------------------------

import type { ExplainObservation } from "../src/explain.ts";

test("E8 observe fires once on a generation with readingCount + pronunciationState (not on a hit)", async () => {
  const seen: ExplainObservation[] = [];
  const d = deps({ observe: (o) => seen.push(o) });
  await getWordExplanation(d, req()); // generate
  await getWordExplanation(d, req()); // hit — must NOT observe again
  expect(seen).toHaveLength(1);
  expect(seen[0]!.outcome).toBe("generated");
  expect(seen[0]!.target).toBe("en");
  expect(seen[0]!.readingCount).toBe(1);
  expect(seen[0]!.pronunciationState).toBe("present"); // the mock returns a reading
});

test("E8 observe reports the gate-failure reason on a rejected generation", async () => {
  const seen: ExplainObservation[] = [];
  const provider = new MockExplanationProvider((): GenerateResult => ({ raw: { readings: [] } }));
  const d = deps({ provider, observe: (o) => seen.push(o) });
  await getWordExplanation(d, req());
  expect(seen).toHaveLength(1);
  expect(seen[0]!.outcome).toBe("failed");
  expect(seen[0]!.reason).toBe("missing_sense");
});

test("E8 observe surfaces a dropped pronunciation field (omit-on-fail signal)", async () => {
  const seen: ExplainObservation[] = [];
  // a valid sense, but the offered pronunciation is unusable (oversized) → blanked per-reading
  // (E8 'dropped').
  const provider = new MockExplanationProvider((): GenerateResult => ({
    raw: {
      readings: [
        {
          pronunciationPrimary: "x".repeat(121),
          pronunciationSecondary: "",
          pos: [{ partOfSpeech: "noun", senses: ["a thing"] }],
        },
      ],
    },
  }));
  const d = deps({ provider, observe: (o) => seen.push(o) });
  const r = await getWordExplanation(d, req());
  expect(r.status).toBe("generated"); // omit-on-fail: the bad field never blocks the core
  expect(seen[0]!.pronunciationState).toBe("dropped");
});
