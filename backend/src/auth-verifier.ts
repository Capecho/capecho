import type { AuthProvider, VerifiedIdentity } from "./auth.ts";

// Provider credential verification (M3 auth). Turns a sign-in credential into a VerifiedIdentity
// or a typed failure. Mirrors the AI-provider pattern (providers/{mock,null}.ts): a deterministic
// MOCK for dev/test, a real OIDC verifier whose CONFIG (client ids) is env-bound, and an
// Unconfigured fail-closed default so a fresh prod env can't silently trust anyone.
//
// SECURITY — the OIDC path verifies provider ID tokens (RS256 JWTs) and is hardened against the
// classic JWT attacks:
//  - alg allowlist = RS256 ONLY → kills `alg:none` and the RS256→HS256 key-confusion forgery
//    (we only ever crypto.subtle.verify with an RSA public key; an HMAC-"signed" token can't pass).
//  - signature is verified BEFORE any claim is trusted; the verifying key is selected from the
//    provider JWKS by `kid` (never derived from attacker-controlled token fields).
//  - iss/aud/exp(+iat/nbf) are all checked; aud must equal our configured client id.

export type VerifyResult = VerifiedIdentity | { error: string };

export interface IdentityVerifier {
  verify(provider: AuthProvider, credential: string): Promise<VerifyResult>;
}

// --- dev/test: deterministic mock --------------------------------------------

/**
 * Dev/staging only (gated by DEV_TRUST_MOCK_AUTH). The credential is a JSON string
 * `{"sub": "...", "email": "..."}` — no signature, no network — so the whole sign-in → session
 * → authed-route flow is exercisable in tests and local dev without real OAuth apps.
 */
export class MockIdentityVerifier implements IdentityVerifier {
  async verify(provider: AuthProvider, credential: string): Promise<VerifyResult> {
    let parsed: unknown;
    try {
      parsed = JSON.parse(credential);
    } catch {
      return { error: "mock_credential_not_json" };
    }
    const o = parsed as Record<string, unknown> | null;
    if (!o || typeof o.sub !== "string" || o.sub.trim().length === 0) {
      return { error: "mock_credential_missing_sub" };
    }
    return { provider, subject: o.sub, email: typeof o.email === "string" ? o.email : undefined };
  }
}

// --- fail-closed default -----------------------------------------------------

/** No provider configured ⇒ every sign-in fails (prod default until real client ids are set). */
export class UnconfiguredVerifier implements IdentityVerifier {
  async verify(): Promise<VerifyResult> {
    return { error: "auth_not_configured" };
  }
}

// --- real OIDC (Apple / Google) ----------------------------------------------

/** Resolves a JWKS `kid` to its RSA public verifying key, or null if unknown. DI'd for tests. */
export type KeyResolver = (kid: string) => Promise<CryptoKey | null>;

export interface OidcConfig {
  provider: AuthProvider;
  /** Acceptable `iss` values (Google issues with and without the https:// scheme). */
  issuers: string[];
  /**
   * Accepted `aud` values — the token's `aud` must match one. A multi-platform app issues
   * tokens with DIFFERENT audiences (Apple: the Bundle ID for native iOS/macOS vs a Services ID
   * for web/Android; Google: per-platform client ids, or one web "server" client id if every
   * platform uses it as its serverClientId), so this is a list, not a single value.
   */
  audiences: string[];
  resolveKey: KeyResolver;
  /** Tolerance for clock skew on exp/iat/nbf. Default 60s. */
  clockSkewMs?: number;
  /** Injectable clock for tests. Default Date.now. */
  now?: () => number;
}

/**
 * Verify one provider's ID token. Returns the VerifiedIdentity or a typed error string; never
 * throws on malformed input (a bad token is a failed sign-in, not a 500).
 */
