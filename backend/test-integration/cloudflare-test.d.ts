import type { D1Migration } from "@cloudflare/vitest-pool-workers";
import type { Env } from "../src/index.ts";

// The worker Env the integration tests see via `cloudflare:test`, plus the migrations binding the
// setup file consumes.
declare module "cloudflare:test" {
  interface ProvidedEnv extends Env {
    TEST_MIGRATIONS: D1Migration[];
  }
}
