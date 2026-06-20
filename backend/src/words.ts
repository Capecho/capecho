import { canonicalizeBcp47 } from "@capecho/lang";
import { dedupKey, DEDUP_VERSION } from "./dedup-key.ts";
import { unitWithinBounds } from "./input.ts";
import type { Sql } from "./sql.ts";

export type ExplanationState = "pending" | "ready" | "language_unsupported" | "failed";

export interface WordRow {
  id: string;
  user_id: string;
  target_language: string;
  surface_unit: string;
  normalized_unit: string;
  target_normalization_version: string;
  is_phrase: number;
  explanation_state: ExplanationState;
  explanation_cache_key: string | null;
  fsrs_epoch: number;
  created_at: number;
  updated_at: number;
  deleted_at: number | null;
}

const COLS =
  "id, user_id, target_language, surface_unit, normalized_unit, target_normalization_version, is_phrase, explanation_state, explanation_cache_key, fsrs_epoch, created_at, updated_at, deleted_at";

export type SaveWordOutcome =
  | { status: "invalid_target_language" }
  | { status: "empty_unit" }
  | { status: "unit_too_large" }
  | { status: "cap_reached" } // free saved-word cap hit on a NET-NEW save (not Pro); no row created
  | { status: "created" | "deduped" | "resurrected"; word: WordRow };

export interface SaveWordInput {
  userId: string;
  surfaceUnit: string;
  /** raw client tag — the server canonicalizes + re-normalizes (authoritative) */
  targetLanguage: string;
  /** free saved-word cap N (config; the route reads freeWordCapFromEnv). A NET-NEW create past N is
   *  blocked for non-Pro accounts (cap_reached); Pro (accounts.pro_until > now) bypasses it, and
   *  resurrect/dedup/restore are always exempt (they touch an existing row, not a net-new insert).
   *  OMITTED ⇒ unlimited (no configured cap) — the cap is a product lever, not a cost control, so an
   *  unconfigured caller fails OPEN (never accidentally locks a user out). Both real routes pass N. */
  freeWordCap?: number;
  now: number;
  newId: () => string;
}

async function getByKey(
  sql: Sql,
  userId: string,
  target: string,
  normalized: string,
): Promise<WordRow | null> {
  return sql
    .prepare(`SELECT ${COLS} FROM words WHERE user_id = ? AND target_language = ? AND normalized_unit = ?`)
    .bind(userId, target, normalized)
    .first<WordRow>();
}

/**
 * POST /words — create + server-authoritative dedup. The dedup key is
 * (user_id, target_language, normalized_unit); the unique index covers tombstones,
 * so a resave that lands on a tombstone RESURRECTS the same row and resets FSRS to
 * new-card (bumps fsrs_epoch — issue #4 / ENG-4). Classification is exact under
 * concurrent resaves: the create is `ON CONFLICT DO NOTHING` and the resurrect is
 * guarded by `deleted_at IS NOT NULL`, so a second racer falls through to dedup
 * (no double-create, no double-epoch-bump). Active+active context merge is M3.
 */
