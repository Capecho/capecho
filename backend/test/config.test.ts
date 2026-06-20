import { test, expect } from "bun:test";
import { costConfigFromEnv, DEFAULT_COST_CONFIG } from "../src/config.ts";

test("ANON_DAILY_GENERATION_UNITS env var opens the anon allowance (the deployed wrangler value)", () => {
  // backend/wrangler.jsonc sets this to "500" to open signed-out word generation. Prove the string
  // var flows through to a positive numeric cap — a value > 0 is exactly what flips anon from
  // HIT-only to generating in handleExplain (`anonOpen = ... config.anonDailyGenerationUnits > 0`).
  const cfg = costConfigFromEnv({ ANON_DAILY_GENERATION_UNITS: "500" });
  expect(cfg.anonDailyGenerationUnits).toBe(500);
});

test("anon allowance is default-closed (HIT-only) when the env var is unset (budget-DoS-safe default)", () => {
  const cfg = costConfigFromEnv({});
  expect(cfg.anonDailyGenerationUnits).toBe(0);
  expect(cfg.anonDailyGenerationUnits).toBe(DEFAULT_COST_CONFIG.anonDailyGenerationUnits);
});

test("a malformed ANON_DAILY_GENERATION_UNITS falls back to the safe default, never an open cap", () => {
  // A typo'd / non-numeric / negative deploy var must not silently parse to NaN and open the gate.
  expect(costConfigFromEnv({ ANON_DAILY_GENERATION_UNITS: "abc" }).anonDailyGenerationUnits).toBe(0);
  expect(costConfigFromEnv({ ANON_DAILY_GENERATION_UNITS: "-5" }).anonDailyGenerationUnits).toBe(0);
});
