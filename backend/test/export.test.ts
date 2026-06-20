import { test, expect, beforeEach } from "bun:test";
import { freshDb, ids, seedAccount } from "./helpers/db.ts";
import { testCrypto } from "./helpers/crypto.ts";
import { saveWord, softDeleteWord, markExplanationReady } from "../src/words.ts";
import { createContext } from "../src/contexts.ts";
import { MemoryCache } from "../src/cache.ts";
import {
  collectExportRows,
  toCsv,
  toAnki,
  renderExport,
  formatDefinition,
  ATTRIBUTION,
  type ExportRow,
} from "../src/export.ts";
import type { WordExplanation } from "../src/provider.ts";
import type { Sql } from "../src/sql.ts";
import type { EnvelopeCrypto } from "../src/crypto.ts";

let sql: Sql;
let crypto: EnvelopeCrypto;
let cache: MemoryCache;
let newId: () => string;

beforeEach(async () => {
  ({ sql } = freshDb());
  crypto = await testCrypto();
  cache = new MemoryCache();
  newId = ids("e");
  await seedAccount(sql, "u1");
});

async function seedWord(surface: string, target = "en", createdAt = 1): Promise<string> {
  const w = await saveWord(sql, { userId: "u1", surfaceUnit: surface, targetLanguage: target, now: createdAt, newId });
  return w.status === "created" ? w.word.id : "";
}

async function addContext(
  wordId: string,
  text: string,
  createdAt: number,
  opts: { userId?: string; contextLanguage?: string } = {},
): Promise<void> {
  await createContext(sql, crypto, {
    userId: opts.userId ?? "u1",
    wordId,
    contextText: text,
    contextLanguage: opts.contextLanguage ?? null,
    now: createdAt,
    newId,
  });
}

// `definition` is the word's PRIMARY sense (previewLine, D3). The helper takes the sense text and
// builds a minimal senses blob whose primary sense is exactly that text.
const exp = (sense: string): WordExplanation => ({
  readings: [
    { pronunciationPrimary: "", pronunciationSecondary: "", kind: null, pos: [{ partOfSpeech: "noun", senses: [sense] }] },
  ],
});

async function ready(wordId: string, e: WordExplanation): Promise<void> {
  const key = `cache-${wordId}`;
  await cache.put(key, e);
  await markExplanationReady(sql, "u1", wordId, key, 2);
}

const rowsToMap = (rows: ExportRow[]): Map<string, ExportRow> => new Map(rows.map((r) => [r.word, r]));
const csvBody = (csv: string): string[] => csv.replace(/^\uFEFF/, "").split("\r\n"); // strip BOM, split lines

// --- data gathering (collectExportRows) --------------------------------------

test("one row per active unit: word + most-recent context (decrypted) + word-level definition + target tag", async () => {
  const w = await seedWord("serendipity", "en", 1);
  await addContext(w, "an old serendipity", 10);
  await addContext(w, "a fresh serendipity of events", 20); // newer — this one wins
  await ready(w, exp("a happy accident; finding good things by chance"));

  const rows = await collectExportRows(sql, crypto, cache, "u1");
  expect(rows).toHaveLength(1);
  expect(rows[0]).toEqual({
    word: "serendipity",
    context: "a fresh serendipity of events", // MAX(created_at) context, decrypted back
    contextLanguage: "",
    definition: "a happy accident; finding good things by chance",
    targetLanguage: "en",
  });
});

test("a context-less unit, and a unit whose explanation isn't ready, export with empty cells (never an error row)", async () => {
  await seedWord("bare", "en", 1); // no context, no explanation
  const w2 = await seedWord("pending", "en", 2);
  await addContext(w2, "a pending context", 10); // context but explanation never marked ready

  const byWord = rowsToMap(await collectExportRows(sql, crypto, cache, "u1"));
  expect(byWord.get("bare")).toEqual({ word: "bare", context: "", contextLanguage: "", definition: "", targetLanguage: "en" });
  expect(byWord.get("pending")).toEqual({ word: "pending", context: "a pending context", contextLanguage: "", definition: "", targetLanguage: "en" });
});

test("context_language is emitted ONLY when it differs from the unit's target_language (US-6.1)", async () => {
  const w = await seedWord("palabra", "es", 1);
  await addContext(w, "the word palabra appears in this english line", 10, { contextLanguage: "en" }); // differs → emit
  const w2 = await seedWord("hola", "es", 2);
  await addContext(w2, "hola amigo", 10, { contextLanguage: "es" }); // same → blank
  const w3 = await seedWord("adios", "es", 3);
  await addContext(w3, "adios amigo", 10); // null → blank

  const byWord = rowsToMap(await collectExportRows(sql, crypto, cache, "u1"));
  expect(byWord.get("palabra")?.contextLanguage).toBe("en");
  expect(byWord.get("hola")?.contextLanguage).toBe("");
  expect(byWord.get("adios")?.contextLanguage).toBe("");
});

