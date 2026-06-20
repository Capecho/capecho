// Mint a real, fully-signed Apple-like ECDSA certificate chain + StoreKit2-style JWS, in-process, so the
// JWS verifier (src/billing/apple-jws.ts) can be exercised END TO END with a pinned test root we control —
// without shipping a captured production transaction (which would expire and can't be regenerated). The
// production verifier's hardest path (P-384 chain signatures, SPKI/validity parsing) is ALSO covered
// against the REAL Apple Root CA - G3 + WWDR G6 in billing-apple-jws.test.ts; this covers the orchestration
// + the leaf/ES256 link with a minted chain. Chain shape mirrors Apple's: leaf(P-256) ← int(P-384) ← root(P-384).

// --- tiny DER encoders -------------------------------------------------------

function lenBytes(n: number): number[] {
  if (n < 0x80) return [n];
  const out: number[] = [];
  let x = n;
  while (x > 0) {
    out.unshift(x & 0xff);
    x >>>= 8;
  }
  return [0x80 | out.length, ...out];
}
function tlv(tag: number, content: ArrayLike<number>): Uint8Array {
  const c = Array.from(content);
  return Uint8Array.from([tag, ...lenBytes(c.length), ...c]);
}
function flat(parts: ArrayLike<number>[]): number[] {
  const out: number[] = [];
  for (const p of parts) out.push(...Array.from(p));
  return out;
}
function seq(...parts: ArrayLike<number>[]): Uint8Array {
  return tlv(0x30, flat(parts));
}
function derInt(magnitude: number[]): Uint8Array {
  let b = magnitude.slice();
  while (b.length > 1 && b[0] === 0) b.shift();
  if (b.length === 0) b = [0];
  if (((b[0] ?? 0) & 0x80) !== 0) b.unshift(0); // unsigned: avoid a negative sign bit
  return tlv(0x02, b);
}
function derIntFromNumber(n: number): Uint8Array {
  const b: number[] = [];
  let x = n;
  if (x === 0) b.push(0);
  while (x > 0) {
    b.unshift(x & 0xff);
    x = Math.floor(x / 256);
  }
  return derInt(b);
}
function utcTime(epochMs: number): Uint8Array {
  const d = new Date(epochMs);
  const p = (n: number) => String(n).padStart(2, "0");
  const s = `${p(d.getUTCFullYear() % 100)}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}Z`;
  return tlv(0x17, Array.from(new TextEncoder().encode(s)));
}

// signatureAlgorithm = ecdsa-with-SHA384 (every cert below is signed by a P-384 key).
const ALGID_ECDSA_SHA384 = seq(Uint8Array.from([0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x03]));

function boolDer(v: boolean): Uint8Array {
  return tlv(0x01, [v ? 0xff : 0x00]);
}
function base128(v: number): number[] {
  const out = [v & 0x7f];
  let x = Math.floor(v / 128);
  while (x > 0) {
    out.unshift((x & 0x7f) | 0x80);
    x = Math.floor(x / 128);
  }
  return out;
}
function encodeOid(dotted: string): Uint8Array {
  const p = dotted.split(".").map(Number);
  const body = [40 * (p[0] ?? 0) + (p[1] ?? 0)];
  for (let i = 2; i < p.length; i++) body.push(...base128(p[i] ?? 0));
  return tlv(0x06, body);
}
// A bare presence-marker extension: SEQUENCE { extnID, extnValue OCTET STRING(empty) }. Apple's verifier
// (and ours) only checks the OID is PRESENT, so an empty value is sufficient.
function markerExt(oid: string): Uint8Array {
  return seq(encodeOid(oid), tlv(0x04, []));
}
// X.509 extensions [3] EXPLICIT: optional basicConstraints (cA:TRUE) + any presence-marker OIDs.
function buildExtensions(isCA: boolean, markerOids: string[]): Uint8Array {
  const exts: Uint8Array[] = [];
  if (isCA) {
    exts.push(
      seq(
        Uint8Array.from([0x06, 0x03, 0x55, 0x1d, 0x13]), // OID 2.5.29.19 basicConstraints
        boolDer(true), // critical
        tlv(0x04, seq(boolDer(true))), // extnValue OCTET STRING wrapping SEQUENCE { cA TRUE }
      ),
    );
  }
  for (const oid of markerOids) exts.push(markerExt(oid));
  return tlv(0xa3, seq(...exts)); // [3] EXPLICIT SEQUENCE OF Extension
}

function rawEcdsaToDer(raw: Uint8Array): Uint8Array {
  const size = raw.length / 2;
  return seq(derInt(Array.from(raw.subarray(0, size))), derInt(Array.from(raw.subarray(size))));
}

const YEAR = 365 * 24 * 3600 * 1000;

