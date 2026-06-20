import { test, expect } from "bun:test";
import {
  MockIdentityVerifier,
  UnconfiguredVerifier,
  OidcIdentityVerifier,
  verifyOidcToken,
  importRsaPublicKey,
  selectVerifier,
  type OidcConfig,
  type VerifyResult,
} from "../src/auth-verifier.ts";

// --- helpers: mint a real RS256 id token + a JWKS-style key resolver ----------

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
const b64urlStr = (str: string): string => b64url(new TextEncoder().encode(str));

async function makeKeypair(): Promise<{ kp: CryptoKeyPair; pub: { n: string; e: string } }> {
  const kp = (await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const jwk = await crypto.subtle.exportKey("jwk", kp.publicKey);
  return { kp, pub: { n: jwk.n!, e: jwk.e! } };
}

async function sign(priv: CryptoKey, header: object, payload: object): Promise<string> {
  const h = b64urlStr(JSON.stringify(header));
  const p = b64urlStr(JSON.stringify(payload));
  const data = new TextEncoder().encode(`${h}.${p}`);
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "RSASSA-PKCS1-v1_5" }, priv, data));
  return `${h}.${p}.${b64url(sig)}`;
}

const NOW = 1_700_000_000_000; // fixed clock (ms)
const NOW_S = Math.floor(NOW / 1000);
const ISS = "https://appleid.apple.com";
const AUD = "com.capecho.app";
const KID = "test-kid";

async function setup(): Promise<{ cfg: OidcConfig; priv: CryptoKey; header: object; payload: Record<string, unknown> }> {
  const { kp, pub } = await makeKeypair();
  const cfg: OidcConfig = {
    provider: "apple",
    issuers: [ISS],
    audiences: [AUD],
    resolveKey: async (kid) => (kid === KID ? importRsaPublicKey({ kty: "RSA", n: pub.n, e: pub.e }) : null),
    now: () => NOW,
  };
  const header = { alg: "RS256", kid: KID, typ: "JWT" };
  const payload = { iss: ISS, aud: AUD, sub: "apple-sub-123", email: "u@x.z", iat: NOW_S, exp: NOW_S + 3600 };
  return { cfg, priv: kp.privateKey, header, payload };
}

const errOf = (r: VerifyResult): string | undefined => ("error" in r ? r.error : undefined);

// --- OIDC happy path ---------------------------------------------------------

test("verifies a well-formed RS256 id token → subject + email", async () => {
  const { cfg, priv, header, payload } = await setup();
  const r = await verifyOidcToken(cfg, await sign(priv, header, payload));
  expect("error" in r).toBe(false);
  if (!("error" in r)) {
    expect(r.provider).toBe("apple");
    expect(r.subject).toBe("apple-sub-123");
    expect(r.email).toBe("u@x.z");
  }
});

// --- OIDC adversarial --------------------------------------------------------

test("rejects alg:none (no signature trust)", async () => {
  const { cfg, payload } = await setup();
  const h = b64urlStr(JSON.stringify({ alg: "none", kid: KID }));
  const p = b64urlStr(JSON.stringify(payload));
  expect(errOf(await verifyOidcToken(cfg, `${h}.${p}.`))).toBe("unsupported_alg");
});

test("rejects an HS256 (alg-confusion) token before any key work", async () => {
  const { cfg, payload } = await setup();
  const h = b64urlStr(JSON.stringify({ alg: "HS256", kid: KID }));
  const p = b64urlStr(JSON.stringify(payload));
  expect(errOf(await verifyOidcToken(cfg, `${h}.${p}.YWJj`))).toBe("unsupported_alg");
});

test("rejects a tampered payload (signature no longer matches)", async () => {
  const { cfg, priv, header, payload } = await setup();
  const token = await sign(priv, header, payload);
  const [h, , s] = token.split(".");
  const forged = b64urlStr(JSON.stringify({ ...payload, sub: "attacker" }));
  expect(errOf(await verifyOidcToken(cfg, `${h}.${forged}.${s}`))).toBe("bad_signature");
});

test("rejects a wrong audience", async () => {
  const { cfg, priv, header, payload } = await setup();
  const r = await verifyOidcToken(cfg, await sign(priv, header, { ...payload, aud: "com.someone.else" }));
  expect(errOf(r)).toBe("bad_audience");
});

test("rejects a wrong issuer", async () => {
  const { cfg, priv, header, payload } = await setup();
  const r = await verifyOidcToken(cfg, await sign(priv, header, { ...payload, iss: "https://evil.example" }));
  expect(errOf(r)).toBe("bad_issuer");
});

test("rejects an expired token", async () => {
  const { cfg, priv, header, payload } = await setup();
  const r = await verifyOidcToken(cfg, await sign(priv, header, { ...payload, exp: NOW_S - 3600 }));
  expect(errOf(r)).toBe("expired");
});

