import { SELF } from "cloudflare:test";
import { expect, test } from "vitest";

// Boot check: the real worker entrypoint answers through workerd with the wrangler bindings wired.
test("health responds through real workerd", async () => {
  const res = await SELF.fetch("https://api.capecho.test/health");
  expect(res.status).toBe(200);
  expect(await res.json()).toMatchObject({ ok: true, service: "capecho-backend" });
});