async function mintCert(opts: {
  subjectKey: CryptoKey;
  signerKey: CryptoKey;
  serial: number;
  notBefore: number;
  notAfter: number;
  isCA?: boolean;
  markerOids?: string[];
}): Promise<Uint8Array> {
  const spkiDer = new Uint8Array(await crypto.subtle.exportKey("spki", opts.subjectKey));
  const markers = opts.markerOids ?? [];
  const tbs = seq(
    tlv(0xa0, derIntFromNumber(2)), // [0] EXPLICIT version v3
    derIntFromNumber(opts.serial),
    ALGID_ECDSA_SHA384,
    seq(), // issuer (empty Name — valid DER, all the verifier needs)
    seq(utcTime(opts.notBefore), utcTime(opts.notAfter)),
    seq(), // subject
    spkiDer,
    ...(opts.isCA || markers.length ? [buildExtensions(!!opts.isCA, markers)] : []),
  );
  const rawSig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-384" }, opts.signerKey, tbs));
  const sigBitString = tlv(0x03, [0, ...Array.from(rawEcdsaToDer(rawSig))]);
  return seq(tbs, ALGID_ECDSA_SHA384, sigBitString);
}

function b64std(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}
function b64url(bytes: Uint8Array): string {
  return b64std(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Assemble + sign a compact JWS: header carries `x5cDers` as the x5c chain; payload signed by `leafKey`
 *  (ES256). Exposed so tests can build adversarial chains (wrong length, swapped certs) and re-sign. */
export async function buildJws(leafKey: CryptoKey, x5cDers: Uint8Array[], payload: unknown): Promise<string> {
  const header = { alg: "ES256", x5c: x5cDers.map(b64std) };
  const h64 = b64url(new TextEncoder().encode(JSON.stringify(header)));
  const p64 = b64url(new TextEncoder().encode(JSON.stringify(payload)));
  const rawSig = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, leafKey, new TextEncoder().encode(`${h64}.${p64}`)),
  );
  return `${h64}.${p64}.${b64url(rawSig)}`;
}

export interface MintedChain {
  jws: string;
  rootDer: Uint8Array;
  intDer: Uint8Array;
  leafDer: Uint8Array;
  /** the leaf's private key — re-sign arbitrary headers via buildJws for negative tests */
  leafKey: CryptoKey;
}

/**
 * Mint a leaf(P-256) ← int(P-384) ← root(P-384) chain and a JWS over `payload` signed by the leaf (ES256),
 * with the x5c header carrying [leaf, int, root]. Pass `rootDer` to verifyAppleSignedJws as `pinnedRootDer`.
 * `leafNotBefore/leafNotAfter` override the leaf validity window; `intermediateIsCA:false` mints an
 * intermediate WITHOUT basicConstraints cA:TRUE; `leafHasAppStoreOid:false` / `intermediateHasWwdrOid:false`
 * omit Apple's purpose-marker OIDs (to test the verifier's identity checks).
 */
const OID_APP_STORE_SERVER_LEAF = "1.2.840.113635.100.6.11.1";
const OID_WWDR_INTERMEDIATE = "1.2.840.113635.100.6.2.1";

export async function mintAppleLikeJws(
  payload: unknown,
  opts: {
    now: number;
    leafNotBefore?: number;
    leafNotAfter?: number;
    intermediateIsCA?: boolean;
    leafHasAppStoreOid?: boolean;
    intermediateHasWwdrOid?: boolean;
  },
): Promise<MintedChain> {
  const now = opts.now;
  const p384 = () =>
    crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-384" }, true, ["sign", "verify"]) as Promise<CryptoKeyPair>;
  const p256 = () =>
    crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as Promise<CryptoKeyPair>;
  const root = await p384();
  const inter = await p384();
  const leaf = await p256();

  const rootDer = await mintCert({ subjectKey: root.publicKey, signerKey: root.privateKey, serial: 1, notBefore: now - YEAR, notAfter: now + 20 * YEAR, isCA: true });
  const intDer = await mintCert({
    subjectKey: inter.publicKey,
    signerKey: root.privateKey,
    serial: 2,
    notBefore: now - YEAR,
    notAfter: now + 10 * YEAR,
    isCA: opts.intermediateIsCA ?? true,
    markerOids: (opts.intermediateHasWwdrOid ?? true) ? [OID_WWDR_INTERMEDIATE] : [],
  });
  const leafDer = await mintCert({
    subjectKey: leaf.publicKey,
    signerKey: inter.privateKey,
    serial: 3,
    notBefore: opts.leafNotBefore ?? now - YEAR,
    notAfter: opts.leafNotAfter ?? now + YEAR,
    markerOids: (opts.leafHasAppStoreOid ?? true) ? [OID_APP_STORE_SERVER_LEAF] : [],
  });

  const jws = await buildJws(leaf.privateKey, [leafDer, intDer, rootDer], payload);
  return { jws, rootDer, intDer, leafDer, leafKey: leaf.privateKey };
}
