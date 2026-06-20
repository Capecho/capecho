import type { Sql } from "./sql.ts";
import { utcDayKey } from "./time.ts";

// §14 success-metric ingest (CEO-10) — feeds the After-M3 GATE (CEO-7).
//
// The pipeline: macOS client buffers events locally → POSTs a batch here → we validate STRICTLY,
// store only whitelisted fields, and bound abuse on this UNAUTHENTICATED path (anonymous install_id
// is accepted so the pre-login first-capture latency — the aha — is measurable). The gate readout
// (GET /metrics/gate, see index.ts) aggregates these into the 5 metrics.
//
// PRIVACY (T8): an event carries ONLY durations / counts / enums / booleans / opaque ids — never a
// captured unit or context sentence. The validator REBUILDS metadata from the contract (unknown keys
// are rejected, not just ignored), so nothing un-whitelisted can ever persist; the log-hygiene
// round-trip test (test/log-hygiene.test.ts) guards the path.
//
// CONTRACT DRIFT: METRIC_CONTRACT below is the TS source of truth for the event shape; commit 3 pins
// it to a committed fixture that the Dart emitter also asserts against, so a Dart↔TS drift fails CI
// (same posture as the normalization golden vectors / DES-2 token gate).

// capture_completed.client_row_id carries the WORD id, so it shares the id-space of the sync funnel +
// claim_records — that powers the word-keyed funnels (captureToSync / repeatLookup) below.
export const METRIC_CONTRACT_VERSION = 1;
export const MAX_BATCH = 50;
export const MAX_BODY_BYTES = 16 * 1024;
/** Sanity ceiling on any duration field (ms). A monotonic capture span over an hour is junk
 *  (clock glitch / a window left open for hours) → reject rather than poison the percentiles. */
export const MAX_DURATION_MS = 60 * 60 * 1000;

export const DEFAULT_METRICS_DAILY_INSERT_CAP = 1_000_000;

export type MetricEventType =
  | "capture_completed"
  | "capture_presented"
  | "capture_abandoned"
  | "capture_failed"
  | "sync_attempted"
  | "sync_accepted";

const SOURCE_VALUES = ["ocr", "clipboard", "selection"] as const;
const CAPTURE_FAIL_KINDS = ["ocr", "permission", "native", "unknown"] as const;

type FieldSpec =
  | { type: "int"; min: number; max: number }
  | { type: "bool" }
  | { type: "enum"; values: readonly string[] };

interface EventSpec {
  /** capture_completed + sync_* tie to a specific unit; the rest are funnel counts. */
  needsClientRowId: boolean;
  fields: Record<string, FieldSpec>;
}

const MS: FieldSpec = { type: "int", min: 0, max: MAX_DURATION_MS };

/** The metric-event contract. Every listed metadata field is REQUIRED; unknown fields are rejected. */
export const METRIC_CONTRACT: Record<MetricEventType, EventSpec> = {
  // The capture loop, t0=hotkey → t1=overlay present → t2=durable save (all native monotonic clock).
  capture_completed: {
    needsClientRowId: true,
    fields: {
      selToPanelMs: MS, // t1 - t0 (system latency: OCR + reconstruction + present)
      panelToSaveMs: MS, // t2 - t1 (human dwell: edit + confirm)
      totalMs: MS, // t2 - t0 (the spec's headline "capture time")
      source: { type: "enum", values: SOURCE_VALUES },
      hasContext: { type: "bool" }, // normalized client-side (trimmed, non-trivial, != unit)
      langOverride: { type: "bool" }, // final target language != the default shown
    },
  },
  capture_presented: { needsClientRowId: false, fields: { selToPanelMs: MS, source: { type: "enum", values: SOURCE_VALUES } } },
  capture_abandoned: { needsClientRowId: false, fields: { selToPanelMs: MS } },
  capture_failed: { needsClientRowId: false, fields: { errorKind: { type: "enum", values: CAPTURE_FAIL_KINDS } } },
  // Chain-completeness (Issue 2 + 3-state): attempted → accepted (client got 2xx) → materialized
  // (server: claim_records ⋈ LIVE word). accepted-but-not-materialized = the integrity leak.
  sync_attempted: { needsClientRowId: true, fields: {} },
  sync_accepted: { needsClientRowId: true, fields: {} },
};

export interface MetricEvent {
  eventType: MetricEventType;
  clientRowId: string | null;
  clientTs: number;
  metadata: Record<string, number | boolean | string>;
}

