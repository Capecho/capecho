/// <reference types="@cloudflare/workers-types" />

// A tiny async SQL surface the cost-spine logic depends on, so the same logic runs
// against D1 in production and against bun:sqlite (the SAME SQLite engine, loading
// the REAL migration) in tests — high-fidelity correctness without a Workers runtime.

export type SqlValue = string | number | bigint | null | ArrayBuffer | Uint8Array;

export interface SqlStatement {
  bind(...values: SqlValue[]): SqlStatement;
  run(): Promise<{ rowsWritten: number }>;
  all<T = Record<string, unknown>>(): Promise<T[]>;
  first<T = Record<string, unknown>>(): Promise<T | null>;
}

export interface Sql {
  prepare(query: string): SqlStatement;
}

/** Production adapter over a Cloudflare D1 binding. */
export function fromD1(db: D1Database): Sql {
  const wrap = (stmt: D1PreparedStatement): SqlStatement => ({
    bind: (...values: SqlValue[]) => wrap(stmt.bind(...values)),
    run: async () => {
      const r = await stmt.run();
      return { rowsWritten: r.meta?.changes ?? 0 };
    },
    all: async <T>() => {
      const r = await stmt.all<T>();
      return r.results ?? [];
    },
    first: async <T>() => (await stmt.first<T>()) ?? null,
  });
  return { prepare: (query: string) => wrap(db.prepare(query)) };
}
