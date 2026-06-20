import type { Sql, SqlValue } from "./sql.ts";
import type { Budget } from "./budget-logic.ts";
import type { CostConfig } from "./config.ts";
import { EnvelopeCrypto, type Envelope } from "./crypto.ts";
import { reserveContextQuota, commitReservation, refundReservation } from "./quota.ts";
import {
  getContextRow,
  decryptContextText,
  storeGloss,
  MAX_CONTEXT_CHARS,
  type StoredGloss,
} from "./contexts.ts";
import { canonicalizeBcp47 } from "@capecho/lang";
import { unitWithinBounds } from "./input.ts";
import { getWordById } from "./words.ts";
import { CONTEXT_PROMPT_VERSION, type ContextExplanationProvider } from "./context-provider.ts";
import { validateContextExplanation, type ContextValidationFailure } from "./validate-context.ts";

// E2 — the EPHEMERAL context-explanation PREVIEW (RFC explanation-depth). Explains a word IN its
// captured sentence on the RAW (word, sentence) text, BEFORE any word_context row exists, so the
// overlay can show the in-context meaning at capture time. It is metered exactly like the saved
// context layer (same daily cap, same global budget, same reserve-before-generate ordering) and the
// result is stored transiently (encrypted, TTL'd). On Save the gloss is ADOPTED onto the new
// word_context with NO recharge; on dismiss the row just TTL-expires and the cron sweep deletes it.
//
// §178 calm-capture holds because this is OPT-IN (a user-tapped button), never automatic.
//
// Differs from explain-context.ts: there is NO re-view short-circuit — each preview tap is a fresh
// generation + charge ("re-tap re-meters", per the eng E2 decision), and there is no context-nonce
// TOCTOU on store (the preview row is brand new). Adoption is the bridge to the saved layer.

const previewContextAad = (id: string): string => `preview-ctx:${id}`;
const previewGlossAad = (id: string): string => `preview-gloss:${id}`;

/** Structured-observability signal for one preview generation — E8 parity with the saved `/explain`
 *  layer. Carries only the public target / gloss-language axes + the outcome; NEVER the unit, the
 *  sentence, or the gloss text (T8). Indexed by Workers Observability for a preview failure-rate view. */
export interface ContextPreviewObservation {
  outcome: "generated" | "failed";
  target: string; // canonical generation target (public dictionary axis, not sensitive)
  gloss: string; // resolved gloss language (public axis)
  reason?: ContextValidationFailure | "provider_error"; // present iff outcome === "failed"
  charged?: boolean; // present on success — whether the daily slot was actually spent
}

export interface ContextPreviewDeps {
  sql: Sql;
  crypto: EnvelopeCrypto;
  provider: ContextExplanationProvider;
  budget: Budget;
  config: CostConfig;
  now: () => number;
  newId: () => string;
  /** Optional structured-observability sink, called once per generation outcome (never on adoption). */
  observe?: (o: ContextPreviewObservation) => void;
}

export interface ContextPreviewRequest {
  userId: string;
  surfaceUnit: string; // the raw captured unit (the word being explained)
  targetLanguage: string; // canonical target of the unit (caller canonicalizes)
  contextText: string; // the raw captured sentence
  contextLanguage?: string | null;
  spanStart?: number | null;
  spanEnd?: number | null;
  explanationLanguage: string; // resolved canonical gloss language
  idempotencyKey?: string; // retry-idempotency of the SAME tap; fresh otherwise
  quotaDay: string; // account-IANA date
  budgetDayKey: string; // UTC day for the global cap
  cost?: number;
  /** Pro accounts (pro_until > now) have NO daily context cap — the preview shares the saved-layer pool,
   *  so it must honor the same Pro bypass. Resolved by the route via isPro(); the global budget still applies. */
  isPro?: boolean;
}

export type ContextPreviewResult =
  | { status: "ready"; meaning: string; previewHandle: string; charged: boolean }
  | { status: "invalid_unit" } // empty / not a word-or-short-phrase
  | { status: "empty_context" }
  | { status: "context_too_large" }
  | { status: "quota_exhausted" }
  | { status: "budget_exhausted" }
  | { status: "conflict"; reason: "fingerprint_mismatch" | "reservation_expired" | "in_progress" }
  | { status: "failed"; reason: ContextValidationFailure | "provider_error" };

