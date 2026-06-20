import type { Sql } from "./sql.ts";

// Email sign-in via one-time code (M3). The user requests a code (startEmailCode), receives it
// by email (see mailer.ts), and submits it (verifyEmailCode) to mint the SAME bearer session as
// the OIDC providers — see the route wiring + getOrCreateAccount(provider:"email", subject:email)
// in index.ts. D1 is the source of truth; this module is the pure code lifecycle, kept free of
// HTTP/mailer concerns so it is fully unit-testable (now + code are injected).
//
// Security posture (mirrors auth.ts sessions):
//  - The raw code is NEVER stored; the row holds SHA-256(email:code). A 6-digit code is trivially
//    brute-forced OFFLINE, so the hash is defense-in-depth + log hygiene, NOT the primary control.
//  - The real controls against ONLINE guessing are: a short expiry, a per-code attempt cap (then a
//    hard lockout that deletes the code), single-active-code per email, and a per-email resend
//    throttle. Together they bound an attacker to a handful of guesses per minute per address.

/** A sign-in code is good for 10 minutes. Long enough to switch to the mail app, short enough to
 *  keep the online-guessing window tiny. */
export const DEFAULT_CODE_TTL_MS = 10 * 60 * 1000;
/** Minimum spacing between code emails to one address (anti-resend-spam / email-bombing). */
export const DEFAULT_RESEND_THROTTLE_MS = 60 * 1000;
/** Failed verify attempts allowed on a single code before it is burned (forces a new code). */
export const DEFAULT_MAX_ATTEMPTS = 5;

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/** Trim + Unicode-NFKC + lowercase. The normalized form is the account subject AND the table key,
 *  so "A@B.com " and "a@b.com" — and a decomposed vs composed Unicode spelling of the same address —
 *  are one identity (can't fork into two accounts / two active codes). NFKC before lower-casing folds
 *  compatibility variants so a homoglyph/encoding difference can't split an account. */
export function normalizeEmail(raw: string): string {
  return raw.trim().normalize("NFKC").toLowerCase();
}

/** A pragmatic syntactic check (not full RFC 5321) + a length bound. We don't verify deliverability
 *  here — an undeliverable address simply never yields a usable code. */
export function isValidEmail(email: string): boolean {
  return email.length > 0 && email.length <= 254 && EMAIL_RE.test(email);
}

/** A uniform-ish 6-digit code, zero-padded. The mod bias over a 2^32 draw is < 1 in 4000 per code
 *  and irrelevant against a 5-attempt cap. */
export function generateOtpCode(): string {
  const draw = crypto.getRandomValues(new Uint32Array(1))[0] ?? 0;
  return (draw % 1_000_000).toString().padStart(6, "0");
}

/** SHA-256(email:code), lowercase hex — what we store + compare. Salting with the (normalized)
 *  email keeps one global rainbow table from covering every address at once. */
