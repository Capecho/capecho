import { SELF } from "cloudflare:test";
import { expect } from "vitest";

// Shared helpers for the workerd integration tests. Not a `*.integration.ts` file, so vitest's
// include glob skips it as a test (it's imported by the real test files).

export function call(method: string, path: string, opts: { body?: unknown; token?: string } = {}): Promise<Response> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (opts.token) headers.authorization = `Bearer ${opts.token}`;
  return SELF.fetch(`https://api.capecho.test${path}`, {
    method,
    headers,
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });
}

/** Sign in through the real /auth/session (mock verifier) and return the bearer token. */
export async function signIn(sub = "apple-sub", provider: "apple" | "google" | "email" = "apple"): Promise<string> {
  const res = await call("POST", "/auth/session", {
    body: { provider, credential: JSON.stringify({ sub, email: `${sub}@x.z` }), timezone: "UTC" },
  });
  expect(res.status).toBe(200);
  return ((await res.json()) as { token: string }).token;
}

/** Create a word, return its id. */
export async function saveWord(token: string, surfaceUnit: string, targetLanguage = "en"): Promise<string> {
  const res = await call("POST", "/words", { token, body: { surface_unit: surfaceUnit, target_language: targetLanguage } });
  expect(res.status).toBe(201);
  return ((await res.json()) as { word: { id: string } }).word.id;
}
