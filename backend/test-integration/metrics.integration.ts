import { expect, test } from "vitest";
import { call, signIn } from "./_util.ts";

// §14 metrics ingest + GATE readout, end-to-end through real workerd + D1. Proves the route wiring,
// the anonymous-accepted ingest, the admin gate, and the chain-completeness reconciliation (metric
// events ⋈ claim_records ⋈ live words) — the parts the bun unit tests can't reach (real HTTP + the
// real claim route). Per-test isolated storage → each test starts with a fresh migrated DB.

const ADMIN = "test-admin-token"; // matches vitest.config.ts METRICS_ADMIN_TOKEN
const INSTALL = "install-A";

const completed = (crid: string) => ({
  eventType: "capture_completed",
  clientRowId: crid,
  clientTs: 1,
  metadata: { selToPanelMs: 120, panelToSaveMs: 800, totalMs: 920, source: "ocr", hasContext: true, langOverride: false },
});
const batch = (events: unknown[]) => ({ installId: INSTALL, platform: "macos", appVersion: "test", contractVersion: 1, events });

test("POST /metrics accepts an ANONYMOUS batch (no session)", async () => {
  const res = await call("POST", "/metrics", { body: batch([completed("live-1")]) });
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ accepted: 1, dropped: 0 });
});

test("POST /metrics rejects a malformed event with 400 (strict contract)", async () => {
  const res = await call("POST", "/metrics", { body: batch([{ eventType: "capture_completed", clientRowId: "x", clientTs: 1, metadata: { leak: "private sentence" } }]) });
  expect(res.status).toBe(400);
});

test("GET /metrics/gate requires the admin token", async () => {
  expect((await call("GET", "/metrics/gate")).status).toBe(401);
  expect((await call("GET", "/metrics/gate", { token: "wrong" })).status).toBe(401);
});

test("the gate reconciles chain-completeness against claimed words (E2E through workerd)", async () => {
  const token = await signIn("metrics-user");
  // Claim live-1 → a real word + claim_record (the chain numerator source).
  const claimed = await call("POST", "/words/claim", {
    token,
    body: { install_id: INSTALL, rows: [{ client_row_id: "live-1", surface_unit: "serendipity", target_language: "en" }] },
  });
  expect(claimed.status).toBe(200);

  // Emit a completed capture + the sync funnel: live-1 (→ materialized) and ghost-1 (accepted, never claimed → leak).
  const m = await call("POST", "/metrics", {
    body: batch([
      completed("live-1"),
      { eventType: "sync_attempted", clientRowId: "live-1", clientTs: 1, metadata: {} },
      { eventType: "sync_attempted", clientRowId: "ghost-1", clientTs: 1, metadata: {} },
      { eventType: "sync_accepted", clientRowId: "live-1", clientTs: 1, metadata: {} },
      { eventType: "sync_accepted", clientRowId: "ghost-1", clientTs: 1, metadata: {} },
    ]),
  });
  expect(m.status).toBe(200);

  const gate = await call("GET", "/metrics/gate", { token: ADMIN });
  expect(gate.status).toBe(200);
  const report = (await gate.json()) as {
    platforms: Record<string, { chain: { attempted: number; accepted: number; materialized: number; completenessRate: number }; contextFill: { completed: number }; captureTimeMs: { total: { n: number } } }>;
  };
  const g = report.platforms.macos!;
  expect(g.chain.attempted).toBe(2);
  expect(g.chain.accepted).toBe(2);
  expect(g.chain.materialized).toBe(1); // only live-1 resolves to a LIVE word
  expect(g.chain.completenessRate).toBeCloseTo(0.5, 10);
  expect(g.contextFill.completed).toBe(1);
  expect(g.captureTimeMs.total.n).toBe(1);
});
