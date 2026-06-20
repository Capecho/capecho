// StoreKit2 / App Store Server JWS SIGNATURE verification — pure Web Crypto, NO node:crypto, NO deps.
//
// apple.ts intentionally decodes the inbound transaction WITHOUT verifying its signature (trust comes from
// the authoritative App Store Server API refetch). That is safe for ATTRIBUTION because a sub is only ever
// applied to its baked appAccountToken — never to the caller. But the /verify TRANSFER path (App Store
// Guideline 2.1(a): an Apple ID's active subscription must unlock for whoever is signed in) DOES move a sub
// to the caller, so it MUST first prove the posted transaction is genuinely Apple-signed — otherwise a
// guessed/enumerated originalTransactionId in a forged JWS could claim another account's subscription (the
// dual-CR P0 recorded in apple.ts). This module is that proof.
//
// Trust chain: x5c = [leaf, intermediate, root]. The root MUST byte-equal the pinned Apple Root CA - G3
// (embedded below — Apple's offline root, valid through 2039, rotates on a ~decade horizon). Each link's
// ECDSA certificate signature is verified with crypto.subtle, and the JWS payload itself is verified with
// the leaf's public key (ES256). Validity windows are checked against `now`. Returns the decoded payload
// only when the FULL chain + JWS signature verify; null on ANY failure (a forged or malformed post).

// Apple Root CA - G3 (CN=Apple Root CA - G3), the App Store Server JWS trust anchor. ECDSA P-384, self-
// signed, notAfter 2039-04-30. Pinned by exact DER bytes: substituting any other root fails the match.
const APPLE_ROOT_CA_G3_B64 =
  "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==";

let _rootDer: Uint8Array | null = null;
/** The pinned Apple Root CA - G3 DER (decoded once). Exported for the pin check + tests. */
export function appleRootCaG3Der(): Uint8Array {
  return (_rootDer ??= b64ToBytes(APPLE_ROOT_CA_G3_B64));
}

// --- base64 / base64url decode (decode-only; standard base64 for x5c, url for the JWS parts) -----------

