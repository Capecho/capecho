import type { Sql } from "./sql.ts";
import type { Budget } from "./budget-logic.ts";
import type { CostConfig } from "./config.ts";
import { EnvelopeCrypto } from "./crypto.ts";
import { reserveContextQuota, commitReservation, refundReservation } from "./quota.ts";
import { getContextRow, decryptContextText, readGlossPayload, storeGloss, type StoredGloss } from "./contexts.ts";
import { getWordById } from "./words.ts";
import { CONTEXT_PROMPT_VERSION, type ContextExplanationProvider } from "./context-provider.ts";
import { validateContextExplanation, type ContextValidationFailure } from "./validate-context.ts";

// POST /explain/context — the metered, PRIVATE context layer (US-3.2). Order (the
// reservation is what makes it race-safe, not a check-then-decrement):
//   re-view short-circuit → reserve per-user slot → reserve global budget →
//   generate (off-box, zero-retention) → validate → encrypt+store gloss → commit.
// Refund rules:
//   • global cap miss        → refund the per-user slot (no charge), budget untouched
//   • provider transport err → refund BOTH (no spend happened)
//   • validation reject      → refund the per-user slot; global spend STANDS (model paid)
//   • slow gen past the TTL  → CAS-commit fails → not charged, but the gloss is stored,
//                              so a re-view serves it free (eng-review C1)

export interface ContextExplainDeps {
  sql: Sql;
  crypto: EnvelopeCrypto;
  provider: ContextExplanationProvider;
  budget: Budget;
  config: CostConfig;
  /** Clock — called at reserve AND again at commit, so a generation that outruns the
   *  reservation TTL is detected at commit time (not against a stale request-start time). */
  now: () => number;
  newId: () => string;
}

export interface ContextExplainRequest {
  userId: string;
  wordContextId: string;
  explanationLanguage: string;
  /** client-supplied for retry-idempotency of the SAME attempt; a fresh one each call otherwise */
  idempotencyKey?: string;
  quotaDay: string; // account-IANA date
  budgetDayKey: string; // UTC day for the global cap
  cost?: number;
  /** Pro accounts (pro_until > now) have NO daily context cap — "unlimited in-context explanations" is
   *  the headline Pro lever (pro_paywall / upgrade_sheet). The route resolves this via isPro(); the
   *  global AI-spend budget below still applies. Mirrors saveWord's Pro-bypasses-freeWordCap rule. */
  isPro?: boolean;
}

export type ContextExplainResult =
  | { status: "ready"; meaning: string; charged: boolean } // charged=false ⇒ served from a stored gloss (re-view)
  | { status: "not_found" }
  | { status: "quota_exhausted" }
  | { status: "budget_exhausted" }
  | { status: "conflict"; reason: "fingerprint_mismatch" | "reservation_expired" | "in_progress" | "context_changed" }
  | { status: "failed"; reason: ContextValidationFailure | "provider_error" };

