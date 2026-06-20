import type { Sql } from "./sql.ts";
import { normalizeEmail, isValidEmail } from "./email-otp.ts";

// Beta-waitlist capture (pure logic; HTTP/secret-gate lives in index.ts). The marketing site is the
// only caller — via the same-origin /api/beta-signup proxy — so this module just normalizes, validates,
// and idempotently records the address. D1 (beta_signups) is the source of truth.
//
// Reuses the email-otp normalize/validate so a waitlist address and a later sign-in resolve to the
// SAME normalized form (a visitor who joins as "A@B.com " and signs in as "a@b.com" is one identity).

/** Bound the attribution string so an oversized client value can't bloat the row. */
export const MAX_SOURCE_LEN = 96;

export type BetaSignupResult =
  | { status: "added" }
  | { status: "already" }
  | { status: "invalid_email" };

export interface BetaSignupInput {
  /** Raw email as received (normalized here). */
  email: string;
  now: number;
  /** Landing-page path / referrer slug (attribution only); trimmed + length-capped, or null. */
  source?: string | null;
  /** cf-ipcountry (2-letter); upper-cased + validated, or null. */
  country?: string | null;
}

/**
 * Record a waitlist signup. Idempotent on the normalized email (PRIMARY KEY + ON CONFLICT DO NOTHING):
 * a repeat keeps the original row (and its first-seen `created_at` / `source`), returning "already".
 * The caller answers ok for both "added" and "already" so the endpoint never reveals list membership.
 */
export async function recordBetaSignup(sql: Sql, input: BetaSignupInput): Promise<BetaSignupResult> {
  const email = normalizeEmail(input.email);
  if (!isValidEmail(email)) return { status: "invalid_email" };

  const res = await sql
    .prepare(
      `INSERT INTO beta_signups (email, created_at, source, country) VALUES (?, ?, ?, ?)
       ON CONFLICT (email) DO NOTHING`,
    )
    .bind(email, input.now, shortOrNull(input.source, MAX_SOURCE_LEN), countryOrNull(input.country))
    .run();
  return res.rowsWritten > 0 ? { status: "added" } : { status: "already" };
}

function shortOrNull(v: string | null | undefined, max: number): string | null {
  if (typeof v !== "string") return null;
  const t = v.trim();
  return t.length === 0 ? null : t.slice(0, max);
}

function countryOrNull(v: string | null | undefined): string | null {
  if (typeof v !== "string") return null;
  const t = v.trim().toUpperCase();
  return /^[A-Z]{2}$/.test(t) ? t : null;
}
