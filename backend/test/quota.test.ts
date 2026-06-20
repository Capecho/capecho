import { test, expect, beforeEach } from "bun:test";
import { freshDb, ids, seedAccount } from "./helpers/db.ts";
import {
  reserveContextQuota,
  commitReservation,
  refundReservation,
  countLiveReservations,
  sweepExpiredReservations,
} from "../src/quota.ts";
import { saveWord } from "../src/words.ts";
import type { Sql } from "../src/sql.ts";

let sql: Sql;
let newId: () => string;

async function seedContext(user: string, surface: string): Promise<string> {
  const w = await saveWord(sql, { userId: user, surfaceUnit: surface, targetLanguage: "en", now: 1, newId });
  const wordId = w.status === "created" || w.status === "deduped" || w.status === "resurrected" ? w.word.id : "";
  const ctxId = newId();
  await sql
    .prepare(`INSERT INTO word_contexts (id, word_id, user_id, created_at) VALUES (?, ?, ?, 1)`)
    .bind(ctxId, wordId, user)
    .run();
  return ctxId;
}

beforeEach(async () => {
  ({ sql } = freshDb());
  newId = ids("q");
  await seedAccount(sql, "u1");
});

const reserve = (over: Partial<Parameters<typeof reserveContextQuota>[1]> = {}) =>
  reserveContextQuota(sql, {
    userId: "u1",
    wordContextId: null,
    requestFingerprint: "fp-A",
    quotaDay: "2026-05-27",
    idempotencyKey: "idem-1",
    dailyCap: 10,
    ttlMs: 60_000,
    now: 1_000,
    newId,
    ...over,
  });

test("reserve then commit counts toward the day; refund frees the slot", async () => {
  const r = await reserve();
  expect(r.status).toBe("reserved");
  expect(await countLiveReservations(sql, "u1", "2026-05-27", 1_000)).toBe(1);

  expect(await commitReservation(sql, "u1", "idem-1", 1_500)).toBe(true);
  expect(await countLiveReservations(sql, "u1", "2026-05-27", 2_000)).toBe(1); // committed still counts

  // a different request, then refund it
  const r2 = await reserve({ idempotencyKey: "idem-2", requestFingerprint: "fp-B" });
  expect(r2.status).toBe("reserved");
  expect(await countLiveReservations(sql, "u1", "2026-05-27", 2_000)).toBe(2);
  expect(await refundReservation(sql, "u1", "idem-2")).toBe(true);
  expect(await countLiveReservations(sql, "u1", "2026-05-27", 2_000)).toBe(1);
});

test("idempotent retry: same idempotency_key + same fingerprint returns the SAME reservation, no double-charge", async () => {
  const r1 = await reserve();
  const r2 = await reserve(); // identical retry
  expect(r1.status).toBe("reserved");
  expect(r2.status).toBe("idempotent_replay");
  if (r1.status === "reserved" && r2.status === "idempotent_replay") {
    expect(r2.id).toBe(r1.id);
  }
  expect(await countLiveReservations(sql, "u1", "2026-05-27", 1_000)).toBe(1); // counted once
});

test("idempotency_key reused for a DIFFERENT request is rejected (request-bound)", async () => {
  await reserve({ requestFingerprint: "fp-A" });
  const mismatch = await reserve({ requestFingerprint: "fp-DIFFERENT" });
  expect(mismatch.status).toBe("fingerprint_mismatch");
});

test("daily cap is hard: exactly `cap` reservations succeed, the next is cap_exceeded", async () => {
  for (let i = 0; i < 10; i++) {
    const r = await reserve({ idempotencyKey: `k${i}`, requestFingerprint: `f${i}` });
    expect(r.status).toBe("reserved");
  }
  const over = await reserve({ idempotencyKey: "k10", requestFingerprint: "f10" });
  expect(over.status).toBe("cap_exceeded");
  expect(await countLiveReservations(sql, "u1", "2026-05-27", 1_000)).toBe(10);
});

test("retry of an already-reserved request still succeeds even when the day is now full", async () => {
  // fill to cap, including idem-keep
  const keep = await reserve({ idempotencyKey: "keep", requestFingerprint: "fk" });
  expect(keep.status).toBe("reserved");
  for (let i = 0; i < 9; i++) await reserve({ idempotencyKey: `k${i}`, requestFingerprint: `f${i}` });
  expect(await countLiveReservations(sql, "u1", "2026-05-27", 1_000)).toBe(10);
  // retrying 'keep' (at cap) must replay, not be rejected
  const retry = await reserve({ idempotencyKey: "keep", requestFingerprint: "fk" });
  expect(retry.status).toBe("idempotent_replay");
});

test("TTL/crash-recovery: an expired 'reserved' row stops counting and frees a slot", async () => {
  // reserve with a short TTL, then advance the clock past expiry
  await reserve({ idempotencyKey: "stale", requestFingerprint: "fs", ttlMs: 100, now: 1_000 });
  expect(await countLiveReservations(sql, "u1", "2026-05-27", 1_050)).toBe(1); // before expiry
  expect(await countLiveReservations(sql, "u1", "2026-05-27", 2_000)).toBe(0); // after expiry, ignored
  // a fresh request can take the slot even though the stale row physically remains
  const fresh = await reserve({ idempotencyKey: "fresh", requestFingerprint: "ff", dailyCap: 1, now: 2_000 });
  expect(fresh.status).toBe("reserved");
  // sweep marks the stale one refunded
  expect(await sweepExpiredReservations(sql, 2_000)).toBe(1);
});

test("quota days are independent (the cap resets per quota_day)", async () => {
  for (let i = 0; i < 10; i++) await reserve({ idempotencyKey: `a${i}`, requestFingerprint: `fa${i}`, quotaDay: "2026-05-27" });
  const nextDay = await reserve({ idempotencyKey: "next", requestFingerprint: "fn", quotaDay: "2026-05-28" });
  expect(nextDay.status).toBe("reserved");
});

test("same-owner FK holds: a reservation can bind a context the user owns", async () => {
  const ctxId = await seedContext("u1", "serendipity");
  const r = await reserve({ wordContextId: ctxId, idempotencyKey: "ctx", requestFingerprint: "fc" });
  expect(r.status).toBe("reserved");
});

test("commit refuses a reservation past its TTL (can't push committed rows past the cap)", async () => {
  await reserve({ idempotencyKey: "slow", requestFingerprint: "fslow", ttlMs: 100, now: 1_000 });
  // generation ran longer than the TTL; the slot was already freed for others
  expect(await commitReservation(sql, "u1", "slow", 2_000)).toBe(false);
});

test("retry after expiry is surfaced as expired, not a live replay (no quota-free generation)", async () => {
  await reserve({ idempotencyKey: "exp", requestFingerprint: "fexp", ttlMs: 100, now: 1_000 });
  const replay = await reserve({ idempotencyKey: "exp", requestFingerprint: "fexp", ttlMs: 100, now: 5_000 });
  expect(replay.status).toBe("reservation_expired");
});

test("retry of a committed request replays the committed state (work already done)", async () => {
  await reserve({ idempotencyKey: "done", requestFingerprint: "fdone" });
  await commitReservation(sql, "u1", "done", 1_500);
  const replay = await reserve({ idempotencyKey: "done", requestFingerprint: "fdone" });
  expect(replay.status).toBe("idempotent_replay");
  if (replay.status === "idempotent_replay") expect(replay.state).toBe("committed");
});
