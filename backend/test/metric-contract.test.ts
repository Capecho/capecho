import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { METRIC_CONTRACT, METRIC_CONTRACT_VERSION, MAX_DURATION_MS } from "../src/metrics.ts";

// The TS validator must equal the committed fixture, which the Dart contract also asserts against
// (shared/api-client/test/metric_contract_test.dart) — so a Dart↔TS drift fails CI (ENG-3 posture).
const fixture = JSON.parse(
  readFileSync(fileURLToPath(new URL("../../shared/api-client/fixtures/metric-events-contract.json", import.meta.url)), "utf8"),
) as {
  version: number;
  maxDurationMs: number;
  events: Record<string, { needsClientRowId: boolean; fields: Record<string, { type: string; min?: number; max?: number; values?: string[] }> }>;
};

test("the TS METRIC_CONTRACT matches the committed fixture (Dart↔TS parity anchor)", () => {
  expect(METRIC_CONTRACT_VERSION).toBe(fixture.version);
  expect(MAX_DURATION_MS).toBe(fixture.maxDurationMs);
  expect(new Set(Object.keys(METRIC_CONTRACT))).toEqual(new Set(Object.keys(fixture.events)));

  for (const [type, spec] of Object.entries(fixture.events)) {
    const ts = METRIC_CONTRACT[type as keyof typeof METRIC_CONTRACT] as { needsClientRowId: boolean; fields: Record<string, { type: string; min?: number; max?: number; values?: readonly string[] }> };
    expect(ts.needsClientRowId).toBe(spec.needsClientRowId);
    expect(new Set(Object.keys(ts.fields))).toEqual(new Set(Object.keys(spec.fields)));
    for (const [fname, fj] of Object.entries(spec.fields)) {
      const tf = ts.fields[fname]!;
      expect(tf.type).toBe(fj.type);
      if (fj.type === "int") {
        expect(tf.min).toBe(fj.min);
        expect(tf.max).toBe(fj.max);
      } else if (fj.type === "enum") {
        expect([...(tf.values ?? [])]).toEqual(fj.values ?? []);
      }
    }
  }
});
