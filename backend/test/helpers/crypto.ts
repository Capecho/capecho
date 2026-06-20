import { KeyRing, EnvelopeCrypto } from "../../src/crypto.ts";

export function rand32(): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(32));
}

/** EnvelopeCrypto over the given raw KEKs (test-only, in-memory). */
export async function cryptoFromRaws(
  entries: { version: number; raw: Uint8Array }[],
  current: number,
): Promise<EnvelopeCrypto> {
  return new EnvelopeCrypto(await KeyRing.fromRawKeys(entries, current));
}

/** EnvelopeCrypto with a single random KEK at version 1. */
export async function testCrypto(): Promise<EnvelopeCrypto> {
  return cryptoFromRaws([{ version: 1, raw: rand32() }], 1);
}

export function bytesToB64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}
