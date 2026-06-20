import type { Sql } from "./sql.ts";
import { purgeExpiredDeletedAccounts } from "./accounts.ts";
import { sweepExpiredReservations } from "./quota.ts";
import { sweepExpiredPreviews } from "./context-preview.ts";
import { purgeExpiredSessions } from "./auth.ts";
import { purgeExpiredEmailCodes, purgeExpiredEmailSendCounters } from "./email-otp.ts";

// Scheduled maintenance (the cron `scheduled()` handler). These two sweeps activate primitives
// that already exist but had no runner — without the cron, deleted-account data is never
// actually purged (a T8/privacy commitment) and crashed reserve-before-generate rows never
// refund (a user could stay wrongly capped). Both jobs are idempotent and pure-D1 (no DO/R2),
// so the orchestration is fully unit-testable.

/** Account hard-delete retention window (T8): an account marked deleted is purged after this
 *  elapses. Overridable via the DELETE_RETENTION_MS Worker var. */
export const DEFAULT_DELETE_RETENTION_MS = 30 * 24 * 60 * 60 * 1000; // 30 days

/**
 * Parse the DELETE_RETENTION_MS override into a safe retention window. This value gates an
 * IRREVERSIBLE hard-delete, so parsing is STRICT — only a plain positive-integer string is
 * honored; anything absent, malformed, or zero falls back to the 30-day default. In particular
 * `parseInt` is NOT used: it would accept `"30d"` → 30 (ms!), `"2.6e9"` → 2, `"0x10"` → 0, and
 * `"0"` would zero the window — any of which silently purges deleted accounts almost immediately.
 * A misconfigured var must fail SAFE (keep the full window).
 */
export function parseRetentionMs(raw: string | undefined): number {
  if (raw === undefined) return DEFAULT_DELETE_RETENTION_MS;
  const trimmed = raw.trim();
  if (!/^\d+$/.test(trimmed)) return DEFAULT_DELETE_RETENTION_MS; // not a plain non-negative integer
  const n = Number(trimmed);
  return n > 0 ? n : DEFAULT_DELETE_RETENTION_MS; // reject 0 (= purge-everything-now)
}

export interface SweepResult {
  purgedAccounts: number; // accounts past the retention window, hard-deleted (cascades ciphertext + glosses)
  refundedReservations: number; // expired 'reserved' quota rows reclaimed
  purgedPreviews: number; // expired context-explanation previews deleted (E2; dismiss = TTL-expire)
  purgedSessions: number; // expired/revoked session tokens removed
  purgedEmailCodes: number; // expired sign-in OTP codes removed
  purgedEmailSendCounters: number; // expired per-day email send-abuse counters removed
}

/**
 * Run the scheduled sweeps:
 *  - hard-delete accounts whose deletion window has elapsed (cutoff = now - retentionMs);
 *  - refund quota reservations whose TTL has passed;
 *  - delete expired/revoked session tokens (inert already, but don't accumulate forever).
 * Returns counts for an observability log line. Safe to run on any cadence (idempotent).
 */
export async function runScheduledSweeps(sql: Sql, now: number, retentionMs: number): Promise<SweepResult> {
  const purgedAccounts = await purgeExpiredDeletedAccounts(sql, now - retentionMs);
  const refundedReservations = await sweepExpiredReservations(sql, now);
  const purgedPreviews = await sweepExpiredPreviews(sql, now);
  const purgedSessions = await purgeExpiredSessions(sql, now);
  const purgedEmailCodes = await purgeExpiredEmailCodes(sql, now);
  const purgedEmailSendCounters = await purgeExpiredEmailSendCounters(sql, now);
  return { purgedAccounts, refundedReservations, purgedPreviews, purgedSessions, purgedEmailCodes, purgedEmailSendCounters };
}
