import type { Sql } from "./sql.ts";
import { EnvelopeCrypto } from "./crypto.ts";
import { saveWord } from "./words.ts";
import { createContext } from "./contexts.ts";
import { adoptPreview } from "./context-preview.ts";

// Pre-login batch claim (US-SY.1, M3b). Drains locally-captured units into the account.
//
// The ENG-4 merge truth-table is enforced by composing primitives that already encode it:
//   • active+active collision   → saveWord returns "deduped": keeps the canonical unit +
//                                 its FSRS untouched; the claimed context is ADDED (1:N).
//   • claim onto a TOMBSTONE    → saveWord returns "resurrected": clears the tombstone and
//                                 bumps fsrs_epoch (resets FSRS to new-card), contexts kept.
//   • delete wins over a rating → enforced at ingest (a rating on a tombstoned unit is
//                                 rejected), so a claim never races a rating into a deleted unit.
// This module adds the claim-specific concerns: row-level idempotency and context merge.
//
// Idempotency: keyed by (user_id, install_id, client_row_id). Each step is
// idempotent — word dedup, a DETERMINISTIC context id (ON CONFLICT DO NOTHING), and the
// claim-record (PK) written LAST as the completion marker — so a partial-failure retry
// re-claims only un-drained rows and never double-inserts. The upfront claim-record check
// makes a fully-claimed row a true no-op (and stops a retry from resurrecting a unit the
// account has since deleted).

export interface ClaimContextInput {
  text: string;
  contextLanguage?: string | null;
  spanStart?: number | null;
  spanEnd?: number | null;
  /** Capture-source provenance ("where I met this word"), synced with the context. sourceApp +
   *  detectedLanguage[Confidence] are stored plaintext; sourceTitle is encrypted at rest (createContext). */
  sourceApp?: string | null;
  sourceTitle?: string | null;
  detectedLanguage?: string | null;
  detectedLanguageConfidence?: number | null;
  /** E2 adopt-on-save: a still-fresh capture-time preview handle whose already-metered gloss should be
   *  attached to this context (no recharge). Optional — absent for backlog rows captured before any
   *  preview, and a stale/foreign/expired handle simply doesn't adopt. */
  previewHandle?: string | null;
}

export interface ClaimRowInput {
  clientRowId: string;
  surfaceUnit: string;
  targetLanguage: string;
  context?: ClaimContextInput;
}

export type ClaimRowStatus =
  | "created"
  | "deduped"
  | "resurrected"
  | "replayed" // already claimed under this (install, client_row_id) — no-op
  | "invalid_target_language"
  | "empty_unit"
  | "unit_too_large"
  | "cap_reached"; // free saved-word cap hit — row not claimed, stays local (blocked-by-cap, C3)

export interface ClaimRowResult {
  clientRowId: string;
  status: ClaimRowStatus;
  wordId?: string;
  contextStored?: boolean; // present when the row carried a context
  glossAdopted?: boolean; // present when the row carried a preview handle (E2 adopt-on-save)
}

export interface ClaimInput {
  userId: string;
  installId: string;
  rows: ClaimRowInput[];
  /** free saved-word cap N (config) — applied per net-new claim, same as the live save path. Omitted ⇒
   *  unlimited (saveWord's fail-open default); the route always passes the configured N. */
  freeWordCap?: number;
  now: number;
  newId: () => string;
}

/**
 * Deterministic context id so a retry of the same local row can't duplicate its context.
 * Each component is percent-encoded (so a ':' inside install_id/client_row_id can't bleed
 * across the delimiter and collide with a different pair) and the id is anchored on the
 * resolved word_id — a globally-unique uuid scoped to one account. This makes the id
 * collision-safe AND cross-tenant-safe (word_contexts.id is a global PK), and a re-claim
 * whose surface changed (→ a different word) correctly gets its OWN context rather than
 * silently no-op'ing onto the first word.
 */
const claimContextId = (userId: string, installId: string, clientRowId: string, wordId: string): string =>
  `claim:${[userId, installId, clientRowId, wordId].map(encodeURIComponent).join(":")}`;

