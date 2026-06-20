import { test, expect, beforeEach } from "bun:test";
import { freshDb, ids, seedAccount } from "./helpers/db.ts";
import { testCrypto } from "./helpers/crypto.ts";
import { ingestMetricEvents, computeGateReport, percentile, isMetricsAdmin, parseMetricBatch, type MetricBatch } from "../src/metrics.ts";
import { claimRows } from "../src/claim.ts";
import { softDeleteWord } from "../src/words.ts";
import type { Sql } from "../src/sql.ts";
import type { EnvelopeCrypto } from "../src/crypto.ts";

let sql: Sql;
let crypto: EnvelopeCrypto;
let newId: () => string;

beforeEach(async () => {
  ({ sql } = freshDb());
  crypto = await testCrypto();
  newId = ids("g");
  await seedAccount(sql, "u1");
});

// --- percentile (exact nearest-rank) ---------------------------------------

test("percentile: empty → null; single; known vector", () => {
  expect(percentile([], 95)).toBeNull();
  expect(percentile([42], 50)).toBe(42);
  const v = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100];
  expect(percentile(v, 50)).toBe(50); // ceil(.5*10)=5 → idx4
  expect(percentile(v, 95)).toBe(100); // ceil(.95*10)=10 → idx9
  expect(percentile(v, 99)).toBe(100);
  expect(percentile([5, 1, 3, 2, 4], 50)).toBe(3); // sorts internally
});

test("isMetricsAdmin: unset token → never; mismatch → false; exact → true", () => {
  expect(isMetricsAdmin("x", undefined)).toBe(false);
  expect(isMetricsAdmin(null, "secret")).toBe(false);
  expect(isMetricsAdmin("wrong", "secret")).toBe(false);
  expect(isMetricsAdmin("secret", "secret")).toBe(true);
});

// --- computeGateReport -----------------------------------------------------

const INSTALL = "install-A";
const build = (events: unknown[], contractVersion = 1): MetricBatch => {
  const p = parseMetricBatch({ installId: INSTALL, platform: "macos", appVersion: "0.29", contractVersion, events });
  if (!p.ok) throw new Error(`${p.error}: ${p.detail}`);
  return p.value;
};
const emit = (events: unknown[], now = 1000, contractVersion = 1) =>
  ingestMetricEvents(sql, { userId: null, batch: build(events, contractVersion), now, dailyCap: 1_000_000, newId });

const completed = (crid: string, totalMs: number, hasContext: boolean, langOverride: boolean) => ({
  eventType: "capture_completed",
  clientRowId: crid,
  clientTs: 1,
  metadata: { selToPanelMs: 100, panelToSaveMs: totalMs - 100, totalMs, source: "ocr", hasContext, langOverride },
});
const presented = () => ({ eventType: "capture_presented", clientTs: 1, metadata: { selToPanelMs: 100, source: "ocr" } });
const funnel = (t: string) => ({ eventType: t, clientTs: 1, metadata: { selToPanelMs: 100 } });
const syncAtt = (crid: string) => ({ eventType: "sync_attempted", clientRowId: crid, clientTs: 1, metadata: {} });
const syncAcc = (crid: string) => ({ eventType: "sync_accepted", clientRowId: crid, clientTs: 1, metadata: {} });

async function claim(crid: string, surface: string): Promise<string> {
  const [r] = await claimRows(sql, crypto, { userId: "u1", installId: INSTALL, rows: [{ clientRowId: crid, surfaceUnit: surface, targetLanguage: "en" }], now: 1000, newId });
  return r!.wordId!;
}

