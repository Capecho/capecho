// T8 envelope encryption for context text + private context-glosses (ENG-9).
//
// Threat model: encryption AT REST (a D1/disk compromise must not yield plaintext) +
// hard-delete + log hygiene. It does NOT try to hide plaintext from the Worker at
// generation time — the metered context call must send the sentence to an AI provider
// off-box by definition (§9), so true end-to-end encryption is impossible for this
// path. The KEK lives in a Worker Secret; decrypt is server-side, transient, never logged.
//
// Scheme: per-record data key (DEK). A random 256-bit DEK encrypts the plaintext
// (AES-256-GCM); the DEK is itself encrypted ("wrapped") under a versioned master key
// (KEK) and stored beside the ciphertext. Rotation = re-wrap the DEK under a new KEK
// (cheap; no data re-encrypt) — the stored key_version says which KEK wrapped it.
// Only AES-GCM is used (universally available in Workers + bun), so wrapping is just
// "encrypt the DEK bytes under the KEK with their own nonce".

const enc = new TextEncoder();
const dec = new TextDecoder();

const DEK_BYTES = 32; // AES-256
const NONCE_BYTES = 12; // AES-GCM IV

export interface Envelope {
  ciphertext: Uint8Array; // AES-256-GCM(plaintext) under the DEK
  wrappedKey: Uint8Array; // wrapNonce(12) || AES-256-GCM(DEK bytes) under the KEK
  nonce: Uint8Array; // the GCM IV for the data ciphertext
  keyVersion: number; // which KEK version wrapped the DEK (rotation)
}

function randomBytes(n: number): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(n));
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

type GcmUsage = "encrypt" | "decrypt";

async function importGcm(raw: Uint8Array, usages: GcmUsage[]): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, usages);
}

async function gcmEncrypt(
  key: CryptoKey,
  nonce: Uint8Array,
  data: Uint8Array,
  aad?: Uint8Array,
): Promise<Uint8Array> {
  const params = { name: "AES-GCM", iv: nonce, ...(aad ? { additionalData: aad } : {}) };
  return new Uint8Array(await crypto.subtle.encrypt(params, key, data));
}

async function gcmDecrypt(
  key: CryptoKey,
  nonce: Uint8Array,
  data: Uint8Array,
  aad?: Uint8Array,
): Promise<Uint8Array> {
  const params = { name: "AES-GCM", iv: nonce, ...(aad ? { additionalData: aad } : {}) };
  return new Uint8Array(await crypto.subtle.decrypt(params, key, data));
}

/** A versioned set of master keys (KEKs). Seal uses the current version; open uses the
 *  version recorded in the envelope, so retired keys still decrypt old records. */
export class KeyRing {
  private constructor(
    private readonly byVersion: Map<number, CryptoKey>,
    public readonly currentVersion: number,
  ) {}

  static async fromRawKeys(entries: { version: number; raw: Uint8Array }[], currentVersion: number): Promise<KeyRing> {
    if (entries.length === 0) throw new Error("KeyRing needs at least one key");
    const m = new Map<number, CryptoKey>();
    for (const e of entries) {
      if (e.raw.length !== DEK_BYTES) throw new Error(`KEK v${e.version} must be ${DEK_BYTES} bytes (AES-256)`);
      m.set(e.version, await importGcm(e.raw, ["encrypt", "decrypt"]));
    }
    if (!m.has(currentVersion)) throw new Error(`current KEK version ${currentVersion} missing from key ring`);
    return new KeyRing(m, currentVersion);
  }

  current(): { version: number; key: CryptoKey } {
    return { version: this.currentVersion, key: this.byVersion.get(this.currentVersion)! };
  }

  get(version: number): CryptoKey | null {
    return this.byVersion.get(version) ?? null;
  }
}

export class EnvelopeCrypto {
  constructor(private readonly ring: KeyRing) {}

  /**
   * Seal plaintext under a fresh per-record DEK wrapped by the current KEK. `aad`
   * (additional authenticated data) BINDS the ciphertext to its record+field (e.g.
   * "ctx:<id>") so a DB-write-capable attacker can't transplant a valid envelope into
   * another row or the gloss column — `open` must be called with the same `aad`.
   */
  async seal(plaintext: string, aad?: string): Promise<Envelope> {
    const { version, key: kek } = this.ring.current();
    const dekRaw = randomBytes(DEK_BYTES);
    const dek = await importGcm(dekRaw, ["encrypt"]);
    const nonce = randomBytes(NONCE_BYTES);
    const ciphertext = await gcmEncrypt(dek, nonce, enc.encode(plaintext), aad ? enc.encode(aad) : undefined);
    const wrapNonce = randomBytes(NONCE_BYTES);
    const wrappedKey = concat(wrapNonce, await gcmEncrypt(kek, wrapNonce, dekRaw));
    return { ciphertext, wrappedKey, nonce, keyVersion: version };
  }

  /** Open an envelope. Throws on an unknown key version, a failed GCM tag (tamper),
   *  or an `aad` mismatch (a transplanted envelope). */
  async open(env: Envelope, aad?: string): Promise<string> {
    const kek = this.ring.get(env.keyVersion);
    if (!kek) throw new Error(`unknown envelope key version: ${env.keyVersion}`);
    const wrapNonce = env.wrappedKey.subarray(0, NONCE_BYTES);
    const wrappedCt = env.wrappedKey.subarray(NONCE_BYTES);
    const dekRaw = await gcmDecrypt(kek, wrapNonce, wrappedCt);
    const dek = await importGcm(dekRaw, ["decrypt"]);
    return dec.decode(await gcmDecrypt(dek, env.nonce, env.ciphertext, aad ? enc.encode(aad) : undefined));
  }

  /** Rotate: re-wrap the DEK under the current KEK without re-encrypting the data. */
  async rewrap(env: Envelope): Promise<Envelope> {
    const oldKek = this.ring.get(env.keyVersion);
    if (!oldKek) throw new Error(`unknown envelope key version: ${env.keyVersion}`);
    const wrapNonce = env.wrappedKey.subarray(0, NONCE_BYTES);
    const dekRaw = await gcmDecrypt(oldKek, wrapNonce, env.wrappedKey.subarray(NONCE_BYTES));
    const { version, key: kek } = this.ring.current();
    const newNonce = randomBytes(NONCE_BYTES);
    return { ...env, wrappedKey: concat(newNonce, await gcmEncrypt(kek, newNonce, dekRaw)), keyVersion: version };
  }
}

/** Decode a base64 (standard) string to bytes — for KEK material from a Worker Secret. */
export function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64.trim());
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export interface KekEnv {
  CONTEXT_KEK?: string; // base64-encoded 32-byte current KEK (Worker Secret)
  CONTEXT_KEK_VERSION?: string; // integer, default 1
}

/**
 * Build the envelope crypto from env, or null if no KEK is configured — context
 * endpoints then FAIL CLOSED (503) rather than store plaintext or a guessable key.
 */
export async function envelopeCryptoFromEnv(env: KekEnv): Promise<EnvelopeCrypto | null> {
  if (!env.CONTEXT_KEK || env.CONTEXT_KEK.trim().length === 0) return null;
  const version = Number.parseInt(env.CONTEXT_KEK_VERSION ?? "1", 10);
  if (!Number.isFinite(version) || version <= 0) return null;
  let raw: Uint8Array;
  try {
    raw = base64ToBytes(env.CONTEXT_KEK);
  } catch {
    return null;
  }
  if (raw.length !== DEK_BYTES) return null;
  const ring = await KeyRing.fromRawKeys([{ version, raw }], version);
  return new EnvelopeCrypto(ring);
}
