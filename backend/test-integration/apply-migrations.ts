import { applyD1Migrations, env, reset } from "cloudflare:test";
import { beforeEach } from "vitest";

// Per-test pristine slate. vitest-pool-workers 0.16 has no automatic per-test isolation, so we
// `reset()` (wipes D1 + R2 + every Durable Object's storage — notably the shared GlobalBudget DO,
// which would otherwise accumulate spend across tests) and then re-apply the real migrations to
// rebuild the schema. Cheap on in-memory SQLite. This is the SAME migration set wrangler applies
// to production, so the integration tests run against the real, current schema.
beforeEach(async () => {
  await reset();
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});