export async function hashCode(email: string, code: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${email}:${code}`));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export type StartResult = { ok: true } | { ok: false; reason: "throttled" };

export interface StartInput {
  email: string; // already normalized
  code: string; // the freshly generated plaintext code (hashed before storage)
  now: number;
  ttlMs?: number;
  throttleMs?: number;
}

/**
 * Store a fresh code for `email`, REPLACING any prior active code (one-active-code invariant) and
 * resetting the attempt counter. Refuses (without touching the row) if the current code was issued
 * within the resend-throttle window, so a caller can't spam an address with codes.
 */
export async function startEmailCode(sql: Sql, input: StartInput): Promise<StartResult> {
  const throttleMs = input.throttleMs ?? DEFAULT_RESEND_THROTTLE_MS;
  const existing = await sql
    .prepare(`SELECT created_at FROM email_codes WHERE email = ?`)
    .bind(input.email)
    .first<{ created_at: number }>();
  if (existing && input.now - existing.created_at < throttleMs) return { ok: false, reason: "throttled" };

  const codeHash = await hashCode(input.email, input.code);
  const expiresAt = input.now + (input.ttlMs ?? DEFAULT_CODE_TTL_MS);
  await sql
    .prepare(
      `INSERT INTO email_codes (email, code_hash, created_at, expires_at, attempts)
       VALUES (?, ?, ?, ?, 0)
       ON CONFLICT (email) DO UPDATE SET
         code_hash = excluded.code_hash,
         created_at = excluded.created_at,
         expires_at = excluded.expires_at,
         attempts = 0`,
    )
    .bind(input.email, codeHash, input.now, expiresAt)
    .run();
  return { ok: true };
}

export type VerifyResult =
  | { ok: true }
  | { ok: false; reason: "no_code" | "expired" | "too_many_attempts" | "mismatch" };

export interface VerifyInput {
  email: string; // already normalized
  code: string;
  now: number;
  maxAttempts?: number;
}

/**
 * Check a submitted code against the stored one. On success the code is CONSUMED (deleted) so it
 * can't be replayed. Expired / exhausted codes are burned on sight (the user must request a new one).
 * Reasons are returned for the route to map to status codes; the route deliberately does NOT echo
 * `mismatch` vs `no_code` to the client (no oracle for which addresses have a pending code).
 *
 * The attempt cap is enforced by an ATOMIC guarded increment (`UPDATE … WHERE attempts < cap AND
 * not-expired`), not a read-then-write: that single statement is the gate, so K concurrent verifies
 * can land at most `maxAttempts` increments — i.e. at most `maxAttempts` guesses per code — even
 * under a burst. A non-atomic check-then-increment would let every concurrent request pass a stale
 * `attempts` read and try a guess, multiplying the brute-force budget by the concurrency.
 */
export async function verifyEmailCode(sql: Sql, input: VerifyInput): Promise<VerifyResult> {
  const maxAttempts = input.maxAttempts ?? DEFAULT_MAX_ATTEMPTS;
  // Atomically claim one guess slot: increment ONLY while under the cap and unexpired.
  const claim = await sql
    .prepare(`UPDATE email_codes SET attempts = attempts + 1 WHERE email = ? AND attempts < ? AND expires_at > ?`)
    .bind(input.email, maxAttempts, input.now)
    .run();

  if (claim.rowsWritten === 0) {
    // No slot claimed: the row is missing, expired, or already at the cap. Disambiguate for the
    // caller and burn an expired / exhausted code so a fresh one is required.
    const row = await sql
      .prepare(`SELECT expires_at FROM email_codes WHERE email = ?`)
      .bind(input.email)
      .first<{ expires_at: number }>();
    if (!row) return { ok: false, reason: "no_code" };
    await clearEmailCode(sql, input.email);
    return { ok: false, reason: input.now >= row.expires_at ? "expired" : "too_many_attempts" };
  }

  // Slot claimed (attempt counted) → compare against the stored hash.
  const row = await sql
    .prepare(`SELECT code_hash FROM email_codes WHERE email = ?`)
    .bind(input.email)
    .first<{ code_hash: string }>();
  if (!row) return { ok: false, reason: "mismatch" }; // raced with a concurrent consume — treat as a miss
  if ((await hashCode(input.email, input.code)) !== row.code_hash) return { ok: false, reason: "mismatch" };
  await clearEmailCode(sql, input.email); // success ⇒ consume (single-use)
  return { ok: true };
}

/** Remove the active code for an address (consume on success, burn on lockout/expiry, or undo a
 *  code whose email failed to send so the user can retry without waiting out the throttle). */
export async function clearEmailCode(sql: Sql, email: string): Promise<void> {
  await sql.prepare(`DELETE FROM email_codes WHERE email = ?`).bind(email).run();
}

/** Delete expired codes. Run from the scheduled sweep (they're inert once expired). Returns count. */
export async function purgeExpiredEmailCodes(sql: Sql, now: number): Promise<number> {
  const r = await sql.prepare(`DELETE FROM email_codes WHERE expires_at <= ?`).bind(now).run();
  return r.rowsWritten;
}

// --- send abuse control -------------------------------------------------------
// The per-email resend throttle above does nothing against a caller sweeping MANY distinct
// recipients, so /auth/email/start — unauthenticated, one real outbound send per call — would be an
// email-bomb + Resend cost / sender-reputation DoS. These coarse counters bound code emails per IP
// and globally per UTC day; the route fails closed once either trips. The cap counts ATTEMPTS (it
// increments before the verdict), which is the right abuse signal and errs strict.

/** Max code emails attributable to one IP per UTC day (override: EMAIL_PER_IP_DAILY_CAP). Set high
 *  enough that a shared egress IP (office / university / CGNAT aggregating many users) isn't
 *  collectively locked out, while the global cap remains the real cost ceiling (CR P3). */
export const DEFAULT_EMAIL_PER_IP_DAILY_CAP = 50;
/** Max code emails across ALL callers per UTC day — the hard cost/abuse ceiling (override:
 *  EMAIL_GLOBAL_DAILY_CAP). Tune to your Resend plan. */
export const DEFAULT_EMAIL_GLOBAL_DAILY_CAP = 1000;
/** Keep day-bucket counters ~2 days so the cron can sweep them well after the day rolls over. */
export const EMAIL_COUNTER_TTL_MS = 2 * 24 * 60 * 60 * 1000;

/** Parse a positive-integer cap override (Worker var); anything malformed / non-positive ⇒ fallback. */
export function parseSendCap(raw: string | undefined, fallback: number): number {
  if (raw === undefined) return fallback;
  const t = raw.trim();
  if (!/^\d+$/.test(t)) return fallback;
  const n = Number(t);
  return n > 0 ? n : fallback;
}

export type SendLimitResult = { ok: true } | { ok: false; reason: "ip_capped" | "global_capped" };

export interface SendLimitInput {
  /** cf-connecting-ip; null in dev/local (no edge header) ⇒ only the global cap applies. */
  ip: string | null;
  dayKey: string; // UTC day bucket (time.ts utcDayKey)
  now: number;
  perIpCap?: number;
  globalCap?: number;
}

/** Increment a day-bucket counter and return its new value (one atomic upsert; the read-back is a
 *  separate statement, but a coarse abuse counter tolerates a 1-off race at the boundary). */
async function bumpSendCounter(sql: Sql, bucket: string, expiresAt: number): Promise<number> {
  await sql
    .prepare(
      `INSERT INTO email_send_counters (bucket, count, expires_at) VALUES (?, 1, ?)
       ON CONFLICT (bucket) DO UPDATE SET count = count + 1`,
    )
    .bind(bucket, expiresAt)
    .run();
  const row = await sql
    .prepare(`SELECT count FROM email_send_counters WHERE bucket = ?`)
    .bind(bucket)
    .first<{ count: number }>();
  return row?.count ?? 1;
}

/**
 * Account for one code-send attempt against the per-IP and global daily caps. Checks the per-IP
 * bucket FIRST so an IP-capped flood never consumes the shared global budget. Returns not-ok (the
 * route answers 429) once either ceiling is exceeded.
 */
export async function reserveEmailSend(sql: Sql, input: SendLimitInput): Promise<SendLimitResult> {
  const expiresAt = input.now + EMAIL_COUNTER_TTL_MS;
  if (input.ip) {
    const ipCount = await bumpSendCounter(sql, `ip:${input.ip}:${input.dayKey}`, expiresAt);
    if (ipCount > (input.perIpCap ?? DEFAULT_EMAIL_PER_IP_DAILY_CAP)) return { ok: false, reason: "ip_capped" };
  }
  const globalCount = await bumpSendCounter(sql, `global:${input.dayKey}`, expiresAt);
  if (globalCount > (input.globalCap ?? DEFAULT_EMAIL_GLOBAL_DAILY_CAP)) return { ok: false, reason: "global_capped" };
  return { ok: true };
}

/** Delete day-bucket send counters past their retention. Run from the scheduled sweep. Returns count. */
export async function purgeExpiredEmailSendCounters(sql: Sql, now: number): Promise<number> {
  const r = await sql.prepare(`DELETE FROM email_send_counters WHERE expires_at <= ?`).bind(now).run();
  return r.rowsWritten;
}