export interface MetricBatch {
  installId: string;
  platform: "macos";
  appVersion: string | null;
  contractVersion: number;
  events: MetricEvent[];
}

export type ParseResult<T> = { ok: true; value: T } | { ok: false; error: string; detail: string };

const err = (error: string, detail: string): ParseResult<never> => ({ ok: false, error, detail });

/** Validate (and rebuild) one event's metadata against its contract. Rebuilding — not pass-through —
 *  is the T8 guarantee: only whitelisted fields can persist, even if the caller sent extras. */
function validateMetadata(
  eventType: MetricEventType,
  raw: unknown,
): { ok: true; metadata: Record<string, number | boolean | string> } | { ok: false; detail: string } {
  const spec = METRIC_CONTRACT[eventType];
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return { ok: false, detail: "metadata must be an object" };
  const obj = raw as Record<string, unknown>;
  for (const k of Object.keys(obj)) {
    if (!(k in spec.fields)) return { ok: false, detail: `unknown metadata key '${k}'` };
  }
  const out: Record<string, number | boolean | string> = {};
  for (const [k, fs] of Object.entries(spec.fields)) {
    const v = obj[k];
    if (v === undefined || v === null) return { ok: false, detail: `missing metadata key '${k}'` };
    if (fs.type === "int") {
      if (typeof v !== "number" || !Number.isInteger(v) || v < fs.min || v > fs.max) {
        return { ok: false, detail: `'${k}' must be an integer in [${fs.min}, ${fs.max}]` };
      }
      out[k] = v;
    } else if (fs.type === "bool") {
      if (typeof v !== "boolean") return { ok: false, detail: `'${k}' must be a boolean` };
      out[k] = v;
    } else {
      if (typeof v !== "string" || !fs.values.includes(v)) return { ok: false, detail: `'${k}' must be one of ${fs.values.join("|")}` };
      out[k] = v;
    }
  }
  return { ok: true, metadata: out };
}

/** Strict batch parse: the envelope (install/platform/version) + each event. Any malformed event
 *  fails the whole batch with 400 — the committed contract fixture means a correct client never
 *  hits this, so a rejection is a real client bug we want visible (same posture as parseAccountPatch). */
export function parseMetricBatch(raw: unknown): ParseResult<MetricBatch> {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return err("bad_batch", "body must be an object");
  const b = raw as Record<string, unknown>;
  if (typeof b.installId !== "string" || b.installId.trim() === "") return err("bad_batch", "installId is required");
  if (b.platform !== "macos") return err("bad_batch", "platform must be 'macos'");
  if (typeof b.contractVersion !== "number" || !Number.isInteger(b.contractVersion) || b.contractVersion < 1) {
    return err("bad_batch", "contractVersion must be a positive integer");
  }
  if (b.appVersion !== undefined && b.appVersion !== null && typeof b.appVersion !== "string") {
    return err("bad_batch", "appVersion must be a string");
  }
  if (!Array.isArray(b.events) || b.events.length === 0) return err("bad_batch", "events must be a non-empty array");
  if (b.events.length > MAX_BATCH) return err("batch_too_large", `at most ${MAX_BATCH} events per batch`);

  const events: MetricEvent[] = [];
  for (let i = 0; i < b.events.length; i++) {
    const ev = b.events[i];
    if (typeof ev !== "object" || ev === null || Array.isArray(ev)) return err("bad_event", `event[${i}] must be an object`);
    const e = ev as Record<string, unknown>;
    if (typeof e.eventType !== "string" || !(e.eventType in METRIC_CONTRACT)) return err("bad_event", `event[${i}] has an unknown event_type`);
    const eventType = e.eventType as MetricEventType;
    if (typeof e.clientTs !== "number" || !Number.isInteger(e.clientTs) || e.clientTs < 0) return err("bad_event", `event[${i}] clientTs must be a non-negative integer`);

    const spec = METRIC_CONTRACT[eventType];
    let clientRowId: string | null = null;
    if (spec.needsClientRowId) {
      if (typeof e.clientRowId !== "string" || e.clientRowId.trim() === "") return err("bad_event", `event[${i}] (${eventType}) requires a clientRowId`);
      clientRowId = e.clientRowId;
    } else if (e.clientRowId !== undefined && e.clientRowId !== null) {
      return err("bad_event", `event[${i}] (${eventType}) must not carry a clientRowId`);
    }

    const md = validateMetadata(eventType, e.metadata ?? {});
    if (!md.ok) return err("bad_event", `event[${i}] (${eventType}): ${md.detail}`);
    events.push({ eventType, clientRowId, clientTs: e.clientTs, metadata: md.metadata });
  }

  return {
    ok: true,
    value: {
      installId: b.installId.trim(),
      platform: "macos",
      appVersion: (b.appVersion as string | undefined) ?? null,
      contractVersion: b.contractVersion,
      events,
    },
  };
}

