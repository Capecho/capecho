import { test, expect } from "bun:test";
import { envelopeCryptoFromEnv, type Envelope } from "../src/crypto.ts";
import { cryptoFromRaws, testCrypto, rand32, bytesToB64 } from "./helpers/crypto.ts";

test("seal → open round-trips (incl. non-ASCII)", async () => {
  const c = await testCrypto();
  const pt = 'the word "slide" in 这个句子里 means 滑动';
  const env = await c.seal(pt);
  expect(await c.open(env)).toBe(pt);
});

test("ciphertext is not the plaintext, and each seal uses a fresh DEK + nonce", async () => {
  const c = await testCrypto();
  const a = await c.seal("repeatable plaintext");
  const b = await c.seal("repeatable plaintext");
  const asLatin1 = (u: Uint8Array) => String.fromCharCode(...u);
  expect(asLatin1(a.ciphertext)).not.toContain("repeatable");
  // same plaintext, different ciphertext + nonce + wrapped key (random DEK/nonce each time)
  expect(asLatin1(a.ciphertext)).not.toBe(asLatin1(b.ciphertext));
  expect(asLatin1(a.nonce)).not.toBe(asLatin1(b.nonce));
});

test("open throws on an unknown key version", async () => {
  const c = await testCrypto();
  const env = await c.seal("x");
  await expect(c.open({ ...env, keyVersion: 999 })).rejects.toThrow(/unknown envelope key version/);
});

test("tampering with the ciphertext fails the GCM auth tag", async () => {
  const c = await testCrypto();
  const env = await c.seal("authentic");
  const tampered: Envelope = { ...env, ciphertext: Uint8Array.from(env.ciphertext) };
  tampered.ciphertext[0] ^= 0x01;
  await expect(c.open(tampered)).rejects.toThrow();
});

test("rewrap rotates the key version without losing the plaintext (no data re-encrypt)", async () => {
  const raw1 = rand32();
  const raw2 = rand32();
  const cV1 = await cryptoFromRaws([{ version: 1, raw: raw1 }], 1);
  const cV12 = await cryptoFromRaws(
    [
      { version: 1, raw: raw1 },
      { version: 2, raw: raw2 },
    ],
    2,
  );
  const env1 = await cV1.seal("rotate me");
  expect(env1.keyVersion).toBe(1);
  const env2 = await cV12.rewrap(env1);
  expect(env2.keyVersion).toBe(2);
  expect(env2.ciphertext).toEqual(env1.ciphertext); // data not re-encrypted, only the DEK re-wrapped
  expect(await cV12.open(env2)).toBe("rotate me");
  expect(await cV12.open(env1)).toBe("rotate me"); // old version still opens (retired key kept)
});

test("envelopeCryptoFromEnv fails closed on a missing / malformed KEK", async () => {
  expect(await envelopeCryptoFromEnv({})).toBeNull();
  expect(await envelopeCryptoFromEnv({ CONTEXT_KEK: "" })).toBeNull();
  expect(await envelopeCryptoFromEnv({ CONTEXT_KEK: bytesToB64(new Uint8Array(16)) })).toBeNull(); // wrong length
});

test("envelopeCryptoFromEnv builds a working crypto from a base64 32-byte KEK", async () => {
  const c = await envelopeCryptoFromEnv({ CONTEXT_KEK: bytesToB64(rand32()), CONTEXT_KEK_VERSION: "3" });
  expect(c).not.toBeNull();
  const env = await c!.seal("from env");
  expect(env.keyVersion).toBe(3);
  expect(await c!.open(env)).toBe("from env");
});
