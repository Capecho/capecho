import { test, expect, beforeEach } from "bun:test";
import { freshDb, ids, seedAccount } from "./helpers/db.ts";
import {
  parseMetricBatch,
  ingestMetricEvents,
  metricsConfigFromEnv,
  MAX_BATCH,
  MAX_DURATION_MS,
  DEFAULT_METRICS_DAILY_INSERT_CAP,
  type MetricBatch,
} from "../src/metrics.ts";
import type { Sql } from "../src/sql.ts";

let sql: Sql;
let newId: () => string;

beforeEach(async () => {
  ({ sql } = freshDb());
  newId = ids("m");
});

// --- helpers ---------------------------------------------------------------

const completed = (over: Record<string, unknown> = {}) => ({
  eventType: "capture_completed",
  clientRowId: "row-1",
  clientTs: 1000,
  metadata: { selToPanelMs: 120, panelToSaveMs: 3400, totalMs: 3520, source: "ocr", hasContext: true, langOverride: false, ...over },
});

const batch = (events: unknown[], over: Record<string, unknown> = {}): unknown => ({
  installId: "install-A",
  platform: "macos",
  appVersion: "0.29.0.0",
  contractVersion: 1,
  events,
  ...over,
});

const ok = (raw: unknown): MetricBatch => {
  const p = parseMetricBatch(raw);
  if (!p.ok) throw new Error(`expected ok, got ${p.error}: ${p.detail}`);
  return p.value;
};

async function rowCount(): Promise<number> {
  const r = await sql.prepare(`SELECT COUNT(*) AS n FROM metric_events`).first<{ n: number }>();
  return Number(r?.n ?? 0);
}

// --- parse: happy path -----------------------------------------------------

test("parses a valid mixed batch (capture_completed + sync_attempted)", () => {
  const v = ok(batch([completed(), { eventType: "sync_attempted", clientRowId: "row-1", clientTs: 2000, metadata: {} }]));
  expect(v.installId).toBe("install-A");
  expect(v.events).toHaveLength(2);
  expect(v.events[0]!.metadata).toEqual({ selToPanelMs: 120, panelToSaveMs: 3400, totalMs: 3520, source: "ocr", hasContext: true, langOverride: false });
  expect(v.events[1]!.clientRowId).toBe("row-1");
});

test("accepts every event_type in the contract", () => {
  const v = ok(
    batch([
      completed(),
      { eventType: "capture_presented", clientTs: 1, metadata: { selToPanelMs: 90, source: "clipboard" } },
      { eventType: "capture_abandoned", clientTs: 1, metadata: { selToPanelMs: 90 } },
      { eventType: "capture_failed", clientTs: 1, metadata: { errorKind: "permission" } },
      { eventType: "sync_attempted", clientRowId: "r", clientTs: 1, metadata: {} },
      { eventType: "sync_accepted", clientRowId: "r", clientTs: 1, metadata: {} },
    ]),
  );
  expect(v.events).toHaveLength(6);
});

// --- parse: rejections (strict; the contract fixture means a correct client never hits these) ---

test("rejects an unknown metadata key (T8 — only whitelisted fields persist)", () => {
  const p = parseMetricBatch(batch([completed({ secretText: "the user's private sentence" })]));
  expect(p.ok).toBe(false);
  if (!p.ok) expect(p.detail).toContain("unknown metadata key 'secretText'");
});

test("rejects a bad enum value", () => {
  const p = parseMetricBatch(batch([completed({ source: "telepathy" })]));
  expect(p.ok).toBe(false);
});

test("rejects a missing required metadata key", () => {
  const md = { selToPanelMs: 1, panelToSaveMs: 1, totalMs: 1, source: "ocr", hasContext: true }; // no langOverride
  const p = parseMetricBatch(batch([{ eventType: "capture_completed", clientRowId: "r", clientTs: 1, metadata: md }]));
  expect(p.ok).toBe(false);
  if (!p.ok) expect(p.detail).toContain("langOverride");
});

test("rejects a negative duration and an absurd one (bounds, not just type)", () => {
  expect(parseMetricBatch(batch([completed({ selToPanelMs: -5 })])).ok).toBe(false);
  expect(parseMetricBatch(batch([completed({ totalMs: MAX_DURATION_MS + 1 })])).ok).toBe(false);
  expect(parseMetricBatch(batch([completed({ selToPanelMs: 12.5 })])).ok).toBe(false); // non-integer
});

test("rejects a wrong-typed boolean field", () => {
  expect(parseMetricBatch(batch([completed({ hasContext: "yes" })])).ok).toBe(false);
});