function b64ToBytes(s: string): Uint8Array {
  const bin = atob(s.replace(/\s+/g, ""));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function b64urlToBytes(s: string): Uint8Array {
  const pad = "=".repeat((4 - (s.length % 4)) % 4);
  return b64ToBytes(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
}
function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

// --- minimal ASN.1 DER reader (X.509 has only low-tag, definite-length TLVs) ---------------------------

interface Tlv {
  tag: number;
  start: number; // offset of the tag byte
  valueStart: number; // offset of the first content byte
  valueEnd: number; // offset just past the content
  end: number; // === valueEnd
}

/** Read a byte, throwing on out-of-bounds (caught upstream → null; never a silently-wrong parse). */
function at(b: Uint8Array, i: number): number {
  const v = b[i];
  if (v === undefined) throw new Error("der: out of bounds");
  return v;
}
function req<T>(x: T | undefined): T {
  if (x === undefined) throw new Error("der: missing element");
  return x;
}

function readTlv(b: Uint8Array, off: number): Tlv {
  const tag = at(b, off);
  let i = off + 1;
  let len = at(b, i++);
  if (len & 0x80) {
    const n = len & 0x7f;
    len = 0;
    for (let k = 0; k < n; k++) len = (len << 8) | at(b, i++);
  }
  const valueStart = i;
  return { tag, start: off, valueStart, valueEnd: valueStart + len, end: valueStart + len };
}

function children(b: Uint8Array, parent: Tlv): Tlv[] {
  const out: Tlv[] = [];
  let off = parent.valueStart;
  while (off < parent.valueEnd) {
    const t = readTlv(b, off);
    out.push(t);
    off = t.end;
  }
  return out;
}

function oidToString(b: Uint8Array, t: Tlv): string {
  const v = b.subarray(t.valueStart, t.valueEnd);
  const first = at(v, 0);
  const parts: number[] = [Math.floor(first / 40), first % 40];
  let val = 0;
  for (let i = 1; i < v.length; i++) {
    const byte = at(v, i);
    val = (val << 7) | (byte & 0x7f);
    if (!(byte & 0x80)) {
      parts.push(val);
      val = 0;
    }
  }
  return parts.join(".");
}

function parseTime(b: Uint8Array, t: Tlv): number {
  const s = new TextDecoder().decode(b.subarray(t.valueStart, t.valueEnd));
  if (t.tag === 0x17) {
    // UTCTime YYMMDDHHMMSSZ — pivot at 50 per RFC 5280
    let y = parseInt(s.slice(0, 2), 10);
    y = y < 50 ? 2000 + y : 1900 + y;
    return Date.UTC(y, +s.slice(2, 4) - 1, +s.slice(4, 6), +s.slice(6, 8), +s.slice(8, 10), +s.slice(10, 12));
  }
  // GeneralizedTime YYYYMMDDHHMMSSZ
  return Date.UTC(+s.slice(0, 4), +s.slice(4, 6) - 1, +s.slice(6, 8), +s.slice(8, 10), +s.slice(10, 12), +s.slice(12, 14));
}

const OID_ECDSA_SHA256 = "1.2.840.10045.4.3.2";
const OID_ECDSA_SHA384 = "1.2.840.10045.4.3.3";
const OID_P256 = "1.2.840.10045.3.1.7";
const OID_P384 = "1.3.132.0.34";

// Apple certificate PURPOSE markers (per Apple's own app-store-server-library chain verification). The
// leaf must carry the App Store Server signing marker and the intermediate the WWDR marker — this is what
// distinguishes Apple's transaction-signing leaf from ANY OTHER Apple-issued leaf that also chains to the
// root (e.g. a developer's own cert), closing the cert-substitution attack the chain+pin checks miss.
const OID_APP_STORE_SERVER_LEAF = "1.2.840.113635.100.6.11.1";
const OID_WWDR_INTERMEDIATE = "1.2.840.113635.100.6.2.1";

export interface ParsedCertificate {
  /** the raw tbsCertificate DER (the bytes the issuer signed) */
  tbsRaw: Uint8Array;
  /** signatureAlgorithm OID (identifies the hash used by the ISSUER over tbs) */
  sigAlgOid: string;
  /** the certificate signature, DER ECDSA Sig-Value (SEQUENCE{r,s}) */
  sigDer: Uint8Array;
  /** this cert's own SubjectPublicKeyInfo DER (importable as 'spki') */
  spkiDer: Uint8Array;
  /** this cert's public-key curve, or null if unsupported */
  curve: "P-256" | "P-384" | null;
  notBefore: number;
  notAfter: number;
  /** basicConstraints cA:TRUE — i.e. this cert is allowed to act as a CA (sign other certs) */
  isCA: boolean;
  /** dotted OIDs of every X.509 extension present (used to assert Apple's purpose markers) */
  extOids: string[];
}

/** Parse the fields of an X.509 cert this verifier needs. Throws on malformed DER (callers catch → null). */
export function parseCertificate(der: Uint8Array): ParsedCertificate {
  const cert = readTlv(der, 0); // Certificate ::= SEQUENCE { tbs, sigAlg, sigValue }
  const tbs = readTlv(der, cert.valueStart);
  const tbsRaw = der.subarray(tbs.start, tbs.end);
  const sigAlg = readTlv(der, tbs.end);
  const sigAlgOid = oidToString(der, req(children(der, sigAlg)[0]));
  const sigValue = readTlv(der, sigAlg.end); // BIT STRING
  const sigDer = der.subarray(sigValue.valueStart + 1, sigValue.valueEnd); // skip the unused-bits byte

  // TBSCertificate ::= SEQUENCE { [0] version?, serialNumber, signature, issuer, validity, subject, spki, ... }
  const tc = children(der, tbs);
  const base = req(tc[0]).tag === 0xa0 ? 1 : 0; // optional EXPLICIT [0] version
  const validity = children(der, req(tc[base + 3]));
  const notBefore = parseTime(der, req(validity[0]));
  const notAfter = parseTime(der, req(validity[1]));
  const spki = req(tc[base + 5]);
  const spkiDer = der.subarray(spki.start, spki.end);
  const spkiAlg = req(children(der, spki)[0]); // AlgorithmIdentifier { ecPublicKey OID, namedCurve OID }
  const curveOid = oidToString(der, req(children(der, spkiAlg)[1]));
  const curve = curveOid === OID_P384 ? "P-384" : curveOid === OID_P256 ? "P-256" : null;

  // Extensions live in the optional [3] EXPLICIT field (after spki, and any optional [1]/[2] unique IDs).
  // Collect every extension OID, and read basicConstraints cA (defaults FALSE when absent).
  let isCA = false;
  const extOids: string[] = [];
  for (let i = base + 6; i < tc.length; i++) {
    const node = req(tc[i]);
    if (node.tag !== 0xa3) continue; // [3] EXPLICIT extensions
    const exts = children(der, req(children(der, node)[0])); // unwrap [3] → SEQUENCE OF Extension
    for (const ext of exts) {
      const ec = children(der, ext); // Extension ::= { extnID, critical?, extnValue OCTET STRING }
      if (ec.length < 2) continue;
      const oid = oidToString(der, req(ec[0]));
      extOids.push(oid);
      if (oid === "2.5.29.19") {
        const octet = req(ec[ec.length - 1]); // extnValue is the last element
        const bc = children(der, readTlv(der, octet.valueStart)); // OCTET STRING wraps a SEQUENCE
        const first = bc[0];
        if (first && first.tag === 0x01) isCA = at(der, first.valueStart) !== 0x00; // BOOLEAN cA
      }
    }
  }
  return { tbsRaw, sigAlgOid, sigDer, spkiDer, curve, notBefore, notAfter, isCA, extOids };
}

/** Big-endian magnitude with any DER sign-padding / leading zeros stripped. */
function trimInt(b: Uint8Array): Uint8Array {
  let i = 0;
  while (i < b.length - 1 && b[i] === 0) i++;
  return b.subarray(i);
}

/** DER ECDSA Sig-Value (SEQUENCE{r,s}) → the fixed-width raw r‖s Web Crypto wants. */
function derEcdsaSigToRaw(der: Uint8Array, size: number): Uint8Array {
  const seq = readTlv(der, 0);
  const rT = readTlv(der, seq.valueStart);
  const sT = readTlv(der, rT.end);
  const r = trimInt(der.subarray(rT.valueStart, rT.valueEnd));
  const s = trimInt(der.subarray(sT.valueStart, sT.valueEnd));
  const out = new Uint8Array(size * 2);
  out.set(r.subarray(Math.max(0, r.length - size)), size - Math.min(size, r.length));
  out.set(s.subarray(Math.max(0, s.length - size)), size * 2 - Math.min(size, s.length));
  return out;
}

function hashForSigAlg(oid: string): "SHA-256" | "SHA-384" | null {
  if (oid === OID_ECDSA_SHA384) return "SHA-384";
  if (oid === OID_ECDSA_SHA256) return "SHA-256";
  return null;
}

/**
 * Verify `childDer`'s certificate signature with `parentDer`'s public key, and that `now` falls within the
 * child's validity window. True only when the child was genuinely issued by the parent and is current.
 */
export async function verifyCertSignature(childDer: Uint8Array, parentDer: Uint8Array, now: number): Promise<boolean> {
  const child = parseCertificate(childDer);
  const parent = parseCertificate(parentDer);
  if (!parent.curve) return false;
  if (now < child.notBefore || now > child.notAfter) return false;
  const hash = hashForSigAlg(child.sigAlgOid);
  if (!hash) return false;
  const size = parent.curve === "P-384" ? 48 : 32;
  const sigRaw = derEcdsaSigToRaw(child.sigDer, size);
  const key = await crypto.subtle.importKey(
    "spki",
    parent.spkiDer as BufferSource,
    { name: "ECDSA", namedCurve: parent.curve },
    false,
    ["verify"],
  );
  return crypto.subtle.verify({ name: "ECDSA", hash }, key, sigRaw as BufferSource, child.tbsRaw as BufferSource);
}

export interface VerifyJwsOptions {
  now: number;
  /** override the pinned trust anchor (tests only); defaults to the embedded Apple Root CA - G3 */
  pinnedRootDer?: Uint8Array;
}

/**
 * Verify a StoreKit2 / App Store Server JWS end-to-end and return its decoded payload, or null if anything
 * fails. Steps: parse the compact JWS → read the x5c chain → require its root === the pinned Apple root →
 * verify every chain link's cert signature + validity → verify the JWS payload signature with the leaf
 * (ES256). A forged, tampered, expired, or wrong-rooted token yields null (caller falls back to safe,
 * attribution-only behavior).
 */
export async function verifyAppleSignedJws<T = unknown>(jws: string, opts: VerifyJwsOptions): Promise<T | null> {
  try {
    const [h64, p64, s64] = jws.split(".");
    if (h64 === undefined || p64 === undefined || s64 === undefined) return null;
    const header = JSON.parse(new TextDecoder().decode(b64urlToBytes(h64))) as { x5c?: unknown };
    const x5c = header.x5c;
    // Apple's App Store Server / StoreKit2 JWS x5c is EXACTLY [leaf, WWDR intermediate, Apple Root CA - G3].
    // Pin the shape: a fixed length stops both an unbounded-chain DoS and the "stack attacker-minted sub-CAs
    // under one genuine Apple-anchored cert" substitution attack (a longer chain is never legitimate here).
    if (!Array.isArray(x5c) || x5c.length !== 3) return null;
    const chain = x5c.map((c) => b64ToBytes(String(c)));

    // Trust anchor: the chain's root must be the pinned Apple root, byte for byte.
    const pinned = opts.pinnedRootDer ?? appleRootCaG3Der();
    if (!bytesEqual(req(chain[2]), pinned)) return null;

    const leaf = parseCertificate(req(chain[0]));
    const intermediate = parseCertificate(req(chain[1]));

    // Identity + purpose, exactly as Apple's app-store-server-library checks: the intermediate must be a CA
    // carrying the WWDR marker, and the leaf must carry the App Store Server signing marker. Without the
    // leaf-purpose check, ANY Apple-issued P-256 leaf that chains to the root (a developer's own cert)
    // could sign a forged transaction; this is the difference between "needs Apple's signing key" and
    // "needs any Apple-rooted cert key".
    if (!intermediate.isCA) return null;
    if (!intermediate.extOids.includes(OID_WWDR_INTERMEDIATE)) return null;
    if (!leaf.extOids.includes(OID_APP_STORE_SERVER_LEAF)) return null;
    if (leaf.curve !== "P-256") return null; // App Store Server JWS leaves are P-256 / ES256

    // Chain links: each cert is signed by the next (leaf←intermediate←root). The root is trusted by the
    // pin above, so it isn't re-verified as a child.
    for (let i = 0; i < 2; i++) {
      if (!(await verifyCertSignature(req(chain[i]), req(chain[i + 1]), opts.now))) return null;
    }
    const leafKey = await crypto.subtle.importKey(
      "spki",
      leaf.spkiDer as BufferSource,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
    const ok = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      leafKey,
      b64urlToBytes(s64) as BufferSource,
      new TextEncoder().encode(`${h64}.${p64}`),
    );
    if (!ok) return null;

    return JSON.parse(new TextDecoder().decode(b64urlToBytes(p64))) as T;
  } catch {
    return null;
  }
}