export async function claimRows(sql: Sql, crypto: EnvelopeCrypto | null, input: ClaimInput): Promise<ClaimRowResult[]> {
  const results: ClaimRowResult[] = [];
  for (const row of input.rows) {
    // No-op a fully-claimed row (idempotent re-claim; also avoids resurrecting a unit the
    // account deleted after the original claim).
    const claimed = await sql
      .prepare(`SELECT word_id FROM claim_records WHERE user_id = ? AND install_id = ? AND client_row_id = ?`)
      .bind(input.userId, input.installId, row.clientRowId)
      .first<{ word_id: string }>();
    if (claimed) {
      results.push({ clientRowId: row.clientRowId, status: "replayed", wordId: claimed.word_id });
      continue;
    }

    // Word: dedup / resurrect precedence lives in saveWord (ENG-4 word/FSRS dimension); the free cap is
    // applied to net-new claims there (resurrect/dedup exempt).
    const out = await saveWord(sql, {
      userId: input.userId,
      surfaceUnit: row.surfaceUnit,
      targetLanguage: row.targetLanguage,
      freeWordCap: input.freeWordCap,
      now: input.now,
      newId: input.newId,
    });
    if (
      out.status === "invalid_target_language" ||
      out.status === "empty_unit" ||
      out.status === "unit_too_large" ||
      out.status === "cap_reached"
    ) {
      // Not claimed — no claim-record written, so the client keeps the row. For cap_reached it stays a
      // local blocked-by-cap capture (C3); the others the client fixes/resends.
      results.push({ clientRowId: row.clientRowId, status: out.status });
      continue;
    }
    const wordId = out.word.id;

    // Context (1:N merge), encrypted at rest. Deterministic id ⇒ retry-idempotent. A
    // context layer requires the KEK; if it's unconfigured we still claim the word but
    // surface contextStored:false rather than failing the whole batch.
    let contextStored: boolean | undefined;
    let glossAdopted: boolean | undefined;
    if (row.context) {
      if (!crypto) {
        // Unreachable via the HTTP handler (it returns 503 upfront when any row carries a
        // context and no KEK is configured); guarded here so a direct caller can't store
        // plaintext. The row's word is still claimed; the context is reported unstored.
        contextStored = false;
      } else {
        const contextId = claimContextId(input.userId, input.installId, row.clientRowId, wordId);
        const ctx = await createContext(sql, crypto, {
          userId: input.userId,
          wordId,
          contextText: row.context.text,
          contextLanguage: row.context.contextLanguage ?? null,
          spanStart: row.context.spanStart ?? null,
          spanEnd: row.context.spanEnd ?? null,
          sourceApp: row.context.sourceApp ?? null,
          sourceTitle: row.context.sourceTitle ?? null,
          detectedLanguage: row.context.detectedLanguage ?? null,
          detectedLanguageConfidence: row.context.detectedLanguageConfidence ?? null,
          now: input.now,
          newId: input.newId,
          id: contextId,
        });
        contextStored = ctx.status === "created";
        // E2 adopt-on-save: if Save carried a still-fresh preview handle, attach the already-metered
        // gloss to THIS context (no recharge) — the no-recharge bridge from the overlay's capture-time
        // "Explain in this sentence" preview to the persisted Word Book layer. Best-effort + idempotent:
        // adoptPreview owner-scopes the handle, requires the preview's sentence to match this context's
        // sentence, and returns false on any miss (stale/foreign/different-sentence/TTL-expired), so the
        // user simply re-explains from the Word Book in that case. Re-claims short-circuit as "replayed"
        // above, so this only runs on a row's first claim — when the handle is still fresh.
        if (contextStored && row.context.previewHandle) {
          glossAdopted = await adoptPreview(sql, crypto, {
            userId: input.userId,
            previewHandle: row.context.previewHandle,
            contextId,
            now: input.now,
          });
        }
      }
    }

    // Completion marker, written LAST (idempotent).
    await sql
      .prepare(
        `INSERT INTO claim_records (user_id, install_id, client_row_id, word_id, created_at)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT (user_id, install_id, client_row_id) DO NOTHING`,
      )
      .bind(input.userId, input.installId, row.clientRowId, wordId, input.now)
      .run();

    results.push({
      clientRowId: row.clientRowId,
      status: out.status,
      wordId,
      ...(row.context ? { contextStored } : {}),
      ...(glossAdopted !== undefined ? { glossAdopted } : {}),
    });
  }
  return results;
}
