import { canonicalizeBcp47, resolveExplanationLanguage, EXPLANATION_LANGUAGES } from "@capecho/lang";
import type { Sql, SqlValue } from "./sql.ts";

// Account lookup + the T8 retention / hard-delete path. Account deletion is a HARD
// delete (purges context ciphertext + private glosses), not soft-delete-forever:
// `accounts.deleted_at` marks the request time; a purge sweep removes accounts past the
// retention window, cascading to words → word_contexts (ciphertext) → reservations →
// fsrs. The delete-account *UX* is M5; this is the architecture (ENG-9 / T8).

export interface AccountRow {
  id: string;
  auth_provider: string; // 'apple' | 'google' | 'email' — the sign-in provider (Settings identity)
  email: string | null; // the account's email; null when the provider shared none (e.g. Apple relay)
  iana_timezone: string;
  explanation_language: string; // the explicit pick (used only when explanation_follows_learning = 0)
  explanation_follows_learning: number; // 0 | 1 — when 1, the effective gloss follows learning_language
  learning_language: string | null;
  reminder_enabled: number; // 0 | 1
  reminder_time: string | null; // local "HH:MM" or null
  pro_until: number | null; // denormalized Pro entitlement horizon (epoch ms); NULL = free. See entitlement.ts
  deleted_at: number | null;
}

export async function getAccount(sql: Sql, userId: string): Promise<AccountRow | null> {
  return sql
    .prepare(
      `SELECT id, auth_provider, email, iana_timezone, explanation_language, explanation_follows_learning, learning_language, reminder_enabled, reminder_time, pro_until, deleted_at FROM accounts WHERE id = ?`,
    )
    .bind(userId)
    .first<AccountRow>();
}

/** A partial preference update for PATCH /account. An absent field is left unchanged. */
export interface AccountPrefsPatch {
  explanationLanguage?: string;
  explanationFollowsLearning?: boolean;
  learningLanguage?: string | null;
  reminderEnabled?: boolean;
  reminderTime?: string | null;
}

/**
 * Partial-update an account's preferences (Settings → PATCH /account). Only the provided fields are
 * written; an empty patch is a no-op (returns false). Never touches a soft-deleted account. Inputs are
 * assumed already validated by the caller (the route checks the language allowlist + the time format).
 */
export async function updateAccountPrefs(
  sql: Sql,
  userId: string,
  patch: AccountPrefsPatch,
): Promise<boolean> {
  const sets: string[] = [];
  const vals: SqlValue[] = [];
  if (patch.explanationLanguage !== undefined) {
    sets.push("explanation_language = ?");
    vals.push(patch.explanationLanguage);
  }
  if (patch.explanationFollowsLearning !== undefined) {
    sets.push("explanation_follows_learning = ?");
    vals.push(patch.explanationFollowsLearning ? 1 : 0);
  }
  if (patch.learningLanguage !== undefined) {
    sets.push("learning_language = ?");
    vals.push(patch.learningLanguage);
  }
  if (patch.reminderEnabled !== undefined) {
    sets.push("reminder_enabled = ?");
    vals.push(patch.reminderEnabled ? 1 : 0);
  }
  if (patch.reminderTime !== undefined) {
    sets.push("reminder_time = ?");
    vals.push(patch.reminderTime);
  }
  if (sets.length === 0) return false;
  const r = await sql
    .prepare(`UPDATE accounts SET ${sets.join(", ")} WHERE id = ? AND deleted_at IS NULL`)
    .bind(...vals, userId)
    .run();
  return r.rowsWritten === 1;
}

interface PatchAccountBody {
  explanation_language?: unknown;
  explanation_follows_learning?: unknown;
  learning_language?: unknown;
  reminder_enabled?: unknown;
  reminder_time?: unknown;
}

const REMINDER_TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/; // 24-hour HH:MM

/**
 * Validate + build an `AccountPrefsPatch` from a raw `PATCH /account` body. Pure (no I/O) so the route's
 * validation is unit-testable. Only the present fields are validated + included; an absent field is left
 * unchanged. `learning_language` accepts a valid BCP-47 tag (canonicalized) OR an explicit `null` to
 * clear it — a structurally-invalid tag is REJECTED, never silently cleared.
 */
