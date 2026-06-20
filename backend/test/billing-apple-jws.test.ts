import { test, expect } from "bun:test";
import {
  verifyAppleSignedJws,
  verifyCertSignature,
  parseCertificate,
  appleRootCaG3Der,
} from "../src/billing/apple-jws.ts";
import { mintAppleLikeJws, buildJws } from "./helpers/x509-mint.ts";

// Real Apple PKI certs (public, from apple.com/certificateauthority). WWDR G6 is genuinely issued by
// Apple Root CA - G3, so these exercise the REAL P-384 chain-signature + SPKI/validity parsing path.
const APPLE_WWDR_G6_B64 =
  "MIIDFjCCApygAwIBAgIUIsGhRwp0c2nvU4YSycafPTjzbNcwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMjEwMzE3MjAzNzEwWhcNMzYwMzE5MDAwMDAwWjB1MUQwQgYDVQQDDDtBcHBsZSBXb3JsZHdpZGUgRGV2ZWxvcGVyIFJlbGF0aW9ucyBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTELMAkGA1UECwwCRzYxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEbsQKC94PrlWmZXnXgtxzdVJL8T0SGYngDRGpngn3N6PT8JMEb7FDi4bBmPhCnZ3/sq6PF/cGcKXWsL5vOteRhyJ45x3ASP7cOB+aao90fcpxSv/EZFbniAbNgZGhIhpIo4H6MIH3MBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAUu7DeoVgziJqkipnevr3rr9rLJKswRgYIKwYBBQUHAQEEOjA4MDYGCCsGAQUFBzABhipodHRwOi8vb2NzcC5hcHBsZS5jb20vb2NzcDAzLWFwcGxlcm9vdGNhZzMwNwYDVR0fBDAwLjAsoCqgKIYmaHR0cDovL2NybC5hcHBsZS5jb20vYXBwbGVyb290Y2FnMy5jcmwwHQYDVR0OBBYEFD8vlCNR01DJmig97bB85c+lkGKZMA4GA1UdDwEB/wQEAwIBBjAQBgoqhkiG92NkBgIBBAIFADAKBggqhkjOPQQDAwNoADBlAjBAXhSq5IyKogMCPtw490BaB677CaEGJXufQB/EqZGd6CSjiCtOnuMTbXVXmxxcxfkCMQDTSPxarZXvNrkxU3TkUMI33yzvFVVRT4wxWJC994OsdcZ4+RGNsYDyR5gmdr0nDGg=";