export interface IngestResult {
  accepted: number;
  dropped: number;
}

/**
 * Append a validated batch, bounded by the fail-open daily insert ceiling. The per-event metadata is
 * the already-validated whitelist, re-serialized here so only contract fields persist. `userId` is
 * null for anonymous (pre-login) events. Overshoot-tolerant by design (read-then-insert): this is an
 * abuse ceiling, not a money cap, so a small race overshoot beats the cost of strict serialization.
 */
export async function ingestMetricEvents(
  sql: Sql,
  input: { userId: string | null; batch: MetricBatch; now: number; dailyCap: number; newId: () => string },
): Promise<IngestResult> {
  const { batch } = input;
  const dayKey = utcDayKey(input.now);

  await sql.prepare(`INSERT INTO metric_ingest_budget (day_key) VALUES (?) ON CONFLICT (day_key) DO NOTHING`).bind(dayKey).run();
  const budget = await sql.prepare(`SELECT accepted FROM metric_ingest_budget WHERE day_key = ?`).bind(dayKey).first<{ accepted: number }>();
  const already = Number(budget?.accepted ?? 0);
  const room = Math.max(0, input.dailyCap - already);
  const toAccept = Math.min(room, batch.events.length);
  const dropped = batch.events.length - toAccept;

  for (let i = 0; i < toAccept; i++) {
    const e = batch.events[i]!;
    await sql
      .prepare(
        `INSERT INTO metric_events
           (id, user_id, install_id, platform, event_type, client_row_id, client_ts, received_at, app_version, contract_version, metadata)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(
        input.newId(),
        input.userId,
        batch.installId,
        batch.platform,
        e.eventType,
        e.clientRowId,
        e.clientTs,
        input.now,
        batch.appVersion,
        batch.contractVersion,
        JSON.stringify(e.metadata),
      )
      .run();
  }

  if (toAccept > 0 || dropped > 0) {
    await sql.prepare(`UPDATE metric_ingest_budget SET accepted = accepted + ?, dropped = dropped + ? WHERE day_key = ?`).bind(toAccept, dropped, dayKey).run();
  }
  return { accepted: toAccept, dropped };
}

/** Daily insert ceiling from env (positive integer; malformed → default). */
export function metricsConfigFromEnv(env: { METRICS_DAILY_INSERT_CAP?: string }): { dailyInsertCap: number } {
  const n = env.METRICS_DAILY_INSERT_CAP === undefined ? NaN : Number.parseInt(env.METRICS_DAILY_INSERT_CAP, 10);
  return { dailyInsertCap: Number.isFinite(n) && n >= 0 ? n : DEFAULT_METRICS_DAILY_INSERT_CAP };
}

// === GET /metrics/gate readout (CEO-7) =====================================
// Aggregate the raw events into the 5 §14 metrics, segmented by platform, recomputable at any time
// from the immutable event store (so a verdict never depends on when the code ran). Exact, not
// sampled — the cohort is small. The route layer (index.ts) admin-gates this with METRICS_ADMIN_TOKEN.

/** Exact nearest-rank percentile (p in [0,100]); null on an empty set. Nearest-rank, not
 *  interpolated — a GATE wants "the p95 sample", and it avoids fractional-index ambiguity. */
export function percentile(values: number[], p: number): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const rank = Math.ceil((p / 100) * sorted.length);
  return sorted[Math.min(sorted.length - 1, Math.max(0, rank - 1))]!;
}

const rate = (num: number, den: number): number | null => (den > 0 ? num / den : null);
/** Pair key for a (install_id, client_row_id) tuple — unit-separator joined so a value containing
 *  a common delimiter can't collide across the boundary. */
const pairKey = (installId: string, clientRowId: string): string => `${installId}${clientRowId}`;

export interface DurationStats {
  p50: number | null;
  p95: number | null;
  p99: number | null;
  n: number;
}

export interface PlatformGate {
  // Capture-time split (Issue/finding): total is the spec's headline; selToPanel is the system
  // latency the GATE judges "fast" on; panelToSave is human dwell.
  captureTimeMs: { total: DurationStats; selToPanel: DurationStats; panelToSave: DurationStats };
  lookupToSave: { presented: number; completed: number; rate: number | null };
  contextFill: { completed: number; withContext: number; rate: number | null };
  langOverride: { completed: number; overridden: number; rate: number | null };
  // T17: captured locally but never synced — word-id-keyed capture_completed vs the sync funnel. The
  // product signal "do users actually sync?", NOT chain integrity (that's completenessRate below).
  // Confounded by "hasn't signed in yet" (a signed-out user never syncs) — read with sign-in context.
  captureToSync: { capturedWords: number; synced: number; neverSynced: number; syncRate: number | null };
  // T15 watch: repeat-lookup — a word captured >=2x in the window ("did the first explanation stick?").
  repeatLookup: { capturedWords: number; repeated: number; rate: number | null };
  // 3-state chain: attempted → accepted (transport) → materialized (integrity).
  chain: {
    attempted: number;
    accepted: number;
    materialized: number;
    transportRate: number | null; // accepted / attempted (network health)
    completenessRate: number | null; // materialized / accepted — THE integrity number (target ~1.0)
  };
  funnel: { abandoned: number; failed: number };
}

export interface GateReport {
  windowMs: { from: number; to: number };
  generatedAtMs: number;
  platforms: Record<string, PlatformGate>;
  // Data-quality flag: events the fail-open ceiling dropped. A large droppedTotal means the
  // metrics under-count — read them with caution. Global (not per-platform); not window-scoped.
  ingest: { acceptedTotal: number; droppedTotal: number };
}

const WINDOW = `platform = ? AND received_at >= ? AND received_at <= ?`;

async function countEvents(sql: Sql, eventType: string, platform: string, from: number, to: number): Promise<number> {
  const r = await sql.prepare(`SELECT COUNT(*) AS n FROM metric_events WHERE event_type = ? AND ${WINDOW}`).bind(eventType, platform, from, to).first<{ n: number }>();
  return Number(r?.n ?? 0);
}

/** Distinct (install_id, client_row_id) pairs for an event type within the window, as a key set. */
async function distinctPairs(sql: Sql, eventType: string, platform: string, from: number, to: number): Promise<Set<string>> {
  const rows = await sql
    .prepare(`SELECT DISTINCT install_id AS i, client_row_id AS c FROM metric_events WHERE event_type = ? AND client_row_id IS NOT NULL AND ${WINDOW}`)
    .bind(eventType, platform, from, to)
    .all<{ i: string; c: string }>();
  return new Set(rows.map((r) => pairKey(r.i, r.c)));
}

const stats = (values: number[]): DurationStats => ({ p50: percentile(values, 50), p95: percentile(values, 95), p99: percentile(values, 99), n: values.length });

async function platformGate(sql: Sql, platform: string, from: number, to: number, materialized: Set<string>): Promise<PlatformGate> {
  // capture_completed carries the WORD id on client_row_id (the recorder threads it from the local-store
  // drain), so it shares the id-space of the sync funnel + claim_records. That powers two word-keyed
  // readouts below (captured-but-never-synced + repeat-lookup) on top of the count/metadata metrics.
  const completedRows = await sql
    .prepare(`SELECT install_id AS i, client_row_id AS c, metadata AS m FROM metric_events WHERE event_type = 'capture_completed' AND ${WINDOW}`)
    .bind(platform, from, to)
    .all<{ i: string; c: string | null; m: string }>();

  const total: number[] = [];
  const sel: number[] = [];
  const pan: number[] = [];
  let withContext = 0;
  let overridden = 0;
  // (install, word id) → times that word was captured in the window: |keys| = distinct words captured;
  // a value >=2 = a repeat lookup (T15). Keyed off capture_completed's word-id client_row_id.
  const wordCaptureCounts = new Map<string, number>();
  for (const row of completedRows) {
    const md = JSON.parse(row.m) as Record<string, unknown>;
    if (typeof md.totalMs === "number") total.push(md.totalMs);
    if (typeof md.selToPanelMs === "number") sel.push(md.selToPanelMs);
    if (typeof md.panelToSaveMs === "number") pan.push(md.panelToSaveMs);
    if (md.hasContext === true) withContext++;
    if (md.langOverride === true) overridden++;
    if (row.c) {
      const k = pairKey(row.i, row.c);
      wordCaptureCounts.set(k, (wordCaptureCounts.get(k) ?? 0) + 1);
    }
  }
  const completed = completedRows.length;
  const presented = await countEvents(sql, "capture_presented", platform, from, to);

  const attemptedPairs = await distinctPairs(sql, "sync_attempted", platform, from, to);
  const acceptedPairs = await distinctPairs(sql, "sync_accepted", platform, from, to);
  let materializedCount = 0;
  for (const k of acceptedPairs) if (materialized.has(k)) materializedCount++;

  // T17 capture→sync funnel + T15 repeat-lookup, both word-keyed off capture_completed (above).
  const capturedWords = wordCaptureCounts.size;
  let syncedWords = 0;
  let repeatedWords = 0;
  for (const [k, n] of wordCaptureCounts) {
    if (attemptedPairs.has(k)) syncedWords++; // the user initiated a sync for this captured word
    if (n >= 2) repeatedWords++; // captured again in-window — the first explanation may not have stuck
  }

  return {
    captureTimeMs: { total: stats(total), selToPanel: stats(sel), panelToSave: stats(pan) },
    lookupToSave: { presented, completed, rate: rate(completed, presented) },
    contextFill: { completed, withContext, rate: rate(withContext, completed) },
    langOverride: { completed, overridden, rate: rate(overridden, completed) },
    captureToSync: { capturedWords, synced: syncedWords, neverSynced: capturedWords - syncedWords, syncRate: rate(syncedWords, capturedWords) },
    repeatLookup: { capturedWords, repeated: repeatedWords, rate: rate(repeatedWords, capturedWords) },
    chain: {
      attempted: attemptedPairs.size,
      accepted: acceptedPairs.size,
      materialized: materializedCount,
      transportRate: rate(acceptedPairs.size, attemptedPairs.size),
      completenessRate: rate(materializedCount, acceptedPairs.size),
    },
    funnel: {
      abandoned: await countEvents(sql, "capture_abandoned", platform, from, to),
      failed: await countEvents(sql, "capture_failed", platform, from, to),
    },
  };
}

/** Compute the GATE report over [from, to] (ms, received_at). Chain numerator = sync_accepted pairs
 *  that resolve to a LIVE (non-tombstoned) word via claim_records — accepted-but-not-materialized is
 *  the integrity leak; a tombstoned word does NOT count as materialized. */
export async function computeGateReport(sql: Sql, input: { from: number; to: number; now: number }): Promise<GateReport> {
  const { from, to, now } = input;
  const platforms = (await sql.prepare(`SELECT DISTINCT platform FROM metric_events WHERE received_at >= ? AND received_at <= ?`).bind(from, to).all<{ platform: string }>()).map((r) => r.platform);

  // The global set of (install, client_row_id) that materialized as a LIVE word (any account).
  const matRows = await sql
    .prepare(`SELECT cr.install_id AS i, cr.client_row_id AS c FROM claim_records cr JOIN words w ON w.id = cr.word_id WHERE w.deleted_at IS NULL`)
    .all<{ i: string; c: string }>();
  const materialized = new Set(matRows.map((r) => pairKey(r.i, r.c)));

  const platformReports: Record<string, PlatformGate> = {};
  for (const p of platforms) platformReports[p] = await platformGate(sql, p, from, to, materialized);

  const budget = await sql.prepare(`SELECT COALESCE(SUM(accepted), 0) AS a, COALESCE(SUM(dropped), 0) AS d FROM metric_ingest_budget`).first<{ a: number; d: number }>();
  return {
    windowMs: { from, to },
    generatedAtMs: now,
    platforms: platformReports,
    ingest: { acceptedTotal: Number(budget?.a ?? 0), droppedTotal: Number(budget?.d ?? 0) },
  };
}

/** Constant-time-ish admin-token check for GET /metrics/gate. Returns false when no token is
 *  configured (the readout 401s for everyone — the token IS the gate; there's no admin role). */
export function isMetricsAdmin(presentedToken: string | null, configuredToken: string | undefined): boolean {
  if (!configuredToken || !presentedToken || presentedToken.length !== configuredToken.length) return false;
  let r = 0;
  for (let i = 0; i < presentedToken.length; i++) r |= presentedToken.charCodeAt(i) ^ configuredToken.charCodeAt(i);
  return r === 0;
}