export async function explainContext(
  deps: ContextExplainDeps,
  req: ContextExplainRequest,
): Promise<ContextExplainResult> {
  const { sql, crypto, provider, budget, config } = deps;
  const cost = req.cost ?? 1;

  // Load the context (same-owner — this ownership check is why the reservation need not
  // be bound to the context row).
  const row = await getContextRow(sql, req.userId, req.wordContextId);
  if (!row) return { status: "not_found" };

  // Re-view: a stored gloss is served WITHOUT reserving or charging (idempotent +
  // privately persisted, eng-review C5) — but ONLY if it still matches the requested
  // gloss language AND the current prompt version. A different language (or a prompt
  // bump) is a genuinely different answer, so it must regenerate, not serve stale.
  const existingGloss = await readGlossPayload(crypto, row);
  if (
    existingGloss &&
    existingGloss.explanationLanguage === req.explanationLanguage &&
    existingGloss.promptVersion === CONTEXT_PROMPT_VERSION &&
    // Guard on the SHAPE, not just the version: an older stored payload (the two-field
    // sentenceMeaning/wordMeaning shape, or a single `gloss`) lacks `meaning`, so requiring it makes
    // such a payload regenerate under v3 instead of being served as an undefined field (which the
    // non-nullable client cast would crash on).
    typeof existingGloss.meaning === "string"
  ) {
    return {
      status: "ready",
      meaning: existingGloss.meaning,
      charged: false,
    };
  }

  // The unit being explained (for the prompt). Same-owner via getWordById; a
  // soft-deleted (tombstoned) unit is not live, so don't burn a slot explaining it.
  const word = await getWordById(sql, req.userId, row.word_id);
  if (!word || word.deleted_at !== null) return { status: "not_found" };

  // Reserve the per-user daily slot. word_context_id is deliberately NULL: binding it
  // would let a user delete the context to cascade-delete (and thus reclaim) a spent
  // slot — the daily cap is a generation COUNT, not a per-context grant.
  const fingerprint = `ctx:${req.wordContextId}:${CONTEXT_PROMPT_VERSION}`;
  const idempotencyKey = req.idempotencyKey ?? deps.newId();
  const startNow = deps.now();
  // Pro lifts the cap entirely (a bound no live-count reaches), same shape saveWord uses for freeWordCap.
  const dailyCap = req.isPro ? Number.MAX_SAFE_INTEGER : config.contextDailyCap;
  const reserved = await reserveContextQuota(sql, {
    userId: req.userId,
    wordContextId: null,
    requestFingerprint: fingerprint,
    quotaDay: req.quotaDay,
    idempotencyKey,
    dailyCap,
    ttlMs: config.reservationTtlMs,
    now: startNow,
    newId: deps.newId,
  });
  if (reserved.status === "cap_exceeded") return { status: "quota_exhausted" };
  if (reserved.status === "fingerprint_mismatch") return { status: "conflict", reason: "fingerprint_mismatch" };
  if (reserved.status === "reservation_expired") return { status: "conflict", reason: "reservation_expired" };
  // A replay under a still-live key means the FIRST attempt owns the generation (it is
  // in flight, or already committed but its gloss isn't readable here). We must NOT
  // generate again — that would double-spend the global budget and a second-attempt
  // budget miss would refund the FIRST attempt's slot. Tell the caller to retry.
  if (reserved.status === "idempotent_replay") return { status: "conflict", reason: "in_progress" };

  // Reserve the global AI-spend cap (fail-closed). On miss, refund the per-user slot.
  const gb = await budget.reserve(req.budgetDayKey, cost, config.globalDailyBudgetUnits);
  if (!gb.ok) {
    await refundReservation(sql, req.userId, idempotencyKey);
    return { status: "budget_exhausted" };
  }

  // Generate. This is the ONLY path that sends the sentence off-box (§9) — the provider
  // MUST be zero-retention (T8). Decrypt is transient and never logged.
  const contextText = await decryptContextText(crypto, row);
  let raw;
  try {
    raw = await provider.generate({
      unit: word.surface_unit,
      targetLanguage: word.target_language,
      contextText,
      // Only ever the stored script-certain value — NEVER defaulted to the target (the languages
      // genuinely diverge: a zh-Hans unit saved from an English article). Null = the prompt says
      // "the text below" and lets the model read the text.
      contextLanguage: row.context_language,
      explanationLanguage: req.explanationLanguage,
      spanStart: row.span_start,
      spanEnd: row.span_end,
    });
  } catch {
    await budget.refund(req.budgetDayKey, cost); // transport error ⇒ no spend
    await refundReservation(sql, req.userId, idempotencyKey);
    return { status: "failed", reason: "provider_error" };
  }

  const validated = validateContextExplanation(raw);
  if (!validated.ok) {
    // Model was paid (global spend stands) but the user isn't charged for a non-answer.
    await refundReservation(sql, req.userId, idempotencyKey);
    return { status: "failed", reason: validated.reason };
  }

  // Encrypt + store the private gloss BEFORE committing, so a crash between the two
  // leaves a stored gloss (served free on re-view) rather than a charge with no result.
  // The write is GUARDED on the context nonce we read: if the user edited the context
  // mid-generation, this gloss is for the OLD sentence — don't store it and don't charge
  // (the global spend stands; the model was paid).
  const stored: StoredGloss = { ...validated.value, explanationLanguage: req.explanationLanguage };
  const wrote = await storeGloss(sql, crypto, req.userId, req.wordContextId, stored, row.context_nonce!);
  if (!wrote) {
    await refundReservation(sql, req.userId, idempotencyKey);
    return { status: "conflict", reason: "context_changed" };
  }

  // Commit with a FRESH timestamp: if generation outran the reservation TTL, the slot
  // already lapsed (and may have been taken by another request), so CAS-commit fails →
  // not charged, but the gloss is stored, so a re-view serves it free (eng-review C1).
  const charged = await commitReservation(sql, req.userId, idempotencyKey, deps.now());
  return {
    status: "ready",
    meaning: validated.value.meaning,
    charged,
  };
}