function b64ToBytes(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// A timestamp inside the real certs' validity windows (2024-01-01) — must outlive the 2026 "today".
const NOW_IN_RANGE = Date.UTC(2024, 0, 1);

// --- real-cert certificate parsing + chain-signature verification ------------

test("parseCertificate: reads the real Apple Root CA - G3 (P-384, self-issued, 2039 horizon)", () => {
  const cert = parseCertificate(appleRootCaG3Der());
  expect(cert.curve).toBe("P-384");
  expect(cert.sigAlgOid).toBe("1.2.840.10045.4.3.3"); // ecdsa-with-SHA384
  expect(cert.notBefore).toBe(Date.UTC(2014, 3, 30, 18, 19, 6));
  expect(cert.notAfter).toBe(Date.UTC(2039, 3, 30, 18, 19, 6));
});

test("verifyCertSignature: the real WWDR G6 intermediate is genuinely signed by Apple Root CA - G3", async () => {
  const wwdr = b64ToBytes(APPLE_WWDR_G6_B64);
  expect(await verifyCertSignature(wwdr, appleRootCaG3Der(), NOW_IN_RANGE)).toBe(true);
});

test("verifyCertSignature: rejects when the parent is wrong (WWDR is NOT signed by itself)", async () => {
  const wwdr = b64ToBytes(APPLE_WWDR_G6_B64);
  expect(await verifyCertSignature(wwdr, wwdr, NOW_IN_RANGE)).toBe(false);
});

test("verifyCertSignature: rejects a tampered child certificate", async () => {
  const wwdr = b64ToBytes(APPLE_WWDR_G6_B64);
  const tampered = wwdr.slice();
  tampered[120] ^= 0xff; // flip a byte inside tbsCertificate
  expect(await verifyCertSignature(tampered, appleRootCaG3Der(), NOW_IN_RANGE)).toBe(false);
});

test("verifyCertSignature: rejects when `now` is outside the child's validity window", async () => {
  const wwdr = b64ToBytes(APPLE_WWDR_G6_B64);
  expect(await verifyCertSignature(wwdr, appleRootCaG3Der(), Date.UTC(2010, 0, 1))).toBe(false); // before notBefore
  expect(await verifyCertSignature(wwdr, appleRootCaG3Der(), Date.UTC(2040, 0, 1))).toBe(false); // after notAfter
});

// --- full JWS verification, against a minted chain we pin --------------------

test("verifyAppleSignedJws: accepts a correctly-signed chain and returns the decoded payload", async () => {
  const payload = { originalTransactionId: "ot_123", appAccountToken: "u1", expiresDate: 9_000_000 };
  const { jws, rootDer } = await mintAppleLikeJws(payload, { now: NOW_IN_RANGE });
  const out = await verifyAppleSignedJws(jws, { now: NOW_IN_RANGE, pinnedRootDer: rootDer });
  expect(out).toEqual(payload);
});

test("verifyAppleSignedJws: rejects when the chain's root is NOT the pinned root", async () => {
  const { jws } = await mintAppleLikeJws({ originalTransactionId: "ot_1" }, { now: NOW_IN_RANGE });
  // Default pin is the real Apple Root CA - G3; the minted chain roots at a random key → no match.
  expect(await verifyAppleSignedJws(jws, { now: NOW_IN_RANGE })).toBeNull();
});

test("verifyAppleSignedJws: rejects a tampered payload (signature no longer matches)", async () => {
  const { jws, rootDer } = await mintAppleLikeJws({ originalTransactionId: "ot_1" }, { now: NOW_IN_RANGE });
  const [h, , s] = jws.split(".");
  const forged = `${h}.${btoa(JSON.stringify({ originalTransactionId: "ot_EVIL" })).replace(/=+$/, "")}.${s}`;
  expect(await verifyAppleSignedJws(forged, { now: NOW_IN_RANGE, pinnedRootDer: rootDer })).toBeNull();
});

test("verifyAppleSignedJws: rejects a leaf WITHOUT the Apple App Store Server purpose OID", async () => {
  // The cert-substitution guard: a different Apple-issued leaf that chains correctly but
  // lacks the App Store Server signing marker (e.g. a developer's own cert) must NOT be accepted as a signer.
  const { jws, rootDer } = await mintAppleLikeJws({ originalTransactionId: "ot_1" }, { now: NOW_IN_RANGE, leafHasAppStoreOid: false });
  expect(await verifyAppleSignedJws(jws, { now: NOW_IN_RANGE, pinnedRootDer: rootDer })).toBeNull();
});

test("verifyAppleSignedJws: rejects an intermediate WITHOUT the Apple WWDR marker OID", async () => {
  const { jws, rootDer } = await mintAppleLikeJws({ originalTransactionId: "ot_1" }, { now: NOW_IN_RANGE, intermediateHasWwdrOid: false });
  expect(await verifyAppleSignedJws(jws, { now: NOW_IN_RANGE, pinnedRootDer: rootDer })).toBeNull();
});

test("verifyAppleSignedJws: rejects a chain whose intermediate is NOT a CA (basicConstraints cA:false)", async () => {
  // The substitution-attack guard: an issuer cert must carry basicConstraints cA:TRUE. A non-CA cert in the
  // intermediate slot — even correctly signed by the pinned root and correctly signing the leaf — is refused.
  const { jws, rootDer } = await mintAppleLikeJws({ originalTransactionId: "ot_1" }, { now: NOW_IN_RANGE, intermediateIsCA: false });
  expect(await verifyAppleSignedJws(jws, { now: NOW_IN_RANGE, pinnedRootDer: rootDer })).toBeNull();
});

test("verifyAppleSignedJws: rejects a chain that is not exactly 3 certs (no leaf+root, no padded chain)", async () => {
  const { rootDer, intDer, leafDer, leafKey } = await mintAppleLikeJws({ originalTransactionId: "ot_1" }, { now: NOW_IN_RANGE });
  // 2 certs (leaf + root, intermediate dropped) — re-signed so only the length differs.
  const twoCert = await buildJws(leafKey, [leafDer, rootDer], { originalTransactionId: "ot_1" });
  expect(await verifyAppleSignedJws(twoCert, { now: NOW_IN_RANGE, pinnedRootDer: rootDer })).toBeNull();
  // 4 certs (a duplicate stacked in) — the unbounded-chain / stacking shape.
  const fourCert = await buildJws(leafKey, [leafDer, intDer, intDer, rootDer], { originalTransactionId: "ot_1" });
  expect(await verifyAppleSignedJws(fourCert, { now: NOW_IN_RANGE, pinnedRootDer: rootDer })).toBeNull();
});

test("verifyAppleSignedJws: rejects a tampered intermediate (broken intermediate→root signature)", async () => {
  const { rootDer, intDer, leafDer, leafKey } = await mintAppleLikeJws({ originalTransactionId: "ot_1" }, { now: NOW_IN_RANGE });
  const badInt = intDer.slice();
  badInt[80] ^= 0xff; // corrupt the intermediate's tbs → its root signature no longer verifies
  const jws = await buildJws(leafKey, [leafDer, badInt, rootDer], { originalTransactionId: "ot_1" });
  expect(await verifyAppleSignedJws(jws, { now: NOW_IN_RANGE, pinnedRootDer: rootDer })).toBeNull();
});

test("verifyAppleSignedJws: rejects an expired leaf certificate", async () => {
  const { jws, rootDer } = await mintAppleLikeJws(
    { originalTransactionId: "ot_1" },
    { now: NOW_IN_RANGE, leafNotBefore: NOW_IN_RANGE - 2 * 86_400_000, leafNotAfter: NOW_IN_RANGE - 86_400_000 },
  );
  expect(await verifyAppleSignedJws(jws, { now: NOW_IN_RANGE, pinnedRootDer: rootDer })).toBeNull();
});

test("verifyAppleSignedJws: rejects malformed / unsigned input (no x5c, wrong shape)", async () => {
  const { rootDer } = await mintAppleLikeJws({ a: 1 }, { now: NOW_IN_RANGE });
  // A fake JWS with NO x5c header (the shape apple.ts decodes without verifying) must not verify.
  const fake = `${btoa(JSON.stringify({ alg: "ES256" })).replace(/=+$/, "")}.${btoa(JSON.stringify({ a: 1 })).replace(/=+$/, "")}.${btoa("sig").replace(/=+$/, "")}`;
  expect(await verifyAppleSignedJws(fake, { now: NOW_IN_RANGE, pinnedRootDer: rootDer })).toBeNull();
  expect(await verifyAppleSignedJws("not-a-jws", { now: NOW_IN_RANGE })).toBeNull();
  expect(await verifyAppleSignedJws("a.b", { now: NOW_IN_RANGE })).toBeNull();
});
