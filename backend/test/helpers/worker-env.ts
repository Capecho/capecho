import { Database } from "bun:sqlite";
import { freshDb } from "./db.ts";
import { rand32, bytesToB64 } from "./crypto.ts";
import type { Sql, SqlValue } from "../../src/sql.ts";
import type { Env } from "../../src/index.ts";

// In-process integration harness: drive the REAL worker.fetch(request, env) entrypoint — the
// actual router, every handler, real SQL (bun:sqlite, same engine + migrations as D1), real
// envelope crypto, and real HTTP response building. This covers the wiring that the per-module
// unit tests can't: routing, status codes, headers (Content-Type/Disposition/Cache-Control),
// and the cross-handler request lifecycle.
//
// HONEST LIMITS (not the workerd runtime):
//  - The DO classes are STUBBED (stubDO throws on .get().fetch()), so the spend/generation half
//    — /explain, /explain/context, budget reserve/refund, single-flight, and GlobalBudget.mirror
//    (which writes via raw env.DB, bypassing fromD1) — is NOT integration-covered here. Its
//    logic is unit-tested; binding resolution is covered by `wrangler deploy --dry-run`.
//  - bun:sqlite returns BLOBs as Uint8Array, whereas real D1 returns ArrayBuffer (see
//    contexts.ts toBytes). The context round-trip test exercises the BLOB write+read path, but
//    only the bun (Uint8Array) branch — the D1 ArrayBuffer branch can only be covered by a real
//    workerd/Miniflare harness (a deferred follow-up).

/** A D1Database-shaped shim over bun:sqlite, matching exactly what fromD1() consumes. */
function bunAsD1(raw: Database): unknown {
  const mk = (query: string, bound: SqlValue[] = []): unknown => ({
    bind: (...vals: SqlValue[]) => mk(query, vals.map((v) => (v === undefined ? null : v))),
    run: async () => {
      // NOTE: bun:sqlite `changes` counts CASCADED rows; real D1 does not. Production code that
      // cares (purge/hard-delete) counts-before-delete, so this is safe today — but don't key
      // new logic on rowsWritten after a cascading DELETE and trust this harness.
      const info = raw.query(query).run(...(bound as never[]));
      return { success: true, meta: { changes: (info as { changes?: number }).changes ?? 0 } };
    },
    all: async () => ({ success: true, results: raw.query(query).all(...(bound as never[])), meta: {} }),
    first: async () => raw.query(query).get(...(bound as never[])) ?? null,
  });
  return { prepare: (q: string) => mk(q) };
}

/** In-memory R2 shim — just the get/put surface cache.ts uses. */
function memR2(): unknown {
  const m = new Map<string, string>();
  return {
    get: async (key: string) => (m.has(key) ? { text: async () => m.get(key)! } : null),
    put: async (key: string, value: string) => {
      m.set(key, value);
    },
  };
}

/** DO namespace stub — throws if a tested route actually reaches a Durable Object. */
function stubDO(): unknown {
  return {
    idFromName: (name: string) => ({ name }),
    get: () => ({ fetch: async () => { throw new Error("Durable Object unavailable in the in-process harness"); } }),
  };
}

export interface Harness {
  env: Env;
  sql: Sql;
  raw: Database;
}

/**
 * Build a worker Env backed by a fresh in-memory bun:sqlite D1 (real migrations applied), an
 * in-memory R2, DO stubs, header-trust auth (DEV_TRUST_USER_HEADER), and — unless `kek:false` —
 * a random envelope KEK at version 1.
 */
export function makeEnv(opts: { kek?: boolean } = {}): Harness {
  const { raw, sql } = freshDb();
  const env = {
    DB: bunAsD1(raw),
    EXPLANATION_CACHE: memR2(),
    GLOBAL_BUDGET: stubDO(),
    SINGLE_FLIGHT: stubDO(),
    DEV_TRUST_USER_HEADER: "true",
    ...(opts.kek === false ? {} : { CONTEXT_KEK: bytesToB64(rand32()), CONTEXT_KEK_VERSION: "1" }),
  } as unknown as Env;
  return { env, sql, raw };
}
