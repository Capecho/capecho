import { test, expect, beforeEach } from "bun:test";
import { freshDb, ids, seedAccount } from "./helpers/db.ts";
import { testCrypto } from "./helpers/crypto.ts";
import { saveWord } from "../src/words.ts";
import { createContext } from "../src/contexts.ts";
import { getAccount, markAccountDeleted, purgeExpiredDeletedAccounts, hardDeleteAccount } from "../src/accounts.ts";
import type { Sql } from "../src/sql.ts";

let sql: Sql;
let newId: () => string;

async function seedUserWithEncryptedContext(user: string): Promise<void> {
  await seedAccount(sql, user);
  const crypto = await testCrypto();
  const w = await saveWord(sql, { userId: user, surfaceUnit: "ephemeral", targetLanguage: "en", now: 1, newId });
  await createContext(sql, crypto, {
    userId: user,
    wordId: w.status === "created" ? w.word.id : "",
    contextText: "sensitive sentence",
    now: 2,
    newId,
  });
}

async function contextCount(user: string): Promise<number> {
  const r = await sql.prepare(`SELECT COUNT(*) AS n FROM word_contexts WHERE user_id = ?`).bind(user).first<{ n: number }>();
  return Number(r?.n ?? 0);
}

beforeEach(async () => {
  ({ sql } = freshDb());
  newId = ids("r");
});

test("markAccountDeleted starts the retention window (idempotent)", async () => {
  await seedUserWithEncryptedContext("u1");
  expect(await markAccountDeleted(sql, "u1", 1000)).toBe(true);
  expect((await getAccount(sql, "u1"))?.deleted_at).toBe(1000);
  expect(await markAccountDeleted(sql, "u1", 2000)).toBe(false); // already marked
  expect((await getAccount(sql, "u1"))?.deleted_at).toBe(1000); // unchanged
});

test("purge after the window HARD-deletes the account and cascades the encrypted contexts", async () => {
  await seedUserWithEncryptedContext("u1");
  await seedUserWithEncryptedContext("u2");
  await markAccountDeleted(sql, "u1", 1000);

  // cutoff before u1's window elapses → nothing purged
  expect(await purgeExpiredDeletedAccounts(sql, 999)).toBe(0);
  expect(await contextCount("u1")).toBe(1);

  // cutoff at/after the window → u1 purged, its ciphertext gone; u2 (not marked) intact
  expect(await purgeExpiredDeletedAccounts(sql, 1000)).toBe(1);
  expect(await getAccount(sql, "u1")).toBeNull();
  expect(await contextCount("u1")).toBe(0);
  expect(await contextCount("u2")).toBe(1);
});

test("hardDeleteAccount immediately purges one account's data (the purge primitive)", async () => {
  await seedUserWithEncryptedContext("u1");
  expect(await contextCount("u1")).toBe(1);
  expect(await hardDeleteAccount(sql, "u1")).toBe(true);
  expect(await getAccount(sql, "u1")).toBeNull();
  expect(await contextCount("u1")).toBe(0); // cascade purged the ciphertext
});