export async function saveWord(sql: Sql, input: SaveWordInput): Promise<SaveWordOutcome> {
  const canonical = canonicalizeBcp47(input.targetLanguage);
  if (canonical === null) return { status: "invalid_target_language" };

  const normalized = dedupKey(input.surfaceUnit);
  const surface = (input.surfaceUnit ?? "").normalize("NFC");
  if (normalized.length === 0 || surface.trim().length === 0) return { status: "empty_unit" };
  // A saved unit is a word or a short phrase, never a paragraph (§13) — the same
  // server-authoritative bound the free /explain layer enforces, so a captured
  // sentence can't be smuggled in as a "word" through the save path.
  if (!unitWithinBounds(normalized)) return { status: "unit_too_large" };

  const isPhrase = /\s/u.test(normalized) ? 1 : 0;
  const id = input.newId();
  // Omitted cap ⇒ unlimited: a bound no realistic live-count reaches (the COUNT < cap is always true).
  const cap = input.freeWordCap ?? Number.MAX_SAFE_INTEGER;

  // Cap-gated create: the row is inserted ONLY if the account is Pro OR under the free cap, folded into
  // the INSERT…SELECT…WHERE so the cap can't be raced past (the COUNT is evaluated atomically with the
  // insert — exactly one of two concurrent net-new creates at N-1 succeeds, mirroring quota.ts). The
  // cap gates net-new rows only; resurrect/dedup below operate on an EXISTING row and are cap-exempt.
  const ins = await sql
    .prepare(
      `INSERT INTO words
         (id, user_id, target_language, surface_unit, normalized_unit, target_normalization_version, is_phrase, explanation_state, fsrs_epoch, created_at, updated_at)
       SELECT ?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?
       WHERE (
         COALESCE((SELECT pro_until FROM accounts WHERE id = ?), 0) > ?
         OR (SELECT COUNT(*) FROM words WHERE user_id = ? AND deleted_at IS NULL) < ?
       )
       ON CONFLICT (user_id, target_language, normalized_unit) DO NOTHING`,
    )
    .bind(
      id,
      input.userId,
      canonical,
      surface,
      normalized,
      DEDUP_VERSION,
      isPhrase,
      input.now,
      input.now,
      input.userId, // pro_until subquery
      input.now, // pro_until > now
      input.userId, // live-count subquery
      cap, // count < cap
    )
    .run();

  if (ins.rowsWritten === 1) {
    return { status: "created", word: (await getByKey(sql, input.userId, canonical, normalized))! };
  }

  // Nothing inserted: either the dedup key already exists (→ resurrect/dedup, cap-exempt) or the cap
  // blocked a net-new create. Resurrect IFF it's a tombstone; the guard makes this a no-op for an
  // already-active row (→ dedup) and idempotent under a resurrect race. Cap-free by construction.
  const res = await sql
    .prepare(
      `UPDATE words SET deleted_at = NULL, fsrs_epoch = fsrs_epoch + 1, surface_unit = ?, is_phrase = ?, updated_at = ?
       WHERE user_id = ? AND target_language = ? AND normalized_unit = ? AND deleted_at IS NOT NULL`,
    )
    .bind(surface, isPhrase, input.now, input.userId, canonical, normalized)
    .run();

  const word = await getByKey(sql, input.userId, canonical, normalized);
  // No existing row AND the insert didn't fire ⇒ the cap blocked this net-new create (guardrail #1:
  // an at-cap free user can still resurrect/dedup, which would have found a row here).
  if (word === null) return { status: "cap_reached" };
  return { status: res.rowsWritten === 1 ? "resurrected" : "deduped", word };
}

/** The FSRS card projection joined onto a unit for the Word Book memory meter. `null` for a unit
 *  with no card at its CURRENT epoch (a never-reviewed new card, or a freshly-resurrected unit).
 *  These are server-authoritative; clients render them, never recompute (mirrors /review/due). */
export interface FsrsCardProjection {
  stability: number;
  difficulty: number;
  due_at: number;
  state: string; // 'new' | 'learning' | 'review' | 'relearning'
  reps: number;
  lapses: number;
  last_review_at: number | null;
}

export interface WordListRow extends WordRow {
  /** Per-unit FSRS state for the memory meter; null until the unit has been reviewed at this epoch. */
  fsrs: FsrsCardProjection | null;
}

// listWords joins fsrs_cards at the unit's CURRENT epoch only. The join predicate carries
// `c.card_epoch = w.fsrs_epoch` (NOT a WHERE clause) so a stale projection — left behind when a
// delete→resave bumped fsrs_epoch — yields a NULL card (the resurrected unit reads as new), exactly
// as /review/due treats it (review.ts). A never-reviewed unit has no row at all → also NULL.
type WordListJoinRow = WordRow & {
  fsrs_stability: number | null;
  fsrs_difficulty: number | null;
  fsrs_due_at: number | null;
  fsrs_state: string | null;
  fsrs_reps: number | null;
  fsrs_lapses: number | null;
  fsrs_last_review_at: number | null;
};

/** GET /words — active units for a user (word book + sync pull), each with its FSRS card projection
 *  (the memory meter) at the unit's current epoch; `fsrs` is null for a not-yet-reviewed card. */