export function parseAccountPatch(
  body: unknown,
): { ok: true; patch: AccountPrefsPatch } | { ok: false; detail: string } {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, detail: "a JSON object body is required" };
  }
  const b = body as PatchAccountBody;
  const patch: AccountPrefsPatch = {};

  if (b.explanation_language !== undefined) {
    if (typeof b.explanation_language !== "string") {
      return { ok: false, detail: "explanation_language must be a string" };
    }
    const lang = resolveExplanationLanguage(b.explanation_language);
    if (!lang) {
      return {
        ok: false,
        detail: `explanation_language must be one of ${EXPLANATION_LANGUAGES.join(" | ")}`,
      };
    }
    patch.explanationLanguage = lang;
    // An explicit explanation-language pick turns OFF "follow my learning language" — unless the same
    // body also passes explanation_follows_learning explicitly (handled next, which then wins).
    patch.explanationFollowsLearning = false;
  }

  if (b.explanation_follows_learning !== undefined) {
    if (typeof b.explanation_follows_learning !== "boolean") {
      return { ok: false, detail: "explanation_follows_learning must be a boolean" };
    }
    patch.explanationFollowsLearning = b.explanation_follows_learning;
  }

  if (b.learning_language !== undefined) {
    if (b.learning_language === null) {
      patch.learningLanguage = null;
    } else if (typeof b.learning_language === "string") {
      const ll = canonicalizeBcp47(b.learning_language);
      if (!ll) return { ok: false, detail: "learning_language must be a valid BCP-47 tag or null" };
      patch.learningLanguage = ll;
    } else {
      return { ok: false, detail: "learning_language must be a BCP-47 string or null" };
    }
  }

  if (b.reminder_enabled !== undefined) {
    if (typeof b.reminder_enabled !== "boolean") {
      return { ok: false, detail: "reminder_enabled must be a boolean" };
    }
    patch.reminderEnabled = b.reminder_enabled;
  }

  if (b.reminder_time !== undefined) {
    if (b.reminder_time === null) {
      patch.reminderTime = null;
    } else if (typeof b.reminder_time === "string" && REMINDER_TIME_RE.test(b.reminder_time)) {
      patch.reminderTime = b.reminder_time;
    } else {
      return { ok: false, detail: 'reminder_time must be a 24-hour "HH:MM" string or null' };
    }
  }

  return { ok: true, patch };
}

/** Mark an account for hard deletion (starts the retention window). Idempotent. */
export async function markAccountDeleted(sql: Sql, userId: string, now: number): Promise<boolean> {
  const r = await sql
    .prepare(`UPDATE accounts SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL`)
    .bind(now, userId)
    .run();
  return r.rowsWritten === 1;
}

/**
 * Hard-delete accounts whose deletion window has elapsed (deleted_at <= cutoff). The
 * ON DELETE CASCADE chain purges context ciphertext + private glosses with the account.
 * Returns the number of ACCOUNTS purged — counted before the delete, since a cascade
 * makes `changes` engine-dependent (bun:sqlite counts cascaded rows; D1 may not). Run
 * from a scheduled sweep.
 */
export async function purgeExpiredDeletedAccounts(sql: Sql, cutoff: number): Promise<number> {
  const c = await sql
    .prepare(`SELECT COUNT(*) AS n FROM accounts WHERE deleted_at IS NOT NULL AND deleted_at <= ?`)
    .bind(cutoff)
    .first<{ n: number }>();
  const n = Number(c?.n ?? 0);
  if (n === 0) return 0;
  await sql.prepare(`DELETE FROM accounts WHERE deleted_at IS NOT NULL AND deleted_at <= ?`).bind(cutoff).run();
  return n;
}

/** Immediate hard-delete of one account + all its data (the purge primitive). Returns
 *  whether the account existed (checked before delete — cascade makes `changes`
 *  engine-dependent, so we don't key the result on it). */
export async function hardDeleteAccount(sql: Sql, userId: string): Promise<boolean> {
  const existed = await sql.prepare(`SELECT 1 AS x FROM accounts WHERE id = ?`).bind(userId).first<{ x: number }>();
  if (!existed) return false;
  await sql.prepare(`DELETE FROM accounts WHERE id = ?`).bind(userId).run();
  return true;
}
