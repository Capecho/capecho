import { generationCacheKey, resolveExplanationLanguage, type ExplanationLanguage } from "@capecho/lang";
import { dedupKey } from "./dedup-key.ts";
import { wordCacheKey, PROMPT_VERSION } from "./cache-key.ts";
import { unitWithinBounds, isLikelyJunk, isLikelyGibberish } from "./input.ts";
import type { ExplanationCache } from "./cache.ts";
import type { Budget } from "./budget-logic.ts";
import type { SingleFlight } from "./single-flight.ts";
import type { ExplanationProvider, WordExplanation } from "./provider.ts";
import { validateWordExplanation, type PronunciationFieldState, type ValidationFailure } from "./validate.ts";

// GET /explain — the free word-level layer. Cache-first → allowlist gate →
// single-flight → reserve budget → generate → cache-write-validate → cache → serve.
// The whole spend ordering is ENG-6: a follower never reserves spend, the budget is
// reserved (not check-then-spend), and a non-allowlisted target never generates.

export type ExplainResult =
  | { status: "hit" | "generated"; key: string; explanation: WordExplanation }
  | { status: "language_unsupported" }
  | { status: "unit_too_large" } // not a word/short phrase — use the context layer
  | { status: "not_a_word" } // degenerate non-vocabulary (punctuation/number/URL) — never generate (RFC §B)
  | { status: "anon_miss"; key: string } // anonymous + cache miss — sign in to generate
  | { status: "budget_exhausted" } // global / anon sub-cap hit — fail closed
  | { status: "failed"; reason: ValidationFailure | "provider_error" };

// E8 observability — one structured record per ACTUAL generation (not a cache hit; generation is the
// rare, shared event). Lets the per-field gate-failure rate be aggregated off the logs (Workers
// Observability indexes these JSON fields; Analytics Engine is the scale-up path) so the omit-on-fail
// bar is calibratable instead of invisible. Carries NO unit/context text (T8) — only the canonical
// target/gloss tags + counts/enums.
export interface ExplainObservation {
  outcome: "generated" | "failed" | "not_a_word";
  target: string; // canonical generation target (public dictionary axis, not sensitive)
  gloss: ExplanationLanguage;
  promptVersion: string;
  reason?: ValidationFailure | "provider_error"; // present iff outcome === "failed"
  readingCount?: number; // heteronym/polyphone-rate proxy (present on success)
  pronunciationState?: PronunciationFieldState; // the omit-on-fail deep-field signal (present on success)
}

export interface ExplainDeps {
  cache: ExplanationCache;
  budget: Budget;
  singleFlight: SingleFlight;
  provider: ExplanationProvider;
  /** Optional structured-observability sink, called once per generation outcome (never on a hit). */
  observe?: (o: ExplainObservation) => void;
}

export interface ExplainRequest {
  surfaceUnit: string;
  targetLanguage: string; // raw client tag — the allowlist gate canonicalizes
  explanationLanguage: string; // raw client tag — resolved (defaults to en)
  /** account => may generate on miss; anon => HIT-only unless an anon sub-cap is open */
  account: "user" | "anon";
  budgetDayKey: string; // UTC day for the global cap
  globalCap: number;
  /** anon-generation sub-cap (well below global). <= 0 keeps anon HIT-only. */
  anonDayKey?: string;
  anonCap?: number;
  cost?: number; // generation units (default 1)
}

interface Reservation {
  key: string;
  cap: number;
  cost: number;
}

async function reserveAll(budget: Budget, rs: Reservation[]): Promise<boolean> {
  const done: Reservation[] = [];
  for (const r of rs) {
    const d = await budget.reserve(r.key, r.cost, r.cap);
    if (!d.ok) {
      for (const x of done) await budget.refund(x.key, x.cost);
      return false;
    }
    done.push(r);
  }
  return true;
}

export type ExplainKey =
  | { status: "language_unsupported" }
  | { status: "unit_too_large" }
  | { status: "not_a_word" }
  | { status: "ok"; key: string; normalized: string; gloss: ExplanationLanguage; target: string };

/**
 * The shared "head" of /explain — the allowlist gate + canonicalization +
 * normalization + input bounds + gloss resolution + durable cache key.
 * SERVER-AUTHORITATIVE: a non-allowlisted target is never generated/cached (US-3.1),
 * and an over-bound selection (a sentence, not a word/short phrase) is rejected
 * before it can key/spend (§13). Used by the Worker (to pick the single-flight DO id
 * + fast cache-hit path) and by `getWordExplanation` (one source of truth).
 */
