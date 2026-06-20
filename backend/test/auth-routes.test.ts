import { test, expect } from "bun:test";
import worker from "../src/index.ts";
import { makeEnv } from "./helpers/worker-env.ts";
import type { Env } from "../src/index.ts";

// End-to-end through the real worker.fetch(): POST /auth/session (mock verifier) → bearer session
// → an authed route → sign-out. Proves identity now comes from a verified SESSION, not the
// forgeable dev header (which we turn OFF here so the Bearer path stands alone).

const ctx = {} as ExecutionContext;

/** makeEnv with the dev user-header trust OFF and mock auth ON (real provider verify is env-bound). */
function authEnv(): Env {
  const { env } = makeEnv();
  const mut = env as Record<string, unknown>;
  delete mut.DEV_TRUST_USER_HEADER;
  mut.DEV_TRUST_MOCK_AUTH = "true";
  return env;
}

interface CallOpts {
  body?: unknown;
  token?: string;
}
function call(env: Env, method: string, path: string, opts: CallOpts = {}): Promise<Response> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (opts.token) headers.authorization = `Bearer ${opts.token}`;
  return worker.fetch!(
    new Request(`https://capecho.test${path}`, {
      method,
      headers,
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
    }),
    env,
    ctx,
  );
}

interface SignInResponse {
  token: string;
  expires_at: number;
  user: { id: string; iana_timezone: string; learning_language: string | null };
}
async function signIn(env: Env, sub = "apple-sub-1"): Promise<SignInResponse> {
  const res = await call(env, "POST", "/auth/session", {
    body: { provider: "apple", credential: JSON.stringify({ sub, email: "u@x.z" }), timezone: "America/New_York" },
  });
  expect(res.status).toBe(200);
  return (await res.json()) as SignInResponse;
}

test("sign in → bearer token unlocks an authed route", async () => {
  const env = authEnv();
  const { token, user } = await signIn(env);
  expect(token).toMatch(/^[A-Za-z0-9_-]+$/);
  expect(user.iana_timezone).toBe("America/New_York"); // captured at first sign-in
  expect((await call(env, "GET", "/words", { token })).status).toBe(200);
});

test("an authed route 401s with no auth, and with an invalid bearer token", async () => {
  const env = authEnv();
  expect((await call(env, "GET", "/words")).status).toBe(401);
  expect((await call(env, "GET", "/words", { token: "garbage" })).status).toBe(401); // bad token ≠ anon downgrade
});

test("signing in twice returns the SAME account, a fresh token", async () => {
  const env = authEnv();
  const a = await signIn(env, "same-sub");
  const b = await signIn(env, "same-sub");
  expect(b.user.id).toBe(a.user.id);
  expect(b.token).not.toBe(a.token);
});

test("sign out revokes the session", async () => {
  const env = authEnv();
  const { token } = await signIn(env);
  expect((await call(env, "GET", "/words", { token })).status).toBe(200);
  expect((await call(env, "POST", "/auth/signout", { token })).status).toBe(200);
  expect((await call(env, "GET", "/words", { token })).status).toBe(401);
});

test("GET /auth/me returns the signed-in account; 401 without a session", async () => {
  const env = authEnv();
  const { token, user } = await signIn(env);
  const me = await call(env, "GET", "/auth/me", { token });
  expect(me.status).toBe(200);
  expect(((await me.json()) as { user: { id: string } }).user.id).toBe(user.id);
  expect((await call(env, "GET", "/auth/me")).status).toBe(401);
});

test("bad sign-ins: mock credential without sub → 401; unknown provider → 400", async () => {
  const env = authEnv();
  const noSub = await call(env, "POST", "/auth/session", {
    body: { provider: "apple", credential: JSON.stringify({ email: "x@y.z" }) },
  });
  expect(noSub.status).toBe(401);
  const badProvider = await call(env, "POST", "/auth/session", { body: { provider: "facebook", credential: "{}" } });
  expect(badProvider.status).toBe(400);
});

test("with no provider configured, sign-in fails closed (production default)", async () => {
  const { env } = makeEnv();
  delete (env as Record<string, unknown>).DEV_TRUST_USER_HEADER; // no mock, no client ids
  const res = await call(env, "POST", "/auth/session", { body: { provider: "apple", credential: "{}" } });
  expect(res.status).toBe(401);
});