test("multi-target: units in different target languages each carry their own tag (decks don't collide)", async () => {
  await seedWord("hola", "es", 1);
  await seedWord("hello", "en", 2);
  const byWord = rowsToMap(await collectExportRows(sql, crypto, cache, "u1"));
  expect(byWord.get("hola")?.targetLanguage).toBe("es");
  expect(byWord.get("hello")?.targetLanguage).toBe("en");
});

test("a soft-deleted unit is excluded from the export", async () => {
  await seedWord("keep", "en", 1);
  const gone = await seedWord("drop", "en", 2);
  await addContext(gone, "context on a doomed word", 10);
  await softDeleteWord(sql, "u1", gone, 99);

  const rows = await collectExportRows(sql, crypto, cache, "u1");
  expect(rows.map((r) => r.word)).toEqual(["keep"]);
});

test("export is account-scoped: another user's units never leak in", async () => {
  await seedAccount(sql, "u2");
  const mine = await seedWord("mine", "en", 1);
  await addContext(mine, "my own sentence", 10);
  const theirs = await saveWord(sql, { userId: "u2", surfaceUnit: "theirs", targetLanguage: "en", now: 1, newId });
  await addContext(theirs.status === "created" ? theirs.word.id : "", "their secret sentence", 10, { userId: "u2" });

  const rows = await collectExportRows(sql, crypto, cache, "u1");
  expect(rows.map((r) => r.word)).toEqual(["mine"]);
  expect(JSON.stringify(rows)).not.toContain("their secret sentence"); // no cross-tenant decrypt
});

test("the R2 definition lookup is bounded (subrequest guard): definitions past the cap are blank, all units still export", async () => {
  const a = await seedWord("alpha", "en", 1);
  const b = await seedWord("beta", "en", 2);
  await ready(a, exp("first"));
  await ready(b, exp("second"));

  const rows = await collectExportRows(sql, crypto, cache, "u1", 1); // cap at one R2 lookup
  const byWord = rowsToMap(rows);
  expect(rows).toHaveLength(2); // both units still export
  expect(byWord.get("alpha")?.definition).toBe("first"); // the one allowed lookup
  expect(byWord.get("beta")?.definition).toBe(""); // past the cap → blank, never a 500
});

test("rows come back in Word Book order (created_at ASC), and the stored context is NOT plaintext at rest", async () => {
  const a = await seedWord("alpha", "en", 1);
  await seedWord("beta", "en", 2);
  await addContext(a, "alpha in a sentence", 10);

  const rows = await collectExportRows(sql, crypto, cache, "u1");
  expect(rows.map((r) => r.word)).toEqual(["alpha", "beta"]);

  const stored = await sql.prepare(`SELECT context_ciphertext FROM word_contexts WHERE word_id = ?`).bind(a).first<{ context_ciphertext: Uint8Array }>();
  expect(String.fromCharCode(...(stored!.context_ciphertext as Uint8Array))).not.toContain("alpha in a sentence");
});

// --- formatDefinition --------------------------------------------------------

test("formatDefinition IS the word's summary — the same text every other surface shows", () => {
  expect(formatDefinition(exp("  a slide; to glide  "))).toBe("a slide; to glide"); // trimmed
  expect(formatDefinition(exp(""))).toBe("");
});

test("formatDefinition never throws on a corrupt/partial blob — it yields a blank definition", () => {
  // A `ready` word points at a PERSISTED cache_key; a garbled/incomplete R2 blob is always possible.
  // No usable `summary` → a blank cell (graceful, like a definition past the lookup cap), never a
  // throw that fails the whole export.
  expect(formatDefinition({ unit: "x" } as unknown as WordExplanation)).toBe("");
  expect(formatDefinition({ summary: 42 } as unknown as WordExplanation)).toBe("");
  expect(formatDefinition({ readings: [] } as unknown as WordExplanation)).toBe("");
});

test("a ready word whose cached blob is corrupt still exports (blank definition, not a 500)", async () => {
  const w = await seedWord("object", "en", 1);
  await addContext(w, "an object lesson", 10);
  const key = `cache-${w}`;
  await cache.put(key, { unit: "object", targetLanguage: "en", explanationLanguage: "en" } as unknown as WordExplanation);
  await markExplanationReady(sql, "u1", w, key, 2);
  const byWord = rowsToMap(await collectExportRows(sql, crypto, cache, "u1"));
  const row = byWord.get("object");
  expect(row?.definition).toBe(""); // corrupt blob → blank cell, the export still succeeds
  expect(row?.context).toBe("an object lesson"); // the unit + context still export
});

// --- CSV rendering -----------------------------------------------------------