/** Stable, NON-reversible request fingerprint (the sentence must never land in a column in plaintext,
 *  even a quota one). A retry of the same tap carries the same fingerprint; key-reuse for a different
 *  request is caught as a mismatch. Hashes EVERY axis that changes the generated answer — unit, text,
 *  gloss language, target language, context language, span — so two requests differing only in (say)
 *  the marked occurrence can't collide on one reservation. Null axes hash as empty fields. The
 *  separators are `\x00` ESCAPES — a literal NUL in source makes the file binary-invisible to review
 *  (it has happened twice; see NUL-byte footgun). */
async function previewFingerprint(req: {
  unit: string;
  contextText: string;
  explanationLanguage: string;
  targetLanguage: string;
  contextLanguage: string | null;
  spanStart: number | null;
  spanEnd: number | null;
}): Promise<string> {
  const parts = [
    req.unit,
    req.contextText,
    req.explanationLanguage,
    req.targetLanguage,
    req.contextLanguage ?? "",
    req.spanStart === null ? "" : String(req.spanStart),
    req.spanEnd === null ? "" : String(req.spanEnd),
  ];
  const data = new TextEncoder().encode(parts.join("\x00"));
  // Bare `crypto` = the Workers Web Crypto global (this function has no `crypto` param to shadow it).
  const digest = await crypto.subtle.digest("SHA-256", data);
  const hex = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
  return `preview:${hex}:${CONTEXT_PROMPT_VERSION}`;
}

/** Normalize a span to both-null or a valid non-negative start<=end pair (never throw the CHECK). */
function normalizeSpan(ss?: number | null, se?: number | null): { start: number | null; end: number | null } {
  const ok = Number.isInteger(ss) && Number.isInteger(se) && (ss as number) >= 0 && (se as number) >= (ss as number);
  return ok ? { start: ss as number, end: se as number } : { start: null, end: null };
}

