import { test, expect, beforeEach, afterEach } from "bun:test";
import worker from "../src/index.ts";
import { makeEnv } from "./helpers/worker-env.ts";
import type { Env } from "../src/index.ts";

// End-to-end through the real worker.fetch(): POST /auth/email/start (Resend stubbed) → read the
// 6-digit code from the captured email → POST /auth/email/verify → the SAME bearer session as
// Apple/Google unlocks an authed route. The dev user-header trust is OFF so the email path stands
// on its own session.

const ctx = {} as ExecutionContext;

interface Sent {
  to: string;
  code: string;
}
let sent: Sent[] = [];
let failNextSend = false;
const realFetch = globalThis.fetch;

beforeEach(() => {
  sent = [];
  failNextSend = false;
  globalThis.fetch = (async (url: unknown, init?: RequestInit) => {
    if (String(url).includes("api.resend.com")) {
      const payload = JSON.parse((init?.body as string) ?? "{}");
      const code = String(payload.subject).match(/\d{6}/)?.[0] ?? "";
      sent.push({ to: payload.to[0], code });
      if (failNextSend) return new Response("upstream boom", { status: 500 });
      return new Response(JSON.stringify({ id: "email_1" }), { status: 200 });
    }
    return realFetch(url as never, init);
  }) as typeof fetch;
});
afterEach(() => {
  globalThis.fetch = realFetch;
});