export async function listWords(sql: Sql, userId: string): Promise<WordListRow[]> {
  const rows = await sql
    .prepare(
      `SELECT w.*,
              c.stability AS fsrs_stability, c.difficulty AS fsrs_difficulty, c.due_at AS fsrs_due_at,
              c.state AS fsrs_state, c.reps AS fsrs_reps, c.lapses AS fsrs_lapses,
              c.last_review_at AS fsrs_last_review_at
         FROM words w
         LEFT JOIN fsrs_cards c
           ON c.word_id = w.id AND c.user_id = w.user_id AND c.card_epoch = w.fsrs_epoch
        WHERE w.user_id = ? AND w.deleted_at IS NULL
        ORDER BY w.created_at ASC, w.id ASC`,
    )
    .bind(userId)
    .all<WordListJoinRow>();

  return rows.map((r) => {
    const {
      fsrs_stability,
      fsrs_difficulty,
      fsrs_due_at,
      fsrs_state,
      fsrs_reps,
      fsrs_lapses,
      fsrs_last_review_at,
      ...word
    } = r;
    // A present projection has all NOT-NULL columns (schema CHECKs); key off due_at + stability.
    const fsrs: FsrsCardProjection | null =
      fsrs_due_at === null || fsrs_stability === null || fsrs_state === null
        ? null
        : {
            stability: fsrs_stability,
            difficulty: fsrs_difficulty ?? 0,
            due_at: fsrs_due_at,
            state: fsrs_state,
            reps: fsrs_reps ?? 0,
            lapses: fsrs_lapses ?? 0,
            last_review_at: fsrs_last_review_at,
          };
    return { ...(word as WordRow), fsrs };
  });
}

export async function getWordById(sql: Sql, userId: string, id: string): Promise<WordRow | null> {
  return sql.prepare(`SELECT ${COLS} FROM words WHERE id = ? AND user_id = ?`).bind(id, userId).first<WordRow>();
}

/** DELETE /words/:id — soft-delete (tombstone). Returns whether a live row was tombstoned. */
export async function softDeleteWord(
  sql: Sql,
  userId: string,
  id: string,
  now: number,
): Promise<boolean> {
  const r = await sql
    .prepare(`UPDATE words SET deleted_at = ?, updated_at = ? WHERE id = ? AND user_id = ? AND deleted_at IS NULL`)
    .bind(now, now, id, userId)
    .run();
  return r.rowsWritten === 1;
}

/**
 * POST /words/:id/restore — clear a tombstone (un-delete). Returns whether a tombstoned row was
 * restored (false = no such id for this user, or it was already active).
 *
 * Restore is "undo my delete", distinct from resurrect-on-resave (saveWord): it PRESERVES the unit's
 * FSRS (fsrs_epoch untouched, so its event history + card projection resume) and its contexts —
 * whereas re-saving the same text onto a tombstone bumps fsrs_epoch and resets to a new card (ENG-4).
 * No collision is possible: the dedup unique index (user_id, target_language, normalized_unit) covers
 * tombstones, so there is at most ONE row per key — restoring it can never clash with a live row.
 */
export async function restoreWord(sql: Sql, userId: string, id: string, now: number): Promise<boolean> {
  const r = await sql
    .prepare(`UPDATE words SET deleted_at = NULL, updated_at = ? WHERE id = ? AND user_id = ? AND deleted_at IS NOT NULL`)
    .bind(now, id, userId)
    .run();
  return r.rowsWritten === 1;
}

// --- explanation-state transitions (driven by the /explain orchestration) --------

export async function markExplanationReady(
  sql: Sql,
  userId: string,
  wordId: string,
  cacheKey: string,
  now: number,
): Promise<void> {
  await sql
    .prepare(`UPDATE words SET explanation_state = 'ready', explanation_cache_key = ?, updated_at = ? WHERE id = ? AND user_id = ?`)
    .bind(cacheKey, now, wordId, userId)
    .run();
}

export async function markExplanationState(
  sql: Sql,
  userId: string,
  wordId: string,
  state: Exclude<ExplanationState, "ready">,
  now: number,
): Promise<void> {
  await sql
    .prepare(`UPDATE words SET explanation_state = ?, updated_at = ? WHERE id = ? AND user_id = ?`)
    .bind(state, now, wordId, userId)
    .run();
}