export async function explainContextPreview(
  deps: ContextPreviewDeps,
  req: ContextPreviewRequest,
): Promise<ContextPreviewResult> {
  const { sql, crypto, provider, budget, config } = deps;
  const cost = req.cost ?? 1;

  const unit = req.surfaceUnit.normalize("NFC").trim();
  if (unit.length === 0 || !unitWithinBounds(unit)) return { status: "invalid_unit" };
  const text = req.contextText.normalize("NFC");
  if (text.trim().length === 0) return { status: "empty_context" };
  if (text.length > MAX_CONTEXT_CHARS) return { status: "context_too_large" };
  // Canonicalize-or-drop the (optional) context language at the chokepoint: only a real BCP-47 value
  // is hashed / sent to the prompt / stored — junk degrades to "unknown", never to a wrong label.
  const contextLanguage = req.contextLanguage == null ? null : canonicalizeBcp47(req.contextLanguage);
  // Normalize the span ONCE; the same pair feeds the fingerprint, the provider, and the stored row
  // (the prompt re-validates it against the text's content before marking — see resolveMarkedRange).
  const span = normalizeSpan(req.spanStart, req.spanEnd);

  // Reserve the per-user daily slot (shared with the saved context layer — ONE 10/day pool). The
  // fingerprint is content-derived so a key reused for a different request is rejected.
  const fingerprint = await previewFingerprint({
    unit,
    contextText: text,
    explanationLanguage: req.explanationLanguage,
    targetLanguage: req.targetLanguage,
    contextLanguage,
    spanStart: span.start,
    spanEnd: span.end,
  });
  const idempotencyKey = req.idempotencyKey ?? deps.newId();
  // Pro lifts the shared daily cap entirely (a bound no live-count reaches); the global budget still applies.
  const dailyCap = req.isPro ? Number.MAX_SAFE_INTEGER : config.contextDailyCap;
  const reserved = await reserveContextQuota(sql, {
    userId: req.userId,
    wordContextId: null, // a preview is not bound to a context row (it doesn't exist yet)
    requestFingerprint: fingerprint,
    quotaDay: req.quotaDay,
    idempotencyKey,
    dailyCap,
    ttlMs: config.reservationTtlMs,
    now: deps.now(),
    newId: deps.newId,
  });
  if (reserved.status === "cap_exceeded") return { status: "quota_exhausted" };
  if (reserved.status === "fingerprint_mismatch") return { status: "conflict", reason: "fingerprint_mismatch" };
  if (reserved.status === "reservation_expired") return { status: "conflict", reason: "reservation_expired" };
  if (reserved.status === "idempotent_replay") return { status: "conflict", reason: "in_progress" };

  // Reserve the global AI-spend cap (fail-closed). On miss, refund the per-user slot.
  const gb = await budget.reserve(req.budgetDayKey, cost, config.globalDailyBudgetUnits);
  if (!gb.ok) {
    await refundReservation(sql, req.userId, idempotencyKey);
    return { status: "budget_exhausted" };
  }

  // Generate on the RAW (unit, sentence). This sends the sentence off-box (§9) → zero-retention
  // provider only (T8); the sentence is never logged.
  let raw;
  try {
    raw = await provider.generate({
      unit,
      targetLanguage: req.targetLanguage,
      contextText: text,
      // Only ever the client's script-certain value — NEVER defaulted to the target (the languages
      // genuinely diverge: a zh-Hans unit captured in an English article). Unknown = the prompt says
      // "the text below" and lets the model read the text.
      contextLanguage,
      explanationLanguage: req.explanationLanguage,
      spanStart: span.start,
      spanEnd: span.end,
    });
  } catch {
    await budget.refund(req.budgetDayKey, cost); // transport error ⇒ no spend
    await refundReservation(sql, req.userId, idempotencyKey);
    deps.observe?.({ outcome: "failed", target: req.targetLanguage, gloss: req.explanationLanguage, reason: "provider_error" });
    return { status: "failed", reason: "provider_error" };
  }

  const validated = validateContextExplanation(raw);
  if (!validated.ok) {
    await refundReservation(sql, req.userId, idempotencyKey); // not charged for a non-answer
    deps.observe?.({ outcome: "failed", target: req.targetLanguage, gloss: req.explanationLanguage, reason: validated.reason });
    return { status: "failed", reason: validated.reason };
  }

  // Store the ephemeral preview (sentence + gloss encrypted) BEFORE committing, so a crash between
  // the two leaves a usable (if uncharged) preview rather than a charge with no result.
  const id = deps.newId();
  const ctxEnv = await crypto.seal(text, previewContextAad(id));
  const stored: StoredGloss = { ...validated.value, explanationLanguage: req.explanationLanguage };
  const glossEnv = await crypto.seal(JSON.stringify(stored), previewGlossAad(id));
  const startNow = deps.now();
  await sql
    .prepare(
      `INSERT INTO context_previews
         (id, user_id, surface_unit, target_language, context_language, span_start, span_end,
          context_ciphertext, context_wrapped_key, context_nonce, context_key_version,
          gloss_ciphertext, gloss_wrapped_key, gloss_nonce, gloss_key_version,
          explanation_language, prompt_version, created_at, expires_at, adopted_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)`,
    )
    .bind(
      id,
      req.userId,
      unit,
      req.targetLanguage,
      contextLanguage,
      span.start,
      span.end,
      ctxEnv.ciphertext as SqlValue,
      ctxEnv.wrappedKey as SqlValue,
      ctxEnv.nonce as SqlValue,
      ctxEnv.keyVersion,
      glossEnv.ciphertext as SqlValue,
      glossEnv.wrappedKey as SqlValue,
      glossEnv.nonce as SqlValue,
      glossEnv.keyVersion,
      req.explanationLanguage,
      stored.promptVersion,
      startNow,
      startNow + config.previewTtlMs,
    )
    .run();

  // Commit with a FRESH timestamp (a generation that outran the reservation TTL fails the CAS — the
  // preview is still stored + adoptable, the user just isn't charged).
  const charged = await commitReservation(sql, req.userId, idempotencyKey, deps.now());
  deps.observe?.({ outcome: "generated", target: req.targetLanguage, gloss: req.explanationLanguage, charged });
  return {
    status: "ready",
    meaning: validated.value.meaning,
    previewHandle: id,
    charged,
  };
}

// --- adoption (Save) + sweep (dismiss) -------------------------------------------

interface PreviewRow {
  id: string;
  user_id: string;
  surface_unit: string;
  context_ciphertext: Uint8Array | ArrayBuffer | null;
  context_wrapped_key: Uint8Array | ArrayBuffer | null;
  context_nonce: Uint8Array | ArrayBuffer | null;
  context_key_version: number | null;
  gloss_ciphertext: Uint8Array | ArrayBuffer | null;
  gloss_wrapped_key: Uint8Array | ArrayBuffer | null;
  gloss_nonce: Uint8Array | ArrayBuffer | null;
  gloss_key_version: number | null;
}

