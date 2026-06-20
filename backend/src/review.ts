import type { Sql } from "./sql.ts";
import { getWordById } from "./words.ts";
import { accountDayStartMs } from "./time.ts";
import { projectCard, type ProjectedCard, type RatingValue, type FoldEvent, type CardStateName } from "./fsrs.ts";

// Server-authoritative review (US-1.2, §11). POST /review ingests a rating event:
// the server assigns the per-user sequence (ORDER), clamps the client timestamp for
// skew + per-card out-of-order (ELAPSED), appends to the event log (the source of
// truth), then RE-FOLDS the card from all its events into the fsrs_cards projection.
// Ingest is idempotent on the client-supplied event id. A soft-deleted unit rejects
// the rating (delete wins over a concurrent rating).

export interface IngestReviewInput {
  userId: string;
  wordId: string;
  eventId: string; // client-generated uuid → idempotent ingest
  rating: RatingValue;
  clientReviewTs: number; // raw client review time (untrusted)
  now: number; // server receive time (the skew-clamp ceiling)
  source?: string; // which surface produced the rating ('app' | 'widget' | 'notification') — attribution only, NOT folded; omitted → 'app'
}

// Bound an untrusted `source` attribution tag to a short string, default 'app'. Lenient — any value
// passes (a future surface like 'standby'/'control' needs no code change) — but length-capped so a
// hostile client can't stuff an oversized blob into the event log. Empty/absent/non-string → 'app'.
const MAX_SOURCE_LEN = 32;
export function normalizeSource(raw: unknown): string {
  return typeof raw === "string" && raw.length > 0 && raw.length <= MAX_SOURCE_LEN ? raw : "app";
}

export type IngestOutcome =
  | { status: "applied"; card: ProjectedCard | null; replay: boolean } // null ⇒ a stale-epoch replay; the live card is unchanged
  | { status: "not_found" } // no such unit for this account
  | { status: "unit_deleted" } // tombstoned unit — delete wins, rating rejected
  | { status: "id_conflict" }; // event id already used by a different user/unit

interface EventIdRow {
  user_id: string;
  word_id: string;
  card_epoch: number;
}

const MAX_SEQ_RETRIES = 6;

/**
 * Re-fold the card from its CURRENT-epoch events and upsert the projection. Always
 * folds at the epoch passed by the caller (the unit's current fsrs_epoch) — never an
 * event's stored epoch — so a stale-epoch replay can't revert a resurrected card.
 * Returns null when there are no current-epoch events (nothing to project; the unit is
 * effectively new), in which case the projection is left untouched.
 *
 * The upsert is MONOTONIC: it only advances when last_applied_seq increases. This makes
 * a concurrent or out-of-order refold idempotent and stops an older fold (lower seq)
 * from clobbering a newer projection that landed first.
 */
async function refoldAndPersist(
  sql: Sql,
  userId: string,
  wordId: string,
  epoch: number,
  createdAtMs: number,
): Promise<ProjectedCard | null> {
  const rows = await sql
    .prepare(
      `SELECT rating, clamped_elapsed, server_seq FROM fsrs_events
       WHERE user_id = ? AND word_id = ? AND card_epoch = ? ORDER BY server_seq ASC`,
    )
    .bind(userId, wordId, epoch)
    .all<{ rating: number; clamped_elapsed: number; server_seq: number }>();
  const events: FoldEvent[] = rows.map((r) => ({ rating: r.rating as RatingValue, elapsedMs: Number(r.clamped_elapsed) }));
  const projected = projectCard(createdAtMs, events);
  if (!projected) return null; // no current-epoch events — leave the projection untouched
  const lastSeq = rows.reduce((m, r) => Math.max(m, Number(r.server_seq)), 0);
  await sql
    .prepare(
      `INSERT INTO fsrs_cards
         (word_id, user_id, card_epoch, stability, difficulty, due_at, last_review_at, reps, lapses, state, last_applied_seq)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (word_id) DO UPDATE SET
         user_id = excluded.user_id, card_epoch = excluded.card_epoch,
         stability = excluded.stability, difficulty = excluded.difficulty,
         due_at = excluded.due_at, last_review_at = excluded.last_review_at,
         reps = excluded.reps, lapses = excluded.lapses, state = excluded.state,
         last_applied_seq = excluded.last_applied_seq
       WHERE excluded.last_applied_seq > fsrs_cards.last_applied_seq`,
    )
    .bind(
      wordId,
      userId,
      epoch,
      projected.stability,
      projected.difficulty,
      projected.dueAt,
      projected.lastReviewAt,
      projected.reps,
      projected.lapses,
      projected.state,
      lastSeq,
    )
    .run();
  return projected;
}

