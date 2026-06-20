import { test, expect, beforeEach } from "bun:test";
import { freshDb, ids, seedAccount } from "./helpers/db.ts";
import { testCrypto } from "./helpers/crypto.ts";
import { saveWord } from "../src/words.ts";
import { createContext } from "../src/contexts.ts";
import { explainContext } from "../src/explain-context.ts";
import { BudgetLedger, MemoryBudgetStore } from "../src/budget-logic.ts";
import { MockContextProvider } from "../src/providers/mock-context.ts";
import { DEFAULT_COST_CONFIG } from "../src/config.ts";
import { parseMetricBatch, ingestMetricEvents } from "../src/metrics.ts";
import type { Sql } from "../src/sql.ts";
import type { EnvelopeCrypto } from "../src/crypto.ts";

// ENG-10: context plaintext must NEVER appear in logs/traces or in any persisted
// non-crypto column. This is a round-trip GREP test (not an assertion) so hygiene
// can't silently rot when a new log line is added. A known sensitive marker is driven
// through create + explain; we then grep all captured console output AND every stored
// string/blob column for it, and fail on any hit — while proving the ciphertext still
// decrypts to the marker (encryption actually happened, it wasn't just dropped).

const SECRET = "PT-DIAGNOSIS-9F2A acetaminophen 4000mg overdose note to self";

function captureConsole(): { logs: string[]; restore: () => void } {
  const logs: string[] = [];
  const methods = ["log", "info", "warn", "error", "debug"] as const;
  const orig: Record<string, unknown> = {};
  for (const m of methods) {
    orig[m] = (console as unknown as Record<string, unknown>)[m];
    (console as unknown as Record<string, (...a: unknown[]) => void>)[m] = (...a: unknown[]) => {
      logs.push(a.map((x) => (typeof x === "string" ? x : JSON.stringify(x))).join(" "));
    };
  }
  return {
    logs,
    restore: () => {
      for (const m of methods) (console as unknown as Record<string, unknown>)[m] = orig[m];
    },
  };
}

let sql: Sql;
let crypto: EnvelopeCrypto;
let newId: () => string;

beforeEach(async () => {
  ({ sql } = freshDb());
  crypto = await testCrypto();
  newId = ids("h");
  await seedAccount(sql, "u1");
});

/** All persisted bytes across the row, as one searchable latin1 string. */
async function dumpPersisted(): Promise<string> {
  const ctxRows = await sql.prepare(`SELECT * FROM word_contexts`).all<Record<string, unknown>>();
  const resRows = await sql.prepare(`SELECT * FROM context_quota_reservations`).all<Record<string, unknown>>();
  const flat = (rows: Record<string, unknown>[]) =>
    rows
      .flatMap((r) => Object.values(r))
      .map((v) => (v instanceof Uint8Array ? String.fromCharCode(...v) : String(v)))
      .join("");
  return `${flat(ctxRows)}${flat(resRows)}`;
}

test("ENG-10: the context plaintext never leaks to logs or any persisted non-crypto column", async () => {
  const w = await saveWord(sql, { userId: "u1", surfaceUnit: "note", targetLanguage: "en", now: 1, newId });
  const ctx = await createContext(sql, crypto, {
    userId: "u1",
    wordId: w.status === "created" ? w.word.id : "",
    contextText: SECRET,
    now: 2,
    newId,
  });
  const ctxId = ctx.status === "created" ? ctx.id : "";

  const cap = captureConsole();
  try {
    const r = await explainContext(
      {
        sql,
        crypto,
        provider: new MockContextProvider(),
        budget: new BudgetLedger(new MemoryBudgetStore()),
        config: DEFAULT_COST_CONFIG,
        now: () => 1000,
        newId,
      },
      {
        userId: "u1",
        wordContextId: ctxId,
        explanationLanguage: "en",
        quotaDay: "2026-05-27",
        budgetDayKey: "2026-05-27",
      },
    );
    expect(r.status).toBe("ready");
  } finally {
    cap.restore();
  }

  // 1) nothing logged contains the secret
  expect(cap.logs.join("\n")).not.toContain(SECRET);
  // 2) no persisted column (fingerprint, idempotency key, ciphertext bytes, …) contains it
  expect(await dumpPersisted()).not.toContain(SECRET);
  // 3) but the encryption really happened: the stored ciphertext decrypts back to the secret
  const { getContextRow, decryptContextText } = await import("../src/contexts.ts");
  const row = await getContextRow(sql, "u1", ctxId);
  expect(await decryptContextText(crypto, row!)).toBe(SECRET);
});

test("ENG-10: a provider error path also emits no plaintext", async () => {
  const w = await saveWord(sql, { userId: "u1", surfaceUnit: "note", targetLanguage: "en", now: 1, newId });
  const ctx = await createContext(sql, crypto, {
    userId: "u1",
    wordId: w.status === "created" ? w.word.id : "",
    contextText: SECRET,
    now: 2,
    newId,
  });

  const cap = captureConsole();
  try {
    await explainContext(
      {
        sql,
        crypto,
        provider: new MockContextProvider(() => {
          throw new Error("upstream failed"); // error message must not carry the sentence
        }),
        budget: new BudgetLedger(new MemoryBudgetStore()),
        config: DEFAULT_COST_CONFIG,
        now: () => 1000,
        newId,
      },
      {
        userId: "u1",
        wordContextId: ctx.status === "created" ? ctx.id : "",
        explanationLanguage: "en",
        quotaDay: "2026-05-27",
        budgetDayKey: "2026-05-27",
      },
    );
  } finally {
    cap.restore();
  }
  expect(cap.logs.join("\n")).not.toContain(SECRET);
});

test("ENG-10: the §14 metrics path stores/logs no text — the whitelist refuses to carry a sentence", async () => {
  // A misbehaving client tries to smuggle a sentence out via an unknown metric field. The strict
  // contract validator REBUILDS metadata from the whitelist, so the batch is rejected outright — the
  // secret never reaches the store.
  const exfil = parseMetricBatch({
    installId: "i",
    platform: "macos",
    contractVersion: 1,
    events: [
      {
        eventType: "capture_completed",
        clientRowId: "r",
        clientTs: 1,
        metadata: { selToPanelMs: 1, panelToSaveMs: 1, totalMs: 1, source: "ocr", hasContext: true, langOverride: false, leakedSentence: SECRET },
      },
    ],
  });
  expect(exfil.ok).toBe(false); // unknown key → 400, never ingested

  // A VALID batch ingests; grep the whole table + captured logs for the secret → absent.
  const cap = captureConsole();
  try {
    const valid = parseMetricBatch({
      installId: "i",
      platform: "macos",
      contractVersion: 1,
      events: [{ eventType: "capture_abandoned", clientTs: 1, metadata: { selToPanelMs: 5 } }],
    });
    expect(valid.ok).toBe(true);
    if (valid.ok) await ingestMetricEvents(sql, { userId: null, batch: valid.value, now: 1000, dailyCap: 100, newId });
  } finally {
    cap.restore();
  }
  const rows = await sql.prepare(`SELECT * FROM metric_events`).all<Record<string, unknown>>();
  const dump = rows.flatMap((r) => Object.values(r)).map((v) => String(v)).join("");
  expect(dump).not.toContain(SECRET);
  expect(cap.logs.join("\n")).not.toContain(SECRET);
});
