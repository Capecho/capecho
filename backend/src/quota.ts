import type { Sql } from "./sql.ts";

// Per-user context-explanation quota = D1 reservation rows (ENG-2), NOT a DO and NOT
// a `used` integer. The daily cap counts live rows = committed ∪ (reserved & unexpired)
// for the (user, quota_day). Reserve-before-generate, commit on success, refund on
// failure; an un-committed 'reserved' row past its TTL stops counting (crash recovery)
// and is swept to 'refunded' lazily. Retries are idempotent on idempotency_key.

export type ReserveOutcome =
  | { status: "reserved"; id: string }
  | { status: "idempotent_replay"; id: string; state: "reserved" | "committed" } // a LIVE replay
  | { status: "reservation_expired"; id: string } // prior reservation lapsed (TTL) or was refunded — not usable
  | { status: "fingerprint_mismatch" } // idempotency_key reused for a DIFFERENT request
  | { status: "cap_exceeded" };

export interface ReserveInput {
  userId: string;
  /** the context being explained (same-owner enforced by the composite FK) */
  wordContextId: string | null;
  /** stable hash of the request; a retry MUST carry the same fingerprint */
  requestFingerprint: string;
  /** 'YYYY-MM-DD' in the account's IANA timezone */
  quotaDay: string;
  idempotencyKey: string;
  dailyCap: number;
  ttlMs: number;
  now: number;
  newId: () => string;
}

interface ReservationRow {
  id: string;
  request_fingerprint: string;
  state: "reserved" | "committed" | "refunded";
  expires_at: number;
}

/** The cap-count: committed rows + still-valid reservations for the (user, day). */
export async function countLiveReservations(
  sql: Sql,
  userId: string,
  quotaDay: string,
  now: number,
): Promise<number> {
  const row = await sql
    .prepare(
      `SELECT COUNT(*) AS n FROM context_quota_reservations
       WHERE user_id = ? AND quota_day = ?
         AND (state = 'committed' OR (state = 'reserved' AND expires_at > ?))`,
    )
    .bind(userId, quotaDay, now)
    .first<{ n: number }>();
  return Number(row?.n ?? 0);
}

export async function reserveContextQuota(sql: Sql, input: ReserveInput): Promise<ReserveOutcome> {
  const id = input.newId();
  const expiresAt = input.now + input.ttlMs;

  // Atomic conditional insert: insert a reservation ONLY if the live count is under
  // cap, in a single statement so the cap can't be raced past. Idempotent retries
  // hit the unique (user_id, idempotency_key) and DO NOTHING.
  const ins = await sql
    .prepare(
      `INSERT INTO context_quota_reservations
         (id, user_id, word_context_id, request_fingerprint, quota_day, idempotency_key, state, expires_at, created_at)
       SELECT ?, ?, ?, ?, ?, ?, 'reserved', ?, ?
       WHERE (
         SELECT COUNT(*) FROM context_quota_reservations
         WHERE user_id = ? AND quota_day = ?
           AND (state = 'committed' OR (state = 'reserved' AND expires_at > ?))
       ) < ?
       ON CONFLICT (user_id, idempotency_key) DO NOTHING`,
    )
    .bind(
      id,
      input.userId,
      input.wordContextId,
      input.requestFingerprint,
      input.quotaDay,
      input.idempotencyKey,
      expiresAt,
      input.now,
      input.userId,
      input.quotaDay,
      input.now,
      input.dailyCap,
    )
    .run();

  if (ins.rowsWritten === 1) return { status: "reserved", id };

  // Nothing inserted: either the idempotency_key already exists (retry / key reuse)
  // or the cap blocked a brand-new key.
  const existing = await sql
    .prepare(
      `SELECT id, request_fingerprint, state, expires_at FROM context_quota_reservations WHERE user_id = ? AND idempotency_key = ?`,
    )
    .bind(input.userId, input.idempotencyKey)
    .first<ReservationRow>();

  if (!existing) return { status: "cap_exceeded" };
  if (existing.request_fingerprint !== input.requestFingerprint) return { status: "fingerprint_mismatch" };
  // Liveness-aware replay: only a committed row (work already done) or a still-valid
  // reservation is usable. A reserved row past its TTL, or a refunded one, no longer
  // counts toward the cap (countLiveReservations ignores it), so returning it as a
  // live reservation would grant quota-free generation — surface it as expired instead
  // so the caller re-reserves with a fresh idempotency_key.
  if (existing.state === "committed") return { status: "idempotent_replay", id: existing.id, state: "committed" };
  if (existing.state === "reserved" && existing.expires_at > input.now) {
    return { status: "idempotent_replay", id: existing.id, state: "reserved" };
  }
  return { status: "reservation_expired", id: existing.id };
}

/** Commit a reservation after a successful generation. */
export async function commitReservation(
  sql: Sql,
  userId: string,
  idempotencyKey: string,
  now: number,
): Promise<boolean> {
  // Commit only a STILL-LIVE reservation. A reservation past its TTL has already been
  // freed for other requests (countLiveReservations ignores it), so committing it would
  // let committed rows exceed the daily cap. A failed guard means the slot
  // lapsed — the caller must refund/abandon and re-reserve.
  const r = await sql
    .prepare(
      `UPDATE context_quota_reservations SET state = 'committed', committed_at = ?
       WHERE user_id = ? AND idempotency_key = ? AND state = 'reserved' AND expires_at > ?`,
    )
    .bind(now, userId, idempotencyKey, now)
    .run();
  return r.rowsWritten === 1;
}

/** Refund a reservation (failed generation) so it doesn't consume the user's day. */
export async function refundReservation(sql: Sql, userId: string, idempotencyKey: string): Promise<boolean> {
  const r = await sql
    .prepare(
      `UPDATE context_quota_reservations SET state = 'refunded'
       WHERE user_id = ? AND idempotency_key = ? AND state = 'reserved'`,
    )
    .bind(userId, idempotencyKey)
    .run();
  return r.rowsWritten === 1;
}

/** Lazily reclaim expired reservations (cron / opportunistic). Cap-count already ignores them. */
export async function sweepExpiredReservations(sql: Sql, now: number): Promise<number> {
  const r = await sql
    .prepare(`UPDATE context_quota_reservations SET state = 'refunded' WHERE state = 'reserved' AND expires_at <= ?`)
    .bind(now)
    .run();
  return r.rowsWritten;
}