export async function ingestReview(sql: Sql, input: IngestReviewInput): Promise<IngestOutcome> {
  const word = await getWordById(sql, input.userId, input.wordId);
  if (!word) return { status: "not_found" };
  if (word.deleted_at !== null) return { status: "unit_deleted" }; // tombstone wins over a rating
  const epoch = word.fsrs_epoch;

  // Idempotent ingest on the client event id. A replay re-folds (same result); an id
  // reused by a different user/unit is rejected (the PK is global).
  const existing = await sql
    .prepare(`SELECT user_id, word_id, card_epoch FROM fsrs_events WHERE id = ?`)
    .bind(input.eventId)
    .first<EventIdRow>();
  if (existing) {
    if (existing.user_id !== input.userId || existing.word_id !== input.wordId) return { status: "id_conflict" };
    // Refold at the CURRENT epoch (not existing.card_epoch): a duplicate delivery of a
    // pre-resurrect event must not revert the live card to its stale epoch.
    const card = await refoldAndPersist(sql, input.userId, input.wordId, epoch, word.created_at);
    return { status: "applied", card, replay: true };
  }

  // Clamp: a review can't be dated in the future (skew ceiling = server receive time),
  // and elapsed since the previous applied review is floored at 0 (a late out-of-order
  // event contributes no negative interval — §11 / eng-review C4).
  //
  // The baseline is the card's FOLD CLOCK position, i.e. created_at + Σ(clamped_elapsed)
  // over the existing events at this epoch — exactly where projectCard's monotonic clock
  // sits before this event. It is NOT the previous event's own timestamp: after an
  // out-of-order event is floored to 0, the applied clock stays put, so the next review's
  // elapsed must be measured from that held position, not from the late event's earlier
  // client ts (which would over-count). This also subsumes skew — the sum is built from
  // already-clamped values, so a forward-skewed predecessor can't shift the baseline.
  const baseRow = await sql
    .prepare(
      `SELECT COALESCE(SUM(clamped_elapsed), 0) AS s FROM fsrs_events
       WHERE user_id = ? AND word_id = ? AND card_epoch = ?`,
    )
    .bind(input.userId, input.wordId, epoch)
    .first<{ s: number }>();
  const foldClock = word.created_at + Number(baseRow?.s ?? 0);
  const clampedReviewTs = Math.min(input.clientReviewTs, input.now);
  const clampedElapsed = Math.max(0, clampedReviewTs - foldClock);

  // Assign the per-user monotonic sequence and append. Under a concurrent append the
  // unique (user_id, server_seq) can collide — retry with a freshly read max; if the
  // same event id appeared meanwhile, treat it as a replay.
  for (let attempt = 0; ; attempt++) {
    const seqRow = await sql
      .prepare(`SELECT COALESCE(MAX(server_seq), 0) + 1 AS seq FROM fsrs_events WHERE user_id = ?`)
      .bind(input.userId)
      .first<{ seq: number }>();
    const seq = Number(seqRow?.seq ?? 1);
    try {
      await sql
        .prepare(
          `INSERT INTO fsrs_events
             (id, user_id, word_id, card_epoch, server_seq, rating, client_review_ts, clamped_elapsed, created_at, source)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .bind(input.eventId, input.userId, input.wordId, epoch, seq, input.rating, input.clientReviewTs, clampedElapsed, input.now, input.source ?? "app")
        .run();
      break;
    } catch (err) {
      // Did our event id land in the table? It could be our own concurrent replay, OR a
      // DIFFERENT user/unit that raced in after the initial existing-check — so re-check
      // ownership here too (mirror the normal path) instead of blindly treating it as our
      // replay, which would silently drop this review.
      const landed = await sql
        .prepare(`SELECT user_id, word_id FROM fsrs_events WHERE id = ?`)
        .bind(input.eventId)
        .first<{ user_id: string; word_id: string }>();
      if (landed) {
        if (landed.user_id !== input.userId || landed.word_id !== input.wordId) return { status: "id_conflict" };
        // our event landed via a concurrent request — refold at the current epoch (never the stale one).
        const card = await refoldAndPersist(sql, input.userId, input.wordId, epoch, word.created_at);
        return { status: "applied", card, replay: true };
      }
      if (attempt >= MAX_SEQ_RETRIES) throw err; // not a seq race we can recover from
      // else: assume a (user_id, server_seq) collision — loop and re-read the max
    }
  }

  const card = await refoldAndPersist(sql, input.userId, input.wordId, epoch, word.created_at);
  return { status: "applied", card, replay: false };
}

// --- Offline-queue flush (POST /sync) ----------------------------------------

export interface SyncEventInput {
  wordId: string;
  eventId: string;
  rating: RatingValue;
  clientReviewTs: number;
  source: string; // which surface produced the rating; normalized on parse (default 'app')
}

export interface SyncEventResult {
  eventId: string;
  // "invalid" ⇒ structurally malformed (drop/quarantine — resending won't help); "error" ⇒ a
  // transient failure (safe to re-send); the rest are normal per-event ingest outcomes.
  status: IngestOutcome["status"] | "error" | "invalid";
  card?: ProjectedCard | null;
}

/**
 * A queued event after wire-parsing: either a well-formed event ready to ingest, or a
 * structurally-invalid one we keep only to report back — carrying its event id when we could
 * read one, so the client can correlate the result and quarantine the bad event.
 */
export type ParsedSyncEvent = { ok: true; event: SyncEventInput } | { ok: false; eventId: string };

/**
 * Wire-parse + validate ONE queued review event. Pure, never throws. Returns a tagged result so
 * the flush can apply the good events and report `invalid` for the bad ones — a single
 * poison-pill event must not 400 the entire offline-queue flush.
 */
export function parseSyncEvent(raw: unknown): ParsedSyncEvent {
  if (!raw || typeof raw !== "object") return { ok: false, eventId: "" };
  const o = raw as Record<string, unknown>;
  const eventId = typeof o.event_id === "string" ? o.event_id : "";
  if (
    typeof o.word_id !== "string" ||
    typeof o.event_id !== "string" ||
    typeof o.rating !== "number" ||
    !Number.isInteger(o.rating) ||
    o.rating < 1 ||
    o.rating > 4 ||
    typeof o.client_review_ts !== "number" ||
    !Number.isFinite(o.client_review_ts)
  ) {
    return { ok: false, eventId };
  }
  return {
    ok: true,
    event: {
      wordId: o.word_id,
      eventId: o.event_id,
      rating: o.rating as RatingValue,
      clientReviewTs: o.client_review_ts,
      source: normalizeSource(o.source),
    },
  };
}

/**
 * Ordered batch replay of queued rating events (US-12.1: "flush in server sequence").
 * The events are applied in array order, so the per-user server_seq is assigned in the
 * client's intended order; each ingest is idempotent (client event id) and clamps skew /
 * out-of-order exactly as the single-event path. Delete-wins falls out for free: an event
 * for a tombstoned unit returns `unit_deleted`. The client re-pulls authoritative state
 * (GET /words, GET /review/due) after flushing — this endpoint does not echo it.
 *
 * Input is the PARSED queue (one ParsedSyncEvent per wire event, in order): a structurally-
 * invalid event becomes an `invalid` result and is skipped, never aborting the flush, so one
 * poison-pill event can't wedge the client's offline queue behind it.
 */
export async function replayReviews(
  sql: Sql,
  input: { userId: string; events: ParsedSyncEvent[]; now: number },
): Promise<SyncEventResult[]> {
  const results: SyncEventResult[] = [];
  for (const parsed of input.events) {
    // A structurally-malformed event is reported per-event and skipped — it consumes no
    // server_seq and never aborts the flush, so the rest of the offline queue still applies.
    if (!parsed.ok) {
      results.push({ eventId: parsed.eventId, status: "invalid" });
      continue;
    }
    const e = parsed.event;
    // Isolate each event: a throw (e.g. a transient D1 error or seq-retry exhaustion) on
    // one event must not abort the flush and drop the per-event results for the rest. Each
    // ingest is idempotent on the event id, so the client safely re-sends `error` rows.
    try {
      const out = await ingestReview(sql, {
        userId: input.userId,
        wordId: e.wordId,
        eventId: e.eventId,
        rating: e.rating,
        clientReviewTs: e.clientReviewTs,
        now: input.now,
        source: e.source,
      });
      results.push({ eventId: e.eventId, status: out.status, card: out.status === "applied" ? out.card : undefined });
    } catch {
      results.push({ eventId: e.eventId, status: "error" });
    }
  }
  return results;
}

// --- Due selection (GET /review/due) -----------------------------------------

export interface DueCard {
  wordId: string;
  surfaceUnit: string;
  targetLanguage: string;
  state: CardStateName;
  dueAt: number;
  isNew: boolean;
}

export const DEFAULT_NEW_CARD_CAP = 20;

/**
 * Due selection (US-1.2 review-load rules): ALL due reviewed cards, most-overdue first,
 * uncapped; PLUS never-reviewed cards under a soft cap (new cards enter without a manual
 * step). A stale projection (card_epoch != the unit's current fsrs_epoch, e.g. after a
 * resurrect) is excluded from due and the unit re-appears as new.
 *
 * The new-card cap is per-account-DAY (M3b): the budget is `newCardCap` introductions per
 * day, where "today" is the account's IANA-tz local day (rolls over at local midnight,
 * same model as the context quota, US-3.2). A card is "introduced" when its first review
 * (the lowest-server_seq event for the current card_epoch) lands. We count cards already
 * introduced today and surface only `max(0, newCardCap - introducedToday)` new cards, so a
 * client refetching mid-day (or another device) doesn't re-spend the budget. A resurrect
 * bumps the epoch, so a re-saved unit's pre-delete introduction doesn't count against the
 * new epoch (it correctly re-appears as new). `now` carries the rollover instant.
 */
export async function listDueReviews(
  sql: Sql,
  userId: string,
  now: number,
  ianaTimezone: string,
  newCardCap: number = DEFAULT_NEW_CARD_CAP,
): Promise<{ due: DueCard[]; newCards: DueCard[] }> {
  const dueRows = await sql
    .prepare(
      `SELECT c.word_id AS wordId, w.surface_unit AS surfaceUnit, w.target_language AS targetLanguage, c.state AS state, c.due_at AS dueAt
       FROM fsrs_cards c JOIN words w ON w.id = c.word_id AND w.user_id = c.user_id
       WHERE c.user_id = ? AND w.deleted_at IS NULL AND c.card_epoch = w.fsrs_epoch AND c.due_at <= ?
       ORDER BY c.due_at ASC, c.word_id ASC`,
    )
    .bind(userId, now)
    .all<{ wordId: string; surfaceUnit: string; targetLanguage: string; state: CardStateName; dueAt: number }>();

  // How many new cards were already introduced today (account-tz day)? A card counts when
  // its FIRST review (lowest server_seq at the current epoch) was received today. An event's
  // created_at is the server-receive time, always <= now, and now is within today's window,
  // so created_at >= dayStart is sufficient to mean "introduced today" (no upper bound needed).
  const dayStart = accountDayStartMs(now, ianaTimezone);
  const introducedRow = await sql
    .prepare(
      `SELECT COUNT(*) AS n
       FROM words w
       WHERE w.user_id = ? AND w.deleted_at IS NULL
         AND EXISTS (
           SELECT 1 FROM fsrs_events e
           WHERE e.user_id = w.user_id AND e.word_id = w.id AND e.card_epoch = w.fsrs_epoch
             AND e.created_at >= ?
             AND e.server_seq = (
               SELECT MIN(e2.server_seq) FROM fsrs_events e2
               WHERE e2.user_id = w.user_id AND e2.word_id = w.id AND e2.card_epoch = w.fsrs_epoch
             )
         )`,
    )
    .bind(userId, dayStart)
    .first<{ n: number }>();
  const introducedToday = Number(introducedRow?.n ?? 0);
  const remaining = Math.max(0, newCardCap - introducedToday);

  const newRows =
    remaining === 0
      ? []
      : await sql
          .prepare(
            `SELECT w.id AS wordId, w.surface_unit AS surfaceUnit, w.target_language AS targetLanguage
             FROM words w
             WHERE w.user_id = ? AND w.deleted_at IS NULL
               AND NOT EXISTS (SELECT 1 FROM fsrs_cards c WHERE c.word_id = w.id AND c.card_epoch = w.fsrs_epoch)
             ORDER BY w.created_at ASC, w.id ASC
             LIMIT ?`,
          )
          .bind(userId, remaining)
          .all<{ wordId: string; surfaceUnit: string; targetLanguage: string }>();

  return {
    due: dueRows.map((r) => ({
      wordId: r.wordId,
      surfaceUnit: r.surfaceUnit,
      targetLanguage: r.targetLanguage,
      state: r.state,
      dueAt: Number(r.dueAt),
      isNew: false,
    })),
    newCards: newRows.map((r) => ({
      wordId: r.wordId,
      surfaceUnit: r.surfaceUnit,
      targetLanguage: r.targetLanguage,
      state: "new" as CardStateName,
      dueAt: now, // a new card is due immediately
      isNew: true,
    })),
  };
}