test("a full save→list round-trips through the real handlers under bearer auth", async () => {
  const env = authEnv();
  const { token } = await signIn(env);
  const save = await call(env, "POST", "/words", { token, body: { surface_unit: "serendipity", target_language: "en" } });
  expect(save.status).toBe(201);
  const list = await call(env, "GET", "/words", { token });
  expect(((await list.json()) as { words: unknown[] }).words).toHaveLength(1);
});

test("GET /auth/me carries the Settings identity (provider + email)", async () => {
  const env = authEnv();
  const { token } = await signIn(env); // mock verifier: provider apple, email u@x.z
  const me = await call(env, "GET", "/auth/me", { token });
  expect(me.status).toBe(200);
  const u = ((await me.json()) as { user: { provider: string; email: string | null } }).user;
  expect(u.provider).toBe("apple");
  expect(u.email).toBe("u@x.z");
});

test("GET /auth/me carries Pro entitlement: false for a fresh account, true once pro_until is in the future", async () => {
  const h = makeEnv();
  const mut = h.env as Record<string, unknown>;
  delete mut.DEV_TRUST_USER_HEADER;
  mut.DEV_TRUST_MOCK_AUTH = "true";
  const { token, user } = await signIn(h.env);

  type MeUser = { pro: boolean; pro_until: number | null };
  const fresh = ((await (await call(h.env, "GET", "/auth/me", { token })).json()) as { user: MeUser }).user;
  expect(fresh.pro).toBe(false);
  expect(fresh.pro_until).toBeNull();

  // Granting Pro = setting the denormalized horizon into the future (what an applied subscription does).
  const future = Date.now() + 30 * 24 * 60 * 60 * 1000;
  await h.sql.prepare(`UPDATE accounts SET pro_until = ? WHERE id = ?`).bind(future, user.id).run();

  const pro = ((await (await call(h.env, "GET", "/auth/me", { token })).json()) as { user: MeUser }).user;
  expect(pro.pro).toBe(true);
  expect(pro.pro_until).toBe(future);
});

test("DELETE /account marks the account deleted; the session goes inert; re-sign-in resurrects it", async () => {
  const env = authEnv();
  const { token, user } = await signIn(env, "del-sub");
  expect((await call(env, "GET", "/words", { token })).status).toBe(200);

  const del = await call(env, "DELETE", "/account", { token });
  expect(del.status).toBe(200);
  expect(((await del.json()) as { status: string }).status).toBe("deletion_scheduled");

  // Immediately inert for that session: deleted_at set (account-level) + token revoked.
  expect((await call(env, "GET", "/words", { token })).status).toBe(401);
  expect((await call(env, "GET", "/auth/me", { token })).status).toBe(401);

  // Re-signing in with the same subject CANCELS the pending deletion — same account, fresh token.
  const back = await signIn(env, "del-sub");
  expect(back.user.id).toBe(user.id);
  expect((await call(env, "GET", "/words", { token: back.token })).status).toBe(200);
});

test("DELETE /account requires auth", async () => {
  const env = authEnv();
  expect((await call(env, "DELETE", "/account")).status).toBe(401);
});

test("DELETE then POST /words/:id/restore brings a unit back (round-trip through the real handlers)", async () => {
  const env = authEnv();
  const { token } = await signIn(env);
  const save = await call(env, "POST", "/words", { token, body: { surface_unit: "ephemeral", target_language: "en" } });
  expect(save.status).toBe(201);
  const id = ((await save.json()) as { word: { id: string } }).word.id;

  expect((await call(env, "DELETE", `/words/${id}`, { token })).status).toBe(200);
  let list = await call(env, "GET", "/words", { token });
  expect(((await list.json()) as { words: unknown[] }).words).toHaveLength(0);

  const restore = await call(env, "POST", `/words/${id}/restore`, { token });
  expect(restore.status).toBe(200);
  expect(((await restore.json()) as { status: string }).status).toBe("restored");
  list = await call(env, "GET", "/words", { token });
  expect(((await list.json()) as { words: unknown[] }).words).toHaveLength(1);

  // Restoring an already-active unit, or a missing id, is a 404.
  expect((await call(env, "POST", `/words/${id}/restore`, { token })).status).toBe(404);
  expect((await call(env, "POST", "/words/no-such-id/restore", { token })).status).toBe(404);
});
