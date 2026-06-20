import { test, expect, beforeEach } from "bun:test";
import worker from "../src/index.ts";
import { makeEnv } from "./helpers/worker-env.ts";
import { freshDb } from "./helpers/db.ts";
import { recordBetaSignup, MAX_SOURCE_LEN } from "../src/beta-signup.ts";
import type { Env } from "../src/index.ts";
import type { Sql } from "../src/sql.ts";

const ctx = {} as ExecutionContext;

// --- module: recordBetaSignup -------------------------------------------------

let sql: Sql;
beforeEach(() => {
  ({ sql } = freshDb());
});

const allRows = () =>
  sql
    .prepare(`SELECT email, source, country FROM beta_signups ORDER BY created_at`)
    .all<{ email: string; source: string | null; country: string | null }>();

test("records a normalized email; a repeat is idempotent (keeps the first row)", async () => {
  expect(await recordBetaSignup(sql, { email: "  Reader@Example.com ", now: 1, source: "/", country: "us" })).toEqual({
    status: "added",
  });
  // Same address, different case/whitespace + no source ⇒ no new row, original preserved.
  expect(await recordBetaSignup(sql, { email: "reader@example.com", now: 2, source: "/faq" })).toEqual({
    status: "already",
  });
  const rows = await allRows();
  expect(rows).toHaveLength(1);
  expect(rows[0]).toEqual({ email: "reader@example.com", source: "/", country: "US" });
});

test("rejects an invalid email without inserting", async () => {
  expect(await recordBetaSignup(sql, { email: "not-an-email", now: 1 })).toEqual({ status: "invalid_email" });
  expect(await allRows()).toHaveLength(0);
});

test("normalizes country, drops empties, caps source length", async () => {
  await recordBetaSignup(sql, { email: "a@b.com", now: 1, source: "   ", country: "USA" }); // bad 3-letter ⇒ null
  await recordBetaSignup(sql, { email: "c@d.com", now: 2, source: "x".repeat(MAX_SOURCE_LEN + 50) });
  const rows = await allRows();
  expect(rows[0]).toEqual({ email: "a@b.com", source: null, country: null });
  expect(rows[1]!.source!.length).toBe(MAX_SOURCE_LEN);
});

// --- route: POST /beta-signup (through the real worker.fetch) -----------------

function betaEnv(token: string | null): { env: Env; sql: Sql } {
  const { env, sql } = makeEnv();
  const mut = env as Record<string, unknown>;
  if (token === null) delete mut.BETA_SIGNUP_TOKEN;
  else mut.BETA_SIGNUP_TOKEN = token;
  return { env, sql };
}

function call(env: Env, body: unknown, token?: string): Promise<Response> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (token) headers["x-capecho-beta-token"] = token;
  return worker.fetch(
    new Request("https://api.capecho.test/beta-signup", { method: "POST", headers, body: JSON.stringify(body) }),
    env,
    ctx,
  );
}

test("503 when the shared token is unconfigured (fail closed)", async () => {
  const { env } = betaEnv(null);
  expect((await call(env, { email: "a@b.com" }, "anything")).status).toBe(503);
});

test("401 on a missing or wrong token", async () => {
  const { env } = betaEnv("secret-1");
  expect((await call(env, { email: "a@b.com" })).status).toBe(401);
  expect((await call(env, { email: "a@b.com" }, "wrong")).status).toBe(401);
});

test("stores a valid signup, returns a flat ok, and is idempotent on repeat", async () => {
  const { env, sql: db } = betaEnv("secret-1");
  const r1 = await call(env, { email: "Reader@Example.com", source: "/", country: "gb" }, "secret-1");
  expect(r1.status).toBe(200);
  expect(await r1.json()).toEqual({ status: "ok" });

  const r2 = await call(env, { email: "reader@example.com" }, "secret-1");
  expect(r2.status).toBe(200);
  expect(await r2.json()).toEqual({ status: "ok" }); // same answer ⇒ no membership oracle

  const count = await db.prepare(`SELECT COUNT(*) AS n FROM beta_signups`).first<{ n: number }>();
  expect(Number(count?.n)).toBe(1);
  const row = await db
    .prepare(`SELECT email, source, country FROM beta_signups`)
    .first<{ email: string; source: string | null; country: string | null }>();
  expect(row).toEqual({ email: "reader@example.com", source: "/", country: "GB" });
});

test("400 on a malformed or missing email", async () => {
  const { env } = betaEnv("secret-1");
  expect((await call(env, { email: "nope" }, "secret-1")).status).toBe(400);
  expect((await call(env, {}, "secret-1")).status).toBe(400);
});