export function explainKey(req: Pick<ExplainRequest, "surfaceUnit" | "targetLanguage" | "explanationLanguage">): ExplainKey {
  // Canonicalize the target ONCE to the collapsed generation target (en-US/en-GB → en).
  // This single canonical tag flows to normalization, the cache key, the provider, the
  // validator, and the cached payload — so a SHARED blob is identical regardless of
  // which client casing first generated it (null ⇒ not generation-allowed).
  const target = generationCacheKey(req.targetLanguage);
  if (target === null) return { status: "language_unsupported" };
  // Degenerate non-vocabulary (pure punctuation/number/symbol/URL/email) OR a single keyboard-mash /
  // repeated-key token ("asdfgh", "aaaa") must never key or spend (RFC §B). Authoritative twin of the
  // client junk + gibberish gates; mirrors their order (language → junk → gibberish). Both reject TRUE
  // non-words ONLY — a real word, incl. an OCR typo, must reach generation (eng-review safety guard).
  if (isLikelyJunk(req.surfaceUnit) || isLikelyGibberish(req.surfaceUnit)) return { status: "not_a_word" };
  const normalized = dedupKey(req.surfaceUnit);
  if (normalized.length === 0) return { status: "language_unsupported" };
  if (!unitWithinBounds(normalized)) return { status: "unit_too_large" };
  const gloss = resolveExplanationLanguage(req.explanationLanguage) ?? "en";
  const key = wordCacheKey({ normalizedUnit: normalized, targetLanguage: target, explanationLanguage: gloss });
  return { status: "ok", key, normalized, gloss, target };
}

export async function getWordExplanation(
  deps: ExplainDeps,
  req: ExplainRequest,
): Promise<ExplainResult> {
  const resolved = explainKey(req);
  if (resolved.status === "language_unsupported") return { status: "language_unsupported" };
  if (resolved.status === "unit_too_large") return { status: "unit_too_large" };
  if (resolved.status === "not_a_word") return { status: "not_a_word" };
  const { key, normalized, gloss, target } = resolved;

  // Cache-first (CDN/R2).
  const hit = await deps.cache.get(key);
  if (hit) return { status: "hit", key, explanation: hit };

  const cost = req.cost ?? 1;
  const anonCap = req.anonCap ?? 0;
  const anonOpen = req.account === "anon" && req.anonDayKey !== undefined && anonCap > 0;

  // Anonymous + cache MISS = HIT-only by default (budget-DoS guard, US-3.1). There is
  // NO fall-through to generation unless a small anon sub-cap is explicitly open.
  if (req.account === "anon" && !anonOpen) return { status: "anon_miss", key };

  // Single-flight: concurrent misses for one key collapse to one generation.
  return deps.singleFlight.run<ExplainResult>(key, async () => {
    // Re-check inside the critical section — a prior leader may have filled the cache.
    const again = await deps.cache.get(key);
    if (again) return { status: "hit", key, explanation: again };

    // ENG-6: the leader reserves budget BEFORE generating. Anon also reserves the
    // sub-cap; if either cap is hit, refund any partial and fail closed.
    //
    // Order matters: reserve the anon sub-cap BEFORE the global cap. A flood of account-less misses
    // that has already exhausted the anon bucket then fails closed on the anon reserve WITHOUT ever
    // reserving (and best-effort-refunding, budget-do-client.ts) a global unit — closing the vector
    // where a failed refund permanently ratchets the shared global cap down and starves signed-in
    // users (budget-DoS guard, US-3.1). When anon has room but the global cap is hit, the partial
    // that gets refunded is the anon (self-limiting) reservation, not a shared global one.
    const reservations: Reservation[] = anonOpen
      ? [
          { key: req.anonDayKey!, cap: anonCap, cost },
          { key: req.budgetDayKey, cap: req.globalCap, cost },
        ]
      : [{ key: req.budgetDayKey, cap: req.globalCap, cost }];
    if (!(await reserveAll(deps.budget, reservations))) return { status: "budget_exhausted" };

    let raw;
    try {
      raw = await deps.provider.generate({
        unit: req.surfaceUnit,
        normalizedUnit: normalized,
        targetLanguage: target,
        explanationLanguage: gloss,
      });
    } catch {
      // Transport error => NO spend happened; refund every reservation.
      for (const r of reservations) await deps.budget.refund(r.key, r.cost);
      deps.observe?.({ outcome: "failed", reason: "provider_error", target, gloss, promptVersion: PROMPT_VERSION });
      return { status: "failed", reason: "provider_error" };
    }

    const validated = validateWordExplanation(raw);
    if (!validated.ok) {
      // The model itself judged the unit a non-word (L3 authority — {"notAWord": true}). A DISTINCT
      // terminal from a failed generation: the model worked, there's just nothing to explain. Spend
      // STANDS (it was paid), and we do NOT cache. Tombstone-caching repeated non-words is a follow-up;
      // meanwhile cost is bounded by the daily budget cap + the saved word's terminal state (a saved
      // non-word is stamped terminal, so it never re-fetches — only a brand-new capture re-spends).
      if (validated.reason === "not_a_word") {
        deps.observe?.({ outcome: "not_a_word", target, gloss, promptVersion: PROMPT_VERSION });
        return { status: "not_a_word" };
      }
      // The model was already paid — spend STANDS (no refund) — but an unusable
      // output must never poison the cache (CEO-8).
      deps.observe?.({ outcome: "failed", reason: validated.reason, target, gloss, promptVersion: PROMPT_VERSION });
      return { status: "failed", reason: validated.reason };
    }

    deps.observe?.({
      outcome: "generated",
      target,
      gloss,
      promptVersion: PROMPT_VERSION,
      readingCount: validated.value.readings.length,
      pronunciationState: validated.pronunciationState,
    });
    await deps.cache.put(key, validated.value);
    return { status: "generated", key, explanation: validated.value };
  });
}