test("computes all 5 metrics segmented by platform, with the 3-state chain", async () => {
  // captures: live-1 (synced+materialized), local-1 (never submitted)
  await emit([completed("live-1", 3000, true, true), completed("local-1", 5000, false, false)]);
  // 3 lookups shown → 2 saved (above)
  await emit([presented(), presented(), presented()]);
  // funnel extras
  await emit([funnel("capture_abandoned"), { eventType: "capture_failed", clientTs: 1, metadata: { errorKind: "permission" } }]);
  // sync funnel: live-1 (→ materialized), del-1 (claimed then deleted → leak), ghost-1 (never claimed → leak)
  await emit([syncAtt("live-1"), syncAtt("del-1"), syncAtt("ghost-1"), syncAcc("live-1"), syncAcc("del-1"), syncAcc("ghost-1")]);

  await claim("live-1", "alpha"); // live word → materialized
  const delWord = await claim("del-1", "beta");
  await softDeleteWord(sql, "u1", delWord, 1000); // tombstoned → NOT materialized
  // ghost-1 never claimed

  const rep = await computeGateReport(sql, { from: 0, to: 100_000, now: 50_000 });
  const g = rep.platforms.macos!;

  // capture-time: totalMs [3000, 5000]
  expect(g.captureTimeMs.total).toEqual({ p50: 3000, p95: 5000, p99: 5000, n: 2 });
  expect(g.captureTimeMs.selToPanel.n).toBe(2);

  // lookup→save = 2 completed / 3 presented
  expect(g.lookupToSave).toEqual({ presented: 3, completed: 2, rate: 2 / 3 });
  // context-fill = 1 of 2
  expect(g.contextFill).toEqual({ completed: 2, withContext: 1, rate: 0.5 });
  // override = 1 of 2
  expect(g.langOverride).toEqual({ completed: 2, overridden: 1, rate: 0.5 });

  // chain: attempted 3, accepted 3, materialized 1 (only live-1); transport 1.0; completeness 1/3
  expect(g.chain.attempted).toBe(3);
  expect(g.chain.accepted).toBe(3);
  expect(g.chain.materialized).toBe(1);
  expect(g.chain.transportRate).toBe(1);
  expect(g.chain.completenessRate).toBeCloseTo(1 / 3, 10);

  expect(g.funnel).toEqual({ abandoned: 1, failed: 1 });

  // T17 capture→sync: 2 words captured (live-1, local-1); live-1 reached sync_attempted, local-1 never.
  expect(g.captureToSync).toEqual({ capturedWords: 2, synced: 1, neverSynced: 1, syncRate: 0.5 });
  // T15 repeat-lookup: each word captured once → no repeats.
  expect(g.repeatLookup).toEqual({ capturedWords: 2, repeated: 0, rate: 0 });
});

test("repeat-lookup (T15) + never-synced (T17), word-keyed off capture_completed", async () => {
  // 'thrice' captured 3× (a repeat, counted ONCE), 'once' captured once. Only 'thrice' is synced.
  await emit([completed("thrice", 1200, true, false), completed("thrice", 1300, true, false), completed("thrice", 1500, true, false), completed("once", 2000, false, false)]);
  await emit([syncAtt("thrice"), syncAcc("thrice")]);

  const g = (await computeGateReport(sql, { from: 0, to: 100_000, now: 1 })).platforms.macos!;

  // 2 distinct words; 'thrice' captured 3× → counted as 1 repeated word (not 2).
  expect(g.repeatLookup).toEqual({ capturedWords: 2, repeated: 1, rate: 0.5 });
  // 'thrice' reached a sync; 'once' never → 1 never-synced.
  expect(g.captureToSync).toEqual({ capturedWords: 2, synced: 1, neverSynced: 1, syncRate: 0.5 });
  // capture-time counts ALL 4 capture_completed (per-save, not per-word).
  expect(g.captureTimeMs.total.n).toBe(4);
  expect(g.lookupToSave.completed).toBe(4);
});

test("a tombstoned word does NOT count as materialized (accepted-but-deleted = a leak)", async () => {
  await emit([syncAtt("d"), syncAcc("d")]);
  const w = await claim("d", "gamma");
  await softDeleteWord(sql, "u1", w, 1000);
  const g = (await computeGateReport(sql, { from: 0, to: 100_000, now: 1 })).platforms.macos!;
  expect(g.chain.accepted).toBe(1);
  expect(g.chain.materialized).toBe(0); // live word required
  expect(g.chain.completenessRate).toBe(0);
});

test("the window filters by received_at; out-of-window events are excluded", async () => {
  await emit([completed("a", 1000, true, false)], 500); // in window
  await emit([completed("b", 2000, true, false)], 9_000); // out of window
  const g = (await computeGateReport(sql, { from: 0, to: 1_000, now: 1 })).platforms.macos!;
  expect(g.contextFill.completed).toBe(1);
  expect(g.captureTimeMs.total.n).toBe(1);
});

test("an empty store yields no platforms and zeroed ingest", async () => {
  const rep = await computeGateReport(sql, { from: 0, to: 100_000, now: 1 });
  expect(rep.platforms).toEqual({});
  expect(rep.ingest).toEqual({ acceptedTotal: 0, droppedTotal: 0 });
});

test("ingest dropped events surface in the report (data-quality flag)", async () => {
  // cap 1 → second event dropped
  await ingestMetricEvents(sql, { userId: null, batch: build([completed("a", 1000, true, false), completed("b", 2000, true, false)]), now: 1000, dailyCap: 1, newId });
  const rep = await computeGateReport(sql, { from: 0, to: 100_000, now: 1 });
  expect(rep.ingest.acceptedTotal).toBe(1);
  expect(rep.ingest.droppedTotal).toBe(1);
});