function toBytes(v: Uint8Array | ArrayBuffer | null): Uint8Array | null {
  if (v == null) return null;
  return v instanceof Uint8Array ? v : new Uint8Array(v);
}

function envelopeOf(
  ciphertext: Uint8Array | ArrayBuffer | null,
  wrappedKey: Uint8Array | ArrayBuffer | null,
  nonce: Uint8Array | ArrayBuffer | null,
  keyVersion: number | null,
): Envelope | null {
  const c = toBytes(ciphertext);
  const w = toBytes(wrappedKey);
  const n = toBytes(nonce);
  if (!c || !w || !n || keyVersion == null) return null;
  return { ciphertext: c, wrappedKey: w, nonce: n, keyVersion };
}

export interface AdoptPreviewInput {
  userId: string;
  previewHandle: string;
  /** the newly-created word_context to attach the adopted gloss to */
  contextId: string;
  now: number;
}

/**
 * Adopt a preview's gloss onto a freshly-saved word_context — the no-recharge bridge from the
 * capture-time preview to the persisted layer. Idempotent + guarded:
 *  - owner-scoped + not-already-adopted;
 *  - the preview's sentence MUST match the target context's sentence (never move a gloss generated
 *    for one sentence onto a different one);
 *  - re-seals the gloss under the target context's gloss AAD and stores it via the same TOCTOU-guarded
 *    path the live layer uses.
 * Returns false (no throw) on any miss, so a Save with a stale/foreign handle simply doesn't adopt.
 */
export async function adoptPreview(sql: Sql, crypto: EnvelopeCrypto, input: AdoptPreviewInput): Promise<boolean> {
  const preview = await sql
    .prepare(
      `SELECT id, user_id, surface_unit, context_ciphertext, context_wrapped_key, context_nonce, context_key_version,
              gloss_ciphertext, gloss_wrapped_key, gloss_nonce, gloss_key_version
         FROM context_previews
        WHERE id = ? AND user_id = ? AND adopted_at IS NULL AND expires_at > ?`,
    )
    .bind(input.previewHandle, input.userId, input.now)
    .first<PreviewRow>();
  if (!preview) return false;

  const target = await getContextRow(sql, input.userId, input.contextId);
  if (!target || target.context_nonce == null) return false;

  // The gloss is UNIT-specific (the meaning describes this exact unit), so never move it onto a context
  // whose word is a different unit — even within the same sentence. Owner + sentence + TTL are checked
  // too; this completes the scope so a buggy/crafted client can't mis-attach a paid gloss across units
  // (the honest client already keys the handle on the unit, so this never rejects a real adopt).
  const word = await getWordById(sql, input.userId, target.word_id);
  if (!word || word.surface_unit.normalize("NFC").trim() !== preview.surface_unit.normalize("NFC").trim()) {
    return false;
  }

  // The gloss is only valid for the sentence it was generated against.
  const ctxEnv = envelopeOf(preview.context_ciphertext, preview.context_wrapped_key, preview.context_nonce, preview.context_key_version);
  const glossEnv = envelopeOf(preview.gloss_ciphertext, preview.gloss_wrapped_key, preview.gloss_nonce, preview.gloss_key_version);
  if (!ctxEnv || !glossEnv) return false;
  const previewSentence = await crypto.open(ctxEnv, previewContextAad(preview.id));
  const targetSentence = await decryptContextText(crypto, target);
  if (previewSentence.normalize("NFC") !== targetSentence.normalize("NFC")) return false;

  let stored: StoredGloss;
  try {
    stored = JSON.parse(await crypto.open(glossEnv, previewGlossAad(preview.id))) as StoredGloss;
  } catch {
    return false;
  }

  const wrote = await storeGloss(sql, crypto, input.userId, input.contextId, stored, target.context_nonce);
  if (!wrote) return false;

  // Mark adopted (idempotent — the WHERE excludes an already-adopted row).
  await sql
    .prepare(`UPDATE context_previews SET adopted_at = ? WHERE id = ? AND user_id = ? AND adopted_at IS NULL AND expires_at > ?`)
    .bind(input.now, input.previewHandle, input.userId, input.now)
    .run();
  return true;
}

/** Delete expired previews (dismiss = let it TTL-expire). Idempotent; safe on any cron cadence. */
export async function sweepExpiredPreviews(sql: Sql, now: number): Promise<number> {
  const r = await sql.prepare(`DELETE FROM context_previews WHERE expires_at <= ?`).bind(now).run();
  return r.rowsWritten;
}