test("rejects an unknown kid (key not in JWKS)", async () => {
  const { cfg, priv, payload } = await setup();
  const r = await verifyOidcToken(cfg, await sign(priv, { alg: "RS256", kid: "rotated-out" }, payload));
  expect(errOf(r)).toBe("unknown_kid");
});

test("rejects a token missing sub even when otherwise valid", async () => {
  const { cfg, priv, header, payload } = await setup();
  const { sub: _omit, ...noSub } = payload;
  void _omit;
  expect(errOf(await verifyOidcToken(cfg, await sign(priv, header, noSub)))).toBe("missing_subject");
});

test("rejects structurally malformed tokens", async () => {
  const { cfg } = await setup();
  expect(errOf(await verifyOidcToken(cfg, "abc"))).toBe("malformed_token"); // not 3 parts
  expect(errOf(await verifyOidcToken(cfg, "@@@.@@@.@@@"))).toBe("malformed_header");
});

test("a non-object header/payload rejects cleanly — never throws (M1)", async () => {
  const { cfg, priv, header, payload } = await setup();
  // Header that decodes to the JSON literal `null` — `null.alg` would throw a TypeError if unguarded.
  const nullHeader = `${b64urlStr("null")}.${b64urlStr(JSON.stringify(payload))}.x`;
  expect(errOf(await verifyOidcToken(cfg, nullHeader))).toBe("malformed_header");
  // A VALIDLY-SIGNED token whose payload decodes to `null` → malformed_payload (not a throw).
  const h = b64urlStr(JSON.stringify(header));
  const p = b64urlStr("null");
  const data = new TextEncoder().encode(`${h}.${p}`);
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "RSASSA-PKCS1-v1_5" }, priv, data));
  expect(errOf(await verifyOidcToken(cfg, `${h}.${p}.${b64url(sig)}`))).toBe("malformed_payload");
});

test("aud may be an array containing one of our client ids", async () => {
  const { cfg, priv, header, payload } = await setup();
  const r = await verifyOidcToken(cfg, await sign(priv, header, { ...payload, aud: ["other", AUD] }));
  expect("error" in r).toBe(false);
});

test("accepts any of multiple configured audiences (multi-platform), rejects the rest", async () => {
  const { cfg, priv, header, payload } = await setup();
  const multi = { ...cfg, audiences: ["com.capecho.app", "com.capecho.signin", AUD] };
  // a token whose aud is a SECOND configured audience verifies
  const ok = await verifyOidcToken(multi, await sign(priv, header, { ...payload, aud: "com.capecho.signin" }));
  expect("error" in ok).toBe(false);
  // an aud outside the configured set is still rejected
  const bad = await verifyOidcToken(multi, await sign(priv, header, { ...payload, aud: "com.someone.else" }));
  expect(errOf(bad)).toBe("bad_audience");
});

// --- mock + unconfigured + selectVerifier ------------------------------------

test("MockIdentityVerifier parses a {sub,email} credential; rejects bad input", async () => {
  const v = new MockIdentityVerifier();
  const ok = await v.verify("google", JSON.stringify({ sub: "g-1", email: "a@b.c" }));
  expect(ok).toEqual({ provider: "google", subject: "g-1", email: "a@b.c" });
  expect(errOf(await v.verify("apple", "not json"))).toBe("mock_credential_not_json");
  expect(errOf(await v.verify("apple", JSON.stringify({ email: "x@y.z" })))).toBe("mock_credential_missing_sub");
});

test("UnconfiguredVerifier always fails closed", async () => {
  expect(errOf(await new UnconfiguredVerifier().verify("apple", "anything"))).toBe("auth_not_configured");
});

test("selectVerifier: mock flag → mock; client id → OIDC; nothing → unconfigured", () => {
  expect(selectVerifier({ DEV_TRUST_MOCK_AUTH: "true" })).toBeInstanceOf(MockIdentityVerifier);
  expect(selectVerifier({ APPLE_CLIENT_ID: "com.capecho.app" })).toBeInstanceOf(OidcIdentityVerifier);
  expect(selectVerifier({ GOOGLE_CLIENT_ID: "a.apps.googleusercontent.com,b.apps.googleusercontent.com" })).toBeInstanceOf(OidcIdentityVerifier);
  expect(selectVerifier({})).toBeInstanceOf(UnconfiguredVerifier);
  expect(selectVerifier({ APPLE_CLIENT_ID: "   " })).toBeInstanceOf(UnconfiguredVerifier); // whitespace-only → no audiences → fail closed
});

test("OidcIdentityVerifier rejects a provider it has no config for", async () => {
  const v = new OidcIdentityVerifier({});
  expect(errOf(await v.verify("apple", "x.y.z"))).toBe("provider_not_configured:apple");
});