test("requires clientRowId on capture_completed and sync_*, forbids it on funnel events", () => {
  expect(parseMetricBatch(batch([{ eventType: "capture_completed", clientTs: 1, metadata: completed().metadata }])).ok).toBe(false);
  expect(parseMetricBatch(batch([{ eventType: "sync_accepted", clientTs: 1, metadata: {} }])).ok).toBe(false);
  expect(parseMetricBatch(batch([{ eventType: "capture_abandoned", clientRowId: "r", clientTs: 1, metadata: { selToPanelMs: 1 } }])).ok).toBe(false);
});

test("rejects an oversized batch, empty events, bad platform, bad contractVersion, missing installId", () => {
  const many = Array.from({ length: MAX_BATCH + 1 }, () => completed());
  expect(parseMetricBatch(batch(many)).ok).toBe(false);
  expect(parseMetricBatch(batch([])).ok).toBe(false);
  expect(parseMetricBatch(batch([completed()], { platform: "windows" })).ok).toBe(false);
  expect(parseMetricBatch(batch([completed()], { contractVersion: 0 })).ok).toBe(false);
  expect(parseMetricBatch(batch([completed()], { installId: "  " })).ok).toBe(false);
});

// --- ingest ----------------------------------------------------------------

test("ingests anonymously (user_id NULL) and stores only whitelisted metadata", async () => {
  const res = await ingestMetricEvents(sql, { userId: null, batch: ok(batch([completed()])), now: 1_000, dailyCap: 100, newId });
  expect(res).toEqual({ accepted: 1, dropped: 0 });
  const row = await sql.prepare(`SELECT * FROM metric_events`).first<Record<string, unknown>>();
  expect(row!.user_id).toBeNull();
  expect(row!.install_id).toBe("install-A");
  expect(row!.event_type).toBe("capture_completed");
  expect(row!.client_row_id).toBe("row-1");
  expect(row!.app_version).toBe("0.29.0.0");
  expect(JSON.parse(row!.metadata as string)).toEqual(completed().metadata);
});

test("attributes to a signed-in account when userId is present", async () => {
  await seedAccount(sql, "u1");
  await ingestMetricEvents(sql, { userId: "u1", batch: ok(batch([completed()])), now: 1_000, dailyCap: 100, newId });
  const row = await sql.prepare(`SELECT user_id FROM metric_events`).first<{ user_id: string }>();
  expect(row!.user_id).toBe("u1");
});

test("the daily insert ceiling is fail-open: accepts up to the cap, drops the rest, tallies both", async () => {
  const three = ok(batch([completed(), completed(), completed()]));
  const res = await ingestMetricEvents(sql, { userId: null, batch: three, now: 1_000, dailyCap: 2, newId });
  expect(res).toEqual({ accepted: 2, dropped: 1 });
  expect(await rowCount()).toBe(2);
  const b = await sql.prepare(`SELECT accepted, dropped FROM metric_ingest_budget`).first<{ accepted: number; dropped: number }>();
  expect(b).toEqual({ accepted: 2, dropped: 1 });

  // Already at cap → a later batch the same UTC day is fully dropped (still no error).
  const more = await ingestMetricEvents(sql, { userId: null, batch: ok(batch([completed()])), now: 2_000, dailyCap: 2, newId });
  expect(more).toEqual({ accepted: 0, dropped: 1 });
  expect(await rowCount()).toBe(2);
});

test("the ceiling is per-UTC-day (a new day starts fresh)", async () => {
  const day1 = Date.UTC(2026, 4, 31, 23, 0, 0); // 2026-05-31
  const day2 = Date.UTC(2026, 5, 1, 1, 0, 0); // 2026-06-01
  await ingestMetricEvents(sql, { userId: null, batch: ok(batch([completed(), completed()])), now: day1, dailyCap: 2, newId });
  const next = await ingestMetricEvents(sql, { userId: null, batch: ok(batch([completed()])), now: day2, dailyCap: 2, newId });
  expect(next).toEqual({ accepted: 1, dropped: 0 });
});

// --- config ----------------------------------------------------------------

test("metricsConfigFromEnv: default + override + malformed-falls-back", () => {
  expect(metricsConfigFromEnv({}).dailyInsertCap).toBe(DEFAULT_METRICS_DAILY_INSERT_CAP);
  expect(metricsConfigFromEnv({ METRICS_DAILY_INSERT_CAP: "5" }).dailyInsertCap).toBe(5);
  expect(metricsConfigFromEnv({ METRICS_DAILY_INSERT_CAP: "abc" }).dailyInsertCap).toBe(DEFAULT_METRICS_DAILY_INSERT_CAP);
});