export async function verifyOidcToken(cfg: OidcConfig, token: string): Promise<VerifyResult> {
  const parts = token.split(".");
  if (parts.length !== 3) return { error: "malformed_token" };
  const [headerB64, payloadB64, signatureB64] = parts;

  let parsedHeader: unknown;
  try {
    parsedHeader = JSON.parse(b64urlToString(headerB64!));
  } catch {
    return { error: "malformed_header" };
  }
  // A header that decodes to a non-object (e.g. the JSON literal `null`, a number, an array) is
  // malformed — guard BEFORE property access so it's a clean reject, never an uncaught TypeError/500.
  if (typeof parsedHeader !== "object" || parsedHeader === null) return { error: "malformed_header" };
  const { alg, kid } = parsedHeader as { alg?: unknown; kid?: unknown };
  // alg allowlist BEFORE anything else: only RS256. Rejects alg:none and HS256-confusion attempts.
  if (alg !== "RS256") return { error: "unsupported_alg" };
  if (typeof kid !== "string" || kid.length === 0) return { error: "missing_kid" };

  const key = await cfg.resolveKey(kid);
  if (!key) return { error: "unknown_kid" };

  let signature: Uint8Array;
  try {
    signature = b64urlToBytes(signatureB64!);
  } catch {
    return { error: "malformed_signature" };
  }
  const signed = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const ok = await crypto.subtle.verify({ name: "RSASSA-PKCS1-v1_5" }, key, signature as BufferSource, signed);
  if (!ok) return { error: "bad_signature" };

  // Signature is valid — NOW the claims can be trusted.
  let parsedPayload: unknown;
  try {
    parsedPayload = JSON.parse(b64urlToString(payloadB64!));
  } catch {
    return { error: "malformed_payload" };
  }
  if (typeof parsedPayload !== "object" || parsedPayload === null) return { error: "malformed_payload" };
  const payload = parsedPayload as Record<string, unknown>;

  const skew = cfg.clockSkewMs ?? 60_000;
  const nowMs = (cfg.now ?? (() => Date.now()))();

  if (typeof payload.iss !== "string" || !cfg.issuers.includes(payload.iss)) return { error: "bad_issuer" };
  const aud = payload.aud;
  const audOk =
    (typeof aud === "string" && cfg.audiences.includes(aud)) ||
    (Array.isArray(aud) && aud.some((a) => typeof a === "string" && cfg.audiences.includes(a)));
  if (!audOk) return { error: "bad_audience" };
  if (typeof payload.exp !== "number" || payload.exp * 1000 <= nowMs - skew) return { error: "expired" };
  if (typeof payload.iat === "number" && payload.iat * 1000 > nowMs + skew) return { error: "issued_in_future" };
  if (typeof payload.nbf === "number" && payload.nbf * 1000 > nowMs + skew) return { error: "not_yet_valid" };
  if (typeof payload.sub !== "string" || payload.sub.length === 0) return { error: "missing_subject" };

  return {
    provider: cfg.provider,
    subject: payload.sub,
    email: typeof payload.email === "string" ? payload.email : undefined,
  };
}

/** Routes a sign-in to the configured per-provider OIDC verifier. */
export class OidcIdentityVerifier implements IdentityVerifier {
  constructor(private readonly configs: Partial<Record<AuthProvider, OidcConfig>>) {}
  async verify(provider: AuthProvider, credential: string): Promise<VerifyResult> {
    const cfg = this.configs[provider];
    if (!cfg) return { error: `provider_not_configured:${provider}` };
    return verifyOidcToken(cfg, credential);
  }
}

// Fixed provider endpoints (only the audience/client-id is env-bound).
const APPLE_ISSUER = "https://appleid.apple.com";
const APPLE_JWKS = "https://appleid.apple.com/auth/keys";
const GOOGLE_ISSUERS = ["https://accounts.google.com", "accounts.google.com"];
const GOOGLE_JWKS = "https://www.googleapis.com/oauth2/v3/certs";

export interface AuthVerifierEnv {
  DEV_TRUST_MOCK_AUTH?: string;
  /** Accepted Apple `aud`(s), comma-separated: the app Bundle ID (native iOS/macOS) and/or a
   *  Services ID (web/Android). e.g. "com.capecho.app,com.capecho.signin". */
  APPLE_CLIENT_ID?: string;
  /** Accepted Google `aud`(s), comma-separated: the web "server" client id and/or per-platform
   *  client ids. e.g. "123-web.apps.googleusercontent.com,123-ios.apps.googleusercontent.com". */
  GOOGLE_CLIENT_ID?: string;
}

