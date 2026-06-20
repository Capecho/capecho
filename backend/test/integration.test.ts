import { test, expect, beforeEach } from "bun:test";
import worker from "../src/index.ts";
import { makeEnv, type Harness } from "./helpers/worker-env.ts";
import { seedAccount } from "./helpers/db.ts";
import { markAccountDeleted, getAccount } from "../src/accounts.ts";
import type { Env } from "../src/index.ts";

// End-to-end through the real worker.fetch(): router + handlers + SQL + crypto + HTTP responses.

const ctx = {} as ExecutionContext;
const call = (env: Env, path: string, init: RequestInit = {}): Promise<Response> =>
  worker.fetch!(new Request(`https://capecho.test${path}`, init), env, ctx);
const asUser = (u: string, extra: Record<string, string> = {}): Record<string, string> => ({ "x-capecho-user-id": u, ...extra });
const json = (u: string) => asUser(u, { "content-type": "application/json" });
const post = (env: Env, path: string, user: string, body: unknown) =>
  call(env, path, { method: "POST", headers: json(user), body: JSON.stringify(body) });

let h: Harness;
beforeEach(async () => {
  h = makeEnv();
  await seedAccount(h.sql, "u1");
});

test("GET /health is open and identifies the service", async () => {
  const res = await call(h.env, "/health");
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ ok: true, service: "capecho-backend" });
});

test("account-gated routes 401 without a trusted user; an unknown route 404s", async () => {
  expect((await call(h.env, "/words")).status).toBe(401); // no x-capecho-user-id header
  expect((await call(h.env, "/nope")).status).toBe(404);
});

test("POST /words → GET /words round-trips through the real router, handlers, and SQL", async () => {
  const create = await post(h.env, "/words", "u1", { surface_unit: "serendipity", target_language: "en" });
  expect(create.status).toBe(201);
  expect((await create.json()).status).toBe("created");

  const list = await call(h.env, "/words", { headers: asUser("u1") });
  expect(list.status).toBe(200);
  expect((await list.json()).words.map((w: { surface_unit: string }) => w.surface_unit)).toEqual(["serendipity"]);
});

test("POST /words rejects a missing body field (400) and an unsupported target (422)", async () => {
  expect((await post(h.env, "/words", "u1", { surface_unit: "x" })).status).toBe(400); // no target_language
  expect((await post(h.env, "/words", "u1", { surface_unit: "x", target_language: "" })).status).toBe(422);
});

test("GET /explain rejects degenerate junk with 422 not_a_word — never generates (RFC §B), end-to-end", async () => {
  // The junk gate fires at the head — before any auth / anon / spend — so even an anonymous caller
  // (no user header, no provider configured) gets the clean 422 rather than burning a generation.
  const res = await call(h.env, `/explain?unit=${encodeURIComponent("→")}&target=en`);
  expect(res.status).toBe(422);
  expect((await res.json()).error).toBe("not_a_word");
});

test("POST /review → GET /review/due drives the FSRS path through the router", async () => {
  const { word } = await (await post(h.env, "/words", "u1", { surface_unit: "ephemeral", target_language: "en" })).json();
  const rate = await post(h.env, "/review", "u1", { word_id: word.id, event_id: "ev-1", rating: 3, client_review_ts: 1_000 });
  expect(rate.status).toBe(200);
  expect((await rate.json()).status).toBe("applied");

  const due = await call(h.env, "/review/due", { headers: asUser("u1") });
  expect(due.status).toBe(200);
  expect((await due.json())).toHaveProperty("counts");
});

test("GET /export returns a private, no-store CSV download (BOM + header + row)", async () => {
  await post(h.env, "/words", "u1", { surface_unit: "hola", target_language: "es" });
  const res = await call(h.env, "/export", { headers: asUser("u1") });
  expect(res.status).toBe(200);
  expect(res.headers.get("content-type")).toBe("text/csv; charset=utf-8");
  expect(res.headers.get("content-disposition")).toContain('attachment; filename="capecho-export-');
  expect(res.headers.get("cache-control")).toBe("private, no-store"); // 2nd-round review fix, verified end-to-end
  const body = await res.text();
  expect(body.startsWith("\uFEFF")).toBe(true);
  const lines = body.replace(/^\uFEFF/, "").split("\r\n");
  expect(lines[0]).toBe("word,context,context_language,definition,target_language");
  expect(lines[1]).toBe("hola,,,,es");
});

test("GET /export?format=anki returns a TSV with import directives; an unknown format 400s", async () => {
  await post(h.env, "/words", "u1", { surface_unit: "hello", target_language: "en" });
  const anki = await call(h.env, "/export?format=anki", { headers: asUser("u1") });
  expect(anki.status).toBe(200);
  expect(anki.headers.get("content-type")).toBe("text/tab-separated-values; charset=utf-8");
  expect((await anki.text()).split("\n")[0]).toBe("#separator:tab");

  expect((await call(h.env, "/export?format=xlsx", { headers: asUser("u1") })).status).toBe(400);
});

test("context + export fail closed (503) when the envelope KEK is unconfigured", async () => {
  const noKek = makeEnv({ kek: false });
  await seedAccount(noKek.sql, "u1");
  await post(noKek.env, "/words", "u1", { surface_unit: "x", target_language: "en" }); // saving needs no crypto
  expect((await call(noKek.env, "/export", { headers: asUser("u1") })).status).toBe(503);
});

test("POST /contexts → GET /contexts round-trips ENCRYPTED context text through the worker + D1 BLOB shim (T8)", async () => {
  // Exercises the seal→store(BLOB)→read→decrypt path across the real fetch + bunAsD1 shim.
  const { word } = await (await post(h.env, "/words", "u1", { surface_unit: "slide", target_language: "en" })).json();
  const create = await post(h.env, "/contexts", "u1", { word_id: word.id, context_text: "the kids went down the slide" });
  expect(create.status).toBe(201);

  const list = await call(h.env, `/contexts?word_id=${word.id}`, { headers: asUser("u1") });
  expect(list.status).toBe(200);
  const { contexts } = await list.json();
  expect(contexts).toHaveLength(1);
  expect(contexts[0].contextText).toBe("the kids went down the slide"); // decrypted back across the BLOB shim
});

test("the scheduled() cron handler wires env → retention parse → sweeps (purges a deleted account)", async () => {
  await seedAccount(h.sql, "old");
  await markAccountDeleted(h.sql, "old", 1); // deleted at epoch 1 → far past the default 30-day window
  // h.env sets no DELETE_RETENTION_MS, so parseRetentionMs → 30-day default; cutoff = now - 30d ≫ 1.
  await worker.scheduled!({ scheduledTime: Date.now(), cron: "0 3 * * *", noRetry() {} } as ScheduledController, h.env, ctx);
  expect(await getAccount(h.sql, "old")).toBeNull(); // hard-deleted by the cron wrapper
  expect((await getAccount(h.sql, "u1"))?.id).toBe("u1"); // a live account is untouched
});
