// Cost-spine configuration. Defaults live here; a deployment overrides via Worker
// vars/secrets (parsed in index.ts). All caps are HARD caps — the spine fails closed.

export interface CostConfig {
  /** per-user context explanations per day — US-3.2 hard cap (no purchase path at MVP) */
  contextDailyCap: number;
  /** one global daily AI-spend cap, in generation units (fail-closed, separate DO) */
  globalDailyBudgetUnits: number;
  /** small anonymous-generation sub-cap, well below the global cap (budget-DoS guard, US-3.1) */
  anonDailyGenerationUnits: number;
  /** reserve→commit window; a 'reserved' row past this is reclaimable (crash recovery) */
  reservationTtlMs: number;
  /** how long an unsaved context PREVIEW (E2) stays adoptable before the sweep deletes it — long
   *  enough to capture→save, short enough to stay ephemeral (dismiss = let it expire) */
  previewTtlMs: number;
}

export const DEFAULT_COST_CONFIG: CostConfig = {
  contextDailyCap: 10,
  globalDailyBudgetUnits: 5000,
  // Default-closed: anonymous callers are HIT-only (the budget-DoS-safe default,
  // US-3.1). Set >0 to open the small bounded onboarding-first-capture allowance.
  anonDailyGenerationUnits: 0,
  reservationTtlMs: 2 * 60 * 1000,
  previewTtlMs: 30 * 60 * 1000, // 30 min
};

function int(value: string | undefined, fallback: number): number {
  if (value === undefined) return fallback;
  const n = Number.parseInt(value, 10);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
}

// Free saved-word cap N — a capacity tier (NOT punitive). When set, free accounts hold up to N words;
// past N a NET-NEW save returns `cap_reached` (resurrect/restore/dedup stay exempt) while every existing
// word stays readable/reviewable/exportable, and Pro accounts bypass it entirely.
//
// MVP STRATEGY (temporary): the cap is DISABLED — saving is free and unlimited. The library is the corpus
// the product compounds on; we'd rather accumulate it (and the habit) than charge for a near-zero-cost
// row, so the only metered lever is per-use AI generation (the in-context explanation). `0` (or any
// non-positive FREE_WORD_CAP) ⇒ no cap. The whole enforcement path above is retained so a single positive
// value re-enables it later. See docs/product-definition-frontier.md §9.
export const DEFAULT_FREE_WORD_CAP = 0;

/** The free saved-word cap, or `undefined` when disabled (unlimited). `<= 0` ⇒ unlimited. */
export function freeWordCapFromEnv(env: { FREE_WORD_CAP?: string }): number | undefined {
  const n = int(env.FREE_WORD_CAP, DEFAULT_FREE_WORD_CAP);
  return n > 0 ? n : undefined;
}

export function costConfigFromEnv(env: {
  CONTEXT_DAILY_CAP?: string;
  GLOBAL_DAILY_BUDGET_UNITS?: string;
  ANON_DAILY_GENERATION_UNITS?: string;
  RESERVATION_TTL_MS?: string;
  PREVIEW_TTL_MS?: string;
}): CostConfig {
  return {
    contextDailyCap: int(env.CONTEXT_DAILY_CAP, DEFAULT_COST_CONFIG.contextDailyCap),
    globalDailyBudgetUnits: int(env.GLOBAL_DAILY_BUDGET_UNITS, DEFAULT_COST_CONFIG.globalDailyBudgetUnits),
    anonDailyGenerationUnits: int(env.ANON_DAILY_GENERATION_UNITS, DEFAULT_COST_CONFIG.anonDailyGenerationUnits),
    reservationTtlMs: int(env.RESERVATION_TTL_MS, DEFAULT_COST_CONFIG.reservationTtlMs),
    previewTtlMs: int(env.PREVIEW_TTL_MS, DEFAULT_COST_CONFIG.previewTtlMs),
  };
}