/** Split a comma-separated client-id env value into a trimmed, non-empty audience list. */
function parseAudiences(value: string | undefined): string[] {
  return (value ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

/**
 * Pick the verifier for this deployment:
 *  - DEV_TRUST_MOCK_AUTH="true" → the mock (dev/staging end-to-end without real OAuth);
 *  - else any configured real provider(s) → OIDC verifier (JWKS fetched + cached at runtime);
 *  - else → Unconfigured (fail closed): a fresh prod env trusts no one until client ids are set.
 * APPLE_CLIENT_ID / GOOGLE_CLIENT_ID are comma-separated lists of accepted audiences.
 */
export function selectVerifier(env: AuthVerifierEnv): IdentityVerifier {
  if (env.DEV_TRUST_MOCK_AUTH === "true") return new MockIdentityVerifier();
  const configs: Partial<Record<AuthProvider, OidcConfig>> = {};
  const appleAudiences = parseAudiences(env.APPLE_CLIENT_ID);
  if (appleAudiences.length > 0) {
    configs.apple = {
      provider: "apple",
      issuers: [APPLE_ISSUER],
      audiences: appleAudiences,
      resolveKey: jwksKeyResolver(APPLE_JWKS),
    };
  }
  const googleAudiences = parseAudiences(env.GOOGLE_CLIENT_ID);
  if (googleAudiences.length > 0) {
    configs.google = {
      provider: "google",
      issuers: GOOGLE_ISSUERS,
      audiences: googleAudiences,
      resolveKey: jwksKeyResolver(GOOGLE_JWKS),
    };
  }
  if (Object.keys(configs).length === 0) return new UnconfiguredVerifier();
  return new OidcIdentityVerifier(configs);
}

// --- JWKS fetch + cache + JWK import ------------------------------------------

interface JsonWebKey {
  kid?: string;
  kty?: string;
  n?: string;
  e?: string;
}

const JWKS_TTL_MS = 60 * 60 * 1000; // refetch provider keys at most hourly
// Cap how often a kid-miss may FORCE a cache-bypassing refetch, so an attacker can't turn each
// request with a bogus `kid` into a guaranteed outbound JWKS fetch (provider-rate-limit / cost DoS).
// Real key rotation tolerates this much staleness; within the window a miss just → unknown_kid.
const JWKS_MIN_FORCE_INTERVAL_MS = 60 * 1000;
const jwksCache = new Map<string, { keys: JsonWebKey[]; fetchedAt: number }>();
const jwksLastForcedAt = new Map<string, number>();

async function fetchJwks(url: string, force: boolean): Promise<JsonWebKey[]> {
  const cached = jwksCache.get(url);
  if (!force && cached && Date.now() - cached.fetchedAt < JWKS_TTL_MS) return cached.keys;
  const res = await fetch(url);
  if (!res.ok) {
    if (cached) return cached.keys; // serve stale rather than fail a sign-in on a transient blip
    throw new Error(`jwks_fetch_failed:${res.status}`);
  }
  const body = (await res.json()) as { keys?: JsonWebKey[] };
  const keys = body.keys ?? [];
  jwksCache.set(url, { keys, fetchedAt: Date.now() });
  return keys;
}

/** Runtime key resolver: look up the JWKS by kid; on a miss (key rotation) refetch once — but at
 *  most once per JWKS_MIN_FORCE_INTERVAL_MS per URL, so bogus kids can't force unbounded fetches. */
function jwksKeyResolver(url: string): KeyResolver {
  const find = (keys: JsonWebKey[], kid: string) => keys.find((k) => k.kid === kid && k.kty === "RSA");
  return async (kid: string) => {
    let jwk = find(await fetchJwks(url, false), kid);
    if (!jwk) {
      const last = jwksLastForcedAt.get(url) ?? 0;
      if (Date.now() - last >= JWKS_MIN_FORCE_INTERVAL_MS) {
        jwksLastForcedAt.set(url, Date.now());
        jwk = find(await fetchJwks(url, true), kid); // rotation: one cache-bypassing refetch, rate-limited
      }
    }
    return jwk ? importRsaPublicKey(jwk) : null;
  };
}

/** Import an RSA JWK as an RS256 verification key. */
export async function importRsaPublicKey(jwk: JsonWebKey): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "jwk",
    { kty: "RSA", n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
}

// --- base64url ---------------------------------------------------------------

function b64urlToBytes(s: string): Uint8Array {
  const pad = "=".repeat((4 - (s.length % 4)) % 4);
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + pad;
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

function b64urlToString(s: string): string {
  return new TextDecoder().decode(b64urlToBytes(s));
}
