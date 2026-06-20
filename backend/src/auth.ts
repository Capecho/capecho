import type { Sql } from "./sql.ts";

// Account provisioning + session tokens (M3 auth). Identity is established by verifying a
// provider credential (see auth-verifier.ts); this module turns a VerifiedIdentity into a
// durable account row and an opaque bearer session. D1 is the source of truth.
//
// Security posture:
//  - The raw session token is returned to the client ONCE and never stored; D1 holds only its
//    SHA-256 hash, so a database dump can't be replayed as live credentials.
//  - resolveSession enforces expiry + revocation AND that the account is not soft-deleted, so a
//    pending-hard-delete account's sessions are inert without a separate revoke pass.

export type AuthProvider = "apple" | "google" | "email";

export interface VerifiedIdentity {
  provider: AuthProvider;
  /** Stable subject id from the provider — the dedup key with the provider (never the email). */
  subject: string;
  email?: string;
}

/** Default session lifetime: 90 days. A Mac/phone stays signed in across a normal usage gap. */
export const DEFAULT_SESSION_TTL_MS = 90 * 24 * 60 * 60 * 1000;

/** Parse SESSION_TTL_MS (plain positive-integer ms) → ttl, falling back to the 90-day default. */
export function parseSessionTtlMs(raw: string | undefined): number {
  if (raw === undefined) return DEFAULT_SESSION_TTL_MS;
  const trimmed = raw.trim();
  if (!/^\d+$/.test(trimmed)) return DEFAULT_SESSION_TTL_MS;
  const n = Number(trimmed);
  return n > 0 ? n : DEFAULT_SESSION_TTL_MS;
}

/** True if `tz` is a resolvable IANA timezone (Intl throws on garbage). */
export function isValidIanaTimeZone(tz: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

// --- tokens ------------------------------------------------------------------

/** A 256-bit random bearer token, base64url (no padding) — ~43 chars, URL/header safe. */
export function generateSessionToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return base64UrlEncode(bytes);
}

/** SHA-256 of the raw token, lowercase hex — what we store + look up by. */
export async function hashToken(rawToken: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(rawToken));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function base64UrlEncode(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// --- accounts ----------------------------------------------------------------

export interface UpsertAccountInput {
  provider: AuthProvider;
  subject: string;
  /** Validated IANA tz (used only on first create; an existing account keeps its stored tz). */
  timezone: string;
  /** Canonical BCP-47 default target (first create only); null to leave unset. */
  learningLanguage?: string | null;
  /** The account's email (Settings identity). For the email provider this equals `subject`; for
   *  Apple/Google it's the token's `email` claim (may be absent → private relay / not shared). */
  email?: string | null;
}

/**
 * Find-or-create the account for a verified (provider, subject). Idempotent on the
 * `UNIQUE (auth_provider, provider_subject)` index. Returns the account id.
 *
 * Re-signing in RESURRECTS a soft-deleted (pending-hard-delete) account — `deleted_at` is
 * cleared, cancelling the T8 deletion window — because actively authenticating is an explicit
 * "I'm back". The conflict path deliberately does NOT clobber the stored timezone /
 * learning_language with possibly-different values from this sign-in; those are first-create only.
 * Email is FILL-IF-NULL: a re-sign-in supplies it only if it was missing, so a later token without
 * the claim (Apple shares the relay email only sometimes) can never erase a stored identity.
 */
export async function getOrCreateAccount(
  sql: Sql,
  input: UpsertAccountInput,
  now: number,
  newId: () => string,
): Promise<string> {
  await sql
    .prepare(
      // New accounts default to "explanation follows learning" (immersion default, §9) — the column's
      // schema default is 0 (so EXISTING accounts keep their explicit explanation_language); a fresh
      // account opts into follow with the literal 1 here. Re-sign-in (ON CONFLICT) never touches it.
      `INSERT INTO accounts (id, auth_provider, provider_subject, iana_timezone, learning_language, email, created_at, explanation_follows_learning)
       VALUES (?, ?, ?, ?, ?, ?, ?, 1)
       ON CONFLICT (auth_provider, provider_subject) DO UPDATE SET
         deleted_at = NULL,
         email = COALESCE(accounts.email, excluded.email)`,
    )
    .bind(newId(), input.provider, input.subject, input.timezone, input.learningLanguage ?? null, input.email ?? null, now)
    .run();
  const row = await sql
    .prepare(`SELECT id FROM accounts WHERE auth_provider = ? AND provider_subject = ?`)
    .bind(input.provider, input.subject)
    .first<{ id: string }>();
  // The upsert just guaranteed the row exists; the read-back is how we learn the canonical id
  // (the generated id is discarded on a conflict).
  return row!.id;
}

// --- sessions ----------------------------------------------------------------

export interface IssuedSession {
  /** Raw bearer token — returned to the client ONCE; never persisted. */
  token: string;
  expiresAt: number;
}

/** Mint a session for `userId`, store its hash, return the raw token + expiry. */
export async function issueSession(
  sql: Sql,
  userId: string,
  now: number,
  ttlMs: number,
): Promise<IssuedSession> {
  const token = generateSessionToken();
  const tokenHash = await hashToken(token);
  const expiresAt = now + ttlMs;
  await sql
    .prepare(
      `INSERT INTO sessions (token_hash, user_id, created_at, expires_at, last_seen_at)
       VALUES (?, ?, ?, ?, ?)`,
    )
    .bind(tokenHash, userId, now, expiresAt, now)
    .run();
  return { token, expiresAt };
}

/**
 * Resolve a raw bearer token to its account id, or null. Active = not revoked, not past
 * expiry, AND the owning account is not soft-deleted (a pending-hard-delete account's sessions
 * are inert). Constant work regardless of validity beyond the single indexed lookup.
 */
export async function resolveSession(sql: Sql, rawToken: string, now: number): Promise<string | null> {
  if (!rawToken) return null;
  const tokenHash = await hashToken(rawToken);
  const row = await sql
    .prepare(
      `SELECT s.user_id AS user_id
         FROM sessions s
         JOIN accounts a ON a.id = s.user_id
        WHERE s.token_hash = ?
          AND s.revoked_at IS NULL
          AND s.expires_at > ?
          AND a.deleted_at IS NULL`,
    )
    .bind(tokenHash, now)
    .first<{ user_id: string }>();
  return row?.user_id ?? null;
}

/** Revoke (sign out) a session by its raw token. Idempotent; returns whether a row flipped. */
export async function revokeSession(sql: Sql, rawToken: string, now: number): Promise<boolean> {
  if (!rawToken) return false;
  const tokenHash = await hashToken(rawToken);
  const r = await sql
    .prepare(`UPDATE sessions SET revoked_at = ? WHERE token_hash = ? AND revoked_at IS NULL`)
    .bind(now, tokenHash)
    .run();
  return r.rowsWritten === 1;
}

/** Delete expired (and already-revoked) sessions. Run from the scheduled sweep. Returns count. */
export async function purgeExpiredSessions(sql: Sql, now: number): Promise<number> {
  const r = await sql
    .prepare(`DELETE FROM sessions WHERE expires_at <= ? OR revoked_at IS NOT NULL`)
    .bind(now)
    .run();
  return r.rowsWritten;
}