/** makeEnv with the dev user-header trust OFF and Resend configured (key present ⇒ real mailer). */
function emailEnv(): Env {
  const { env } = makeEnv();
  const mut = env as Record<string, unknown>;
  delete mut.DEV_TRUST_USER_HEADER;
  mut.RESEND_API_KEY = "re_test";
  mut.EMAIL_FROM = "Capecho <login@capecho.test>";
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

test("start → emailed code → verify → bearer session unlocks an authed route", async () => {
  const env = emailEnv();
  const start = await call(env, "POST", "/auth/email/start", { body: { email: "  User@Example.com " } });
  expect(start.status).toBe(200);
  expect(await start.json()).toEqual({ status: "sent" });
  expect(sent).toHaveLength(1);
  expect(sent[0]!.to).toBe("user@example.com"); // normalized recipient

  const verify = await call(env, "POST", "/auth/email/verify", {
    body: { email: "user@example.com", code: sent[0]!.code, timezone: "America/New_York", learning_language: "es" },
  });
  expect(verify.status).toBe(200);
  const v = (await verify.json()) as SignInResponse;
  expect(v.token).toMatch(/^[A-Za-z0-9_-]+$/);
  expect(v.user.iana_timezone).toBe("America/New_York"); // captured at first sign-in
  expect(v.user.learning_language).toBe("es");
  expect((await call(env, "GET", "/words", { token: v.token })).status).toBe(200);
});

test("a wrong code is rejected (401), then the right code still works", async () => {
  const env = emailEnv();
  await call(env, "POST", "/auth/email/start", { body: { email: "u@x.z" } });
  const wrong = await call(env, "POST", "/auth/email/verify", { body: { email: "u@x.z", code: "000000" } });
  expect(wrong.status).toBe(401);
  expect(((await wrong.json()) as { error: string }).error).toBe("auth_failed");
  const right = await call(env, "POST", "/auth/email/verify", { body: { email: "u@x.z", code: sent[0]!.code } });
  expect(right.status).toBe(200);
});

test("the resend throttle blocks a second code within the window (429, only one email)", async () => {
  const env = emailEnv();
  expect((await call(env, "POST", "/auth/email/start", { body: { email: "u@x.z" } })).status).toBe(200);
  const again = await call(env, "POST", "/auth/email/start", { body: { email: "u@x.z" } });
  expect(again.status).toBe(429);
  expect(sent).toHaveLength(1); // no second email sent
});

test("too many wrong codes locks out the code (429 too_many_attempts)", async () => {
  const env = emailEnv();
  await call(env, "POST", "/auth/email/start", { body: { email: "u@x.z" } });
  for (let i = 0; i < 5; i++) {
    expect((await call(env, "POST", "/auth/email/verify", { body: { email: "u@x.z", code: "000000" } })).status).toBe(401);
  }
  const locked = await call(env, "POST", "/auth/email/verify", { body: { email: "u@x.z", code: sent[0]!.code } });
  expect(locked.status).toBe(429);
  expect(((await locked.json()) as { error: string }).error).toBe("too_many_attempts");
});

test("verify with no pending code → 401 (no oracle for which addresses have a code)", async () => {
  const env = emailEnv();
  const res = await call(env, "POST", "/auth/email/verify", { body: { email: "nobody@x.z", code: "123456" } });
  expect(res.status).toBe(401);
  expect(((await res.json()) as { error: string }).error).toBe("auth_failed");
});

test("bad input: malformed email or non-6-digit code → 400", async () => {
  const env = emailEnv();
  expect((await call(env, "POST", "/auth/email/start", { body: { email: "not-an-email" } })).status).toBe(400);
  expect((await call(env, "POST", "/auth/email/start", { body: {} })).status).toBe(400);
  await call(env, "POST", "/auth/email/start", { body: { email: "u@x.z" } });
  expect((await call(env, "POST", "/auth/email/verify", { body: { email: "u@x.z", code: "12345" } })).status).toBe(400);
  expect((await call(env, "POST", "/auth/email/verify", { body: { email: "u@x.z", code: "abcdef" } })).status).toBe(400);
});

test("email sign-in FAILS CLOSED when unconfigured (no Resend key, no mock) → 503", async () => {
  const { env } = makeEnv();
  delete (env as Record<string, unknown>).DEV_TRUST_USER_HEADER; // no key, no mock
  const res = await call(env, "POST", "/auth/email/start", { body: { email: "u@x.z" } });
  expect(res.status).toBe(503);
  expect(sent).toHaveLength(0);
});

test("signing in twice with the same email returns the SAME account, a fresh token", async () => {
  const env = emailEnv();
  await call(env, "POST", "/auth/email/start", { body: { email: "same@x.z" } });
  const a = (await (await call(env, "POST", "/auth/email/verify", { body: { email: "same@x.z", code: sent[0]!.code } })).json()) as SignInResponse;
  // a fresh code (past the throttle would normally be needed, but the prior code was consumed, so a
  // new start just issues another) — bypass the throttle by clearing via a second start after consume
  sent = [];
  // wait out throttle by issuing through a different path: start again (prior code consumed, but the
  // ROW was deleted on success, so the throttle has no prior row to compare → allowed immediately)
  expect((await call(env, "POST", "/auth/email/start", { body: { email: "same@x.z" } })).status).toBe(200);
  const b = (await (await call(env, "POST", "/auth/email/verify", { body: { email: "same@x.z", code: sent[0]!.code } })).json()) as SignInResponse;
  expect(b.user.id).toBe(a.user.id);
  expect(b.token).not.toBe(a.token);
});

test("a send failure clears the pending code (502) so the user can retry immediately", async () => {
  const env = emailEnv();
  failNextSend = true;
  const res = await call(env, "POST", "/auth/email/start", { body: { email: "u@x.z" } });
  expect(res.status).toBe(502);
  // the pending code was cleared, so a retry is NOT throttled
  failNextSend = false;
  const retry = await call(env, "POST", "/auth/email/start", { body: { email: "u@x.z" } });
  expect(retry.status).toBe(200);
});

test("the global daily send cap fails closed (429) and stops emailing (CR P1)", async () => {
  const env = emailEnv();
  (env as Record<string, unknown>).EMAIL_GLOBAL_DAILY_CAP = "2"; // tiny cap; tests have no cf-connecting-ip ⇒ global only
  expect((await call(env, "POST", "/auth/email/start", { body: { email: "a@x.z" } })).status).toBe(200);
  expect((await call(env, "POST", "/auth/email/start", { body: { email: "b@x.z" } })).status).toBe(200);
  const capped = await call(env, "POST", "/auth/email/start", { body: { email: "c@x.z" } });
  expect(capped.status).toBe(429);
  expect(sent).toHaveLength(2); // the capped 3rd code was never emailed
});

test("/auth/session rejects provider 'email' — email sign-in goes through /auth/email/* (CR P2-3)", async () => {
  const env = emailEnv();
  const res = await call(env, "POST", "/auth/session", { body: { provider: "email", credential: "{}" } });
  expect(res.status).toBe(400);
});
