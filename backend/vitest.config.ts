import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";

// Integration tests run INSIDE workerd (Miniflare) with the REAL bindings from wrangler.jsonc:
// real D1 (the ArrayBuffer BLOB path the bun:sqlite harness can't reach), real R2, and the REAL
// GlobalBudget / SingleFlight Durable Objects (which the in-process harness stubs). This closes the
// ENG-5/T10 gap carried since M1. The fast per-module bun tests still run under `bun test`; these
// `*.integration.ts` files are vitest-only (bun's glob ignores the extension).
export default defineConfig(async () => {
  const migrations = await readD1Migrations(fileURLToPath(new URL("./migrations", import.meta.url)));
  return {
    plugins: [
      cloudflareTest({
        main: "./src/index.ts",
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          // Test-only env. The mock identity verifier + mock AI provider make the full sign-in and
          // /explain-generation flows exercisable locally; a fixed KEK enables the T8 context path;
          // a small anon allowance lets one anon-generation case run. NONE of these are prod values.
          bindings: {
            TEST_MIGRATIONS: migrations,
            DEV_TRUST_MOCK_AUTH: "true",
            DEV_USE_MOCK_PROVIDER: "true",
            CONTEXT_KEK: "YYQScgb5ouuhVg04Oa4Pvnn+F3GiuPIOmAqtKZggxug=",
            CONTEXT_KEK_VERSION: "1",
            ANON_DAILY_GENERATION_UNITS: "5",
            // Small global cap so a single test can exhaust it and assert fail-closed. Per-test
            // isolated storage resets the budget DO between tests, so each test starts fresh at 0.
            GLOBAL_DAILY_BUDGET_UNITS: "2",
            // §14 GATE readout admin token (test-only) so the metrics integration test can read it.
            METRICS_ADMIN_TOKEN: "test-admin-token",
          },
        },
      }),
    ],
    test: {
      include: ["test-integration/**/*.integration.ts"],
      setupFiles: ["./test-integration/apply-migrations.ts"],
    },
  };
});
