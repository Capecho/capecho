import { Database } from "bun:sqlite";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { Sql, SqlStatement, SqlValue } from "../../src/sql.ts";

// Apply ALL migrations in lexical order (0001_, 0002_, …) — the same set, in the same
// order, that wrangler applies to D1 — so tests run against the real, current schema.
const MIGRATIONS_DIR = fileURLToPath(new URL("../../migrations/", import.meta.url));
const MIGRATION_SQL = readdirSync(MIGRATIONS_DIR)
  .filter((f) => f.endsWith(".sql"))
  .sort()
  .map((f) => readFileSync(`${MIGRATIONS_DIR}${f}`, "utf8"))
  .join("\n");

function coerce(v: SqlValue): SqlValue {
  return v === undefined ? null : v;
}

/** bun:sqlite adapter — same SQLite engine D1 runs on, so SQL behavior matches. */
export function fromBunSqlite(db: Database): Sql {
  return {
    prepare(query: string): SqlStatement {
      let bound: SqlValue[] = [];
      const stmt: SqlStatement = {
        bind(...values: SqlValue[]) {
          bound = values.map(coerce);
          return stmt;
        },
        async run() {
          const info = db.query(query).run(...(bound as never[]));
          const changes = typeof (info as { changes?: number }).changes === "number"
            ? (info as { changes: number }).changes
            : 0;
          return { rowsWritten: changes };
        },
        async all<T>() {
          return db.query(query).all(...(bound as never[])) as T[];
        },
        async first<T>() {
          return (db.query(query).get(...(bound as never[])) as T) ?? null;
        },
      };
      return stmt;
    },
  };
}

/** A fresh in-memory DB with FKs ON and the real v1 migration applied. */
export function freshDb(): { raw: Database; sql: Sql } {
  const db = new Database(":memory:");
  db.exec("PRAGMA foreign_keys = ON;");
  db.exec(MIGRATION_SQL);
  return { raw: db, sql: fromBunSqlite(db) };
}

let seq = 0;
/** Deterministic id generator for tests. */
export function ids(prefix = "id"): () => string {
  return () => `${prefix}-${++seq}`;
}

export async function seedAccount(
  sql: Sql,
  id: string,
  opts: { tz?: string; explanationLanguage?: string } = {},
): Promise<void> {
  await sql
    .prepare(
      `INSERT INTO accounts (id, auth_provider, provider_subject, iana_timezone, explanation_language, created_at)
       VALUES (?, 'apple', ?, ?, ?, 1)`,
    )
    .bind(id, `subject-${id}`, opts.tz ?? "UTC", opts.explanationLanguage ?? "en")
    .run();
}