test("toCsv emits a UTF-8 BOM + RFC-4180 header/rows (CRLF) and quotes fields with commas/quotes/newlines", () => {
  const csv = toCsv([
    { word: "slide", context: 'He said "down the slide," then ran.', contextLanguage: "", definition: "to glide\nsmoothly", targetLanguage: "en" },
  ]);
  expect(csv.startsWith("\uFEFF")).toBe(true); // BOM for legacy Excel
  const lines = csvBody(csv);
  expect(lines[0]).toBe("word,context,context_language,definition,target_language");
  expect(lines[1]).toBe('slide,"He said ""down the slide,"" then ran.",,"to glide\nsmoothly",en');
  expect(csv.endsWith("\r\n")).toBe(true);
});

test("toCsv neutralizes spreadsheet formula-injection: a cell starting with = + - @ is prefixed with ' (CWE-1236)", () => {
  const lines = csvBody(
    toCsv([{ word: "=2+3", context: "-1 degree", contextLanguage: "", definition: "@home, sweet home", targetLanguage: "en" }]),
  );
  // each formula-leading field gets a leading ' (Excel/Sheets/Numbers then treat it as text);
  // a neutralized field that ALSO contains a comma is still RFC-4180 quoted (neutralize → quote).
  expect(lines[1]).toBe("'=2+3,'-1 degree,,\"'@home, sweet home\",en");
});

test("attribution is opt-in: off by default, adds a `source` column only when requested", () => {
  const rows: ExportRow[] = [{ word: "w", context: "c", contextLanguage: "", definition: "d", targetLanguage: "en" }];
  expect(csvBody(toCsv(rows))[0]).toBe("word,context,context_language,definition,target_language"); // default: unbranded
  const branded = csvBody(toCsv(rows, { attribution: true }));
  expect(branded[0]).toBe("word,context,context_language,definition,target_language,source");
  expect(branded[1]).toBe(`w,c,,d,en,${ATTRIBUTION}`);
});

// --- Anki rendering ----------------------------------------------------------

test("toAnki emits import directives (tab separator, html:false, target_language→tags) and tab-safe rows, no BOM", () => {
  const out = toAnki([
    { word: "slide", context: "down\tthe\nslide <here>", contextLanguage: "", definition: "to glide", targetLanguage: "en" },
  ]);
  expect(out.startsWith("\uFEFF")).toBe(false); // Anki-native, no BOM
  const lines = out.split("\n");
  expect(lines[0]).toBe("#separator:tab");
  expect(lines[1]).toBe("#html:false"); // so "<here>" is plain text, not parsed as HTML
  expect(lines[2]).toBe("#tags column:5"); // target_language column → Anki tags
  // tab/newline within a field collapse to a space (Anki TSV has no robust quoting)
  expect(lines[3]).toBe("slide\tdown the slide <here>\t\tto glide\ten");
});

test("toAnki appends attribution as a trailing field when opted in (kept off the tags column)", () => {
  const out = toAnki([{ word: "w", context: "c", contextLanguage: "", definition: "d", targetLanguage: "en" }], { attribution: true });
  expect(out.split("\n")[3]).toBe(`w\tc\t\td\ten\t${ATTRIBUTION}`);
});

test("toAnki quotes a first field that would start with '#' so Anki doesn't drop the note [review-fix: Codex P2]", () => {
  const out = toAnki([
    { word: "#define", context: "use #define for macros", contextLanguage: "", definition: "a preprocessor directive", targetLanguage: "en" },
  ]);
  const dataLine = out.split("\n")[3];
  expect(dataLine.startsWith("#")).toBe(false); // would otherwise be read as an Anki comment and the whole row dropped
  expect(dataLine).toBe('"#define"\tuse #define for macros\t\ta preprocessor directive\ten');
});

test("toAnki RFC-4180-quotes any field containing a double-quote (doubled), wherever it sits", () => {
  const out = toAnki([{ word: "say", context: 'he said "hi"', contextLanguage: "", definition: "", targetLanguage: "en" }]);
  expect(out.split("\n")[3]).toBe('say\t"he said ""hi"""\t\t\ten');
});

test("renderExport selects body, content-type, and file extension per format", () => {
  const rows: ExportRow[] = [{ word: "w", context: "c", contextLanguage: "", definition: "d", targetLanguage: "en" }];
  const csv = renderExport(rows, "csv");
  expect(csv.contentType).toContain("text/csv");
  expect(csv.ext).toBe("csv");
  expect(csv.body.startsWith("\uFEFF")).toBe(true);
  const anki = renderExport(rows, "anki");
  expect(anki.contentType).toContain("tab-separated");
  expect(anki.ext).toBe("txt");
  expect(anki.body.split("\n")[0]).toBe("#separator:tab");
});

test("renderExport json returns the raw structured rows (for the client-built .apkg deck)", () => {
  const rows: ExportRow[] = [
    { word: "serendipity", context: "a fresh serendipity", contextLanguage: "", definition: "(n) luck", targetLanguage: "en" },
  ];
  const json = renderExport(rows, "json");
  expect(json.contentType).toContain("application/json");
  expect(json.ext).toBe("json");
  expect(JSON.parse(json.body)).toEqual(rows); // round-trips the exact ExportRow[] the deck builder consumes
});
