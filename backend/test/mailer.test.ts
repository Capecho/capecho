import { test, expect, beforeEach, afterEach } from "bun:test";
import { resendMailer, devLogMailer, selectMailer, MailerError, DEFAULT_EMAIL_FROM } from "../src/mailer.ts";

// Capture outbound fetches so we can assert the Resend request shape without a network call.
interface Captured {
  url: string;
  init: RequestInit;
}
let captured: Captured[] = [];
let nextStatus = 200;
const realFetch = globalThis.fetch;

beforeEach(() => {
  captured = [];
  nextStatus = 200;
  globalThis.fetch = (async (url: unknown, init?: RequestInit) => {
    captured.push({ url: String(url), init: init ?? {} });
    return new Response(JSON.stringify({ id: "email_x" }), { status: nextStatus });
  }) as typeof fetch;
});
afterEach(() => {
  globalThis.fetch = realFetch;
});

test("resendMailer POSTs to Resend with a Bearer key, the sender, recipient, and the code", async () => {
  await resendMailer("re_secret", "Capecho <login@capecho.test>").sendLoginCode("u@x.z", "424242");
  expect(captured).toHaveLength(1);
  const { url, init } = captured[0]!;
  expect(url).toBe("https://api.resend.com/emails");
  expect(init.method).toBe("POST");
  const headers = init.headers as Record<string, string>;
  expect(headers.authorization).toBe("Bearer re_secret");
  expect(headers["content-type"]).toBe("application/json");
  const payload = JSON.parse(init.body as string);
  expect(payload.from).toBe("Capecho <login@capecho.test>");
  expect(payload.to).toEqual(["u@x.z"]);
  expect(payload.subject).toContain("424242");
  expect(payload.text).toContain("424242");
  expect(payload.html).toContain("424242");
});

test("resendMailer defaults the sender when none is given", async () => {
  await resendMailer("re_secret").sendLoginCode("u@x.z", "111111");
  expect(JSON.parse(captured[0]!.init.body as string).from).toBe(DEFAULT_EMAIL_FROM);
});

test("a non-2xx from Resend throws a MailerError carrying only the status (no body/PII)", async () => {
  nextStatus = 422;
  const err = await resendMailer("re_secret").sendLoginCode("u@x.z", "111111").catch((e) => e);
  expect(err).toBeInstanceOf(MailerError);
  expect((err as MailerError).message).toBe("resend_http_422");
  expect((err as MailerError).message).not.toContain("u@x.z");
});

test("devLogMailer never hits the network", async () => {
  await devLogMailer().sendLoginCode("u@x.z", "111111");
  expect(captured).toHaveLength(0);
});

// --- selectMailer ------------------------------------------------------------

test("selectMailer prefers Resend when a key is set", async () => {
  const m = selectMailer({ RESEND_API_KEY: "re_secret", EMAIL_FROM: "Capecho <a@b.c>" });
  expect(m).not.toBeNull();
  await m!.sendLoginCode("u@x.z", "222222");
  expect(captured).toHaveLength(1); // the real (Resend) sender → a fetch happened
  expect(JSON.parse(captured[0]!.init.body as string).from).toBe("Capecho <a@b.c>");
});

test("selectMailer falls back to the dev log mailer only under DEV_TRUST_MOCK_AUTH", async () => {
  const m = selectMailer({ DEV_TRUST_MOCK_AUTH: "true" });
  expect(m).not.toBeNull();
  await m!.sendLoginCode("u@x.z", "222222");
  expect(captured).toHaveLength(0); // dev mailer → no network
});

test("selectMailer returns null (fail closed) with no key and no mock flag", () => {
  expect(selectMailer({})).toBeNull();
});
