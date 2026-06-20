import type { Sql } from "./sql.ts";
import type { EnvelopeCrypto } from "./crypto.ts";
import type { ExplanationCache } from "./cache.ts";
import { previewLine, type WordExplanation } from "./provider.ts";
import { listWords } from "./words.ts";
import { latestContextsByWord } from "./contexts.ts";

// Anki / CSV export (M5, demand #6 — also the r/Anki distribution wedge). ONE row per active
// unit (US-6.1): surface form, most-recent context sentence, word-level definition, and a
// `target_language` column (CSV) / tag (Anki) so multi-language decks don't collide. A
// `context_language` column carries the sentence's language WHEN it differs from the unit's
// target (US-6.1: "context exports as-is, never translated").
//
// Layering: this is the FREE flywheel surface (§16) — the "definition" is the free word-level
// meaning (R2 cache), NOT the paid per-sentence context gloss. Context text is decrypted from
// the at-rest envelope (the user's own data; transient, never logged). Attribution ("captured
// with Capecho") is OPT-IN / off by default — the r/Anki community punishes anything spammy.

export const ATTRIBUTION = "captured with Capecho";

export type ExportFormat = "csv" | "anki" | "json";

export interface ExportRow {
  word: string; // surface unit, exactly as saved
  context: string; // most-recent context sentence (decrypted); "" if context-less
  contextLanguage: string; // the context's language WHEN it differs from targetLanguage (US-6.1); else ""
  definition: string; // the word-level summary (the only word-level explanation text); "" if not generated yet
  targetLanguage: string; // canonical BCP-47 — keeps multi-language decks from colliding
}

export interface ExportOptions {
  attribution?: boolean; // opt-in trailing `source` column (default: off)
}

// Workers subrequest budget guard. Export does 2 D1 queries + one R2 GET per unit with a
// `ready` definition; the bundled-paid plan caps subrequests at ~1000/request. Bound the
// per-word R2 reads so a huge word book can't turn export into a platform-limit 500: ALL
// units + contexts always export, and definitions PAST the cap are simply blank (graceful
// degradation, oldest-first). The proper fix — store the formatted definition in D1 so export
// is pure-D1 — is deferred to a schema change.
export const MAX_EXPORT_DEFINITION_LOOKUPS = 900;

/** The definition cell is the word's PRIMARY sense — the same one-line preview every compact surface
 *  derives from the structured blob (overlay-bilingual-plan.md D3): one home for the derivation
 *  (`previewLine`), no per-sense join here.
 *
 *  Defensive against a corrupt/partial blob: export reads each word's PERSISTED
 *  `explanation_cache_key` ([collectExportRows]), and a garbled/incomplete R2 blob is always
 *  possible. A blob with no usable sense yields a blank cell — graceful (the unit + context still
 *  export, like a definition past the lookup cap), never a throw that fails the WHOLE export. */
export function formatDefinition(exp: WordExplanation): string {
  const readings = (exp as unknown as { readings?: unknown }).readings;
  if (!Array.isArray(readings)) return "";
  return previewLine({ readings: readings as WordExplanation["readings"] });
}

/**
 * Collect one export row per ACTIVE unit, in the Word Book's order (created_at ASC). Cost:
 * 1 query for the units + 1 window-function query for their most-recent contexts; the
 * word-level definition is an R2 GET per unit that has a `ready` explanation, BOUNDED by
 * `maxDefinitionLookups` (subrequest guard). Export is a cold path — a deliberate user action.
 */
export async function collectExportRows(
  sql: Sql,
  crypto: EnvelopeCrypto,
  cache: ExplanationCache,
  userId: string,
  maxDefinitionLookups: number = MAX_EXPORT_DEFINITION_LOOKUPS,
): Promise<ExportRow[]> {
  const words = await listWords(sql, userId); // active only, ordered
  const contextByWord = await latestContextsByWord(sql, crypto, userId);

  const rows: ExportRow[] = [];
  let lookups = 0;
  for (const w of words) {
    let definition = "";
    if (w.explanation_state === "ready" && w.explanation_cache_key && lookups < maxDefinitionLookups) {
      lookups++; // count the subrequest even if the blob is missing/corrupt (it still cost a GET)
      const exp = await cache.get(w.explanation_cache_key);
      if (exp) definition = formatDefinition(exp);
    }
    const ctx = contextByWord.get(w.id);
    const ctxLang = ctx?.contextLanguage ?? null;
    rows.push({
      word: w.surface_unit,
      context: ctx?.text ?? "",
      contextLanguage: ctxLang && ctxLang !== w.target_language ? ctxLang : "", // only when it differs (US-6.1)
      definition,
      targetLanguage: w.target_language,
    });
  }
  return rows;
}

// Column order is stable across formats and across the attribution toggle, so the Anki
// `#tags column:` index below stays fixed. target_language is column 5 (1-indexed).
const HEADER = ["word", "context", "context_language", "definition", "target_language"] as const;
const TARGET_LANGUAGE_COLUMN = 5;
function rowCells(r: ExportRow): string[] {
  return [r.word, r.context, r.contextLanguage, r.definition, r.targetLanguage];
}

// --- CSV (spreadsheet target) ------------------------------------------------
// RFC-4180 quoting + spreadsheet formula-injection neutralization + a UTF-8 BOM so legacy
// Excel renders non-ASCII (zh-Hans / accented es) correctly.
const NEEDS_QUOTE = /[",\r\n]/;
// CWE-1236 (CSV injection): a cell whose first char is one of these is evaluated as a formula
// by Excel/Sheets/Numbers. RFC-4180 quoting only fixes PARSING, not cell semantics — so
// prefix a single quote (OWASP mitigation) to force the cell to be treated as text.
const FORMULA_LEAD = /^[=+\-@\t\r]/;
function csvField(s: string): string {
  const safe = FORMULA_LEAD.test(s) ? `'${s}` : s;
  return NEEDS_QUOTE.test(safe) ? `"${safe.replace(/"/g, '""')}"` : safe;
}

export function toCsv(rows: ExportRow[], opts: ExportOptions = {}): string {
  const header: string[] = [...HEADER];
  if (opts.attribution) header.push("source");
  const lines = [header.map(csvField).join(",")];
  for (const r of rows) {
    const cells = rowCells(r);
    if (opts.attribution) cells.push(ATTRIBUTION);
    lines.push(cells.map(csvField).join(","));
  }
  return "\uFEFF" + lines.join("\r\n") + "\r\n"; // BOM: legacy Excel renders non-ASCII correctly
}

// --- Anki (TSV + import directives) ------------------------------------------
// `#separator:tab` + `#html:false` (so a field with <, >, & is plain text, not HTML) +
// `#tags column:N` so target_language imports as a TAG (US-6.1: "column (CSV) / tag (Anki)").
// Tab/CR/LF within a field collapse to a space — Anki's TSV has no robust multi-line handling.
function ankiField(s: string, isFirst: boolean): string {
  const flat = s.replace(/[\t\r\n]+/g, " ");
  // A data line that STARTS with '#' is read by Anki as a comment/header and the whole note is
  // silently DROPPED — so a unit like "#define" / "#fff" would vanish from the export. Quote a
  // first field that would lead with '#' (the line then starts with '"', not '#'); also quote
  // any field containing a quote so it round-trips (RFC-4180: wrap + double internal quotes).
  const mustQuote = flat.includes('"') || (isFirst && flat.startsWith("#"));
  return mustQuote ? `"${flat.replace(/"/g, '""')}"` : flat;
}

export function toAnki(rows: ExportRow[], opts: ExportOptions = {}): string {
  const lines = ["#separator:tab", "#html:false", `#tags column:${TARGET_LANGUAGE_COLUMN}`];
  for (const r of rows) {
    const cells = rowCells(r);
    if (opts.attribution) cells.push(ATTRIBUTION);
    lines.push(cells.map((c, i) => ankiField(c, i === 0)).join("\t"));
  }
  return lines.join("\n") + "\n";
}

export interface RenderedExport {
  body: string;
  contentType: string;
  ext: string;
}

/** Render rows in the requested format, with the matching content-type + file extension. */
export function renderExport(rows: ExportRow[], format: ExportFormat, opts: ExportOptions = {}): RenderedExport {
  switch (format) {
    case "anki":
      return { body: toAnki(rows, opts), contentType: "text/tab-separated-values; charset=utf-8", ext: "txt" };
    case "json":
      // Structured rows for the one-click Anki `.apkg` deck. The deck (a SQLite `collection.anki2`
      // zipped with a media map) is assembled CLIENT-side, where a real SQLite engine is already
      // bundled (`sqlite3` via `sqlite3_flutter_libs`) — far cheaper + safer than a WASM SQLite in the
      // Worker. Same data the CSV/Anki text formats carry (one row per active unit, context decrypted),
      // just JSON-encoded; `attribution` is applied by the deck builder (as a note tag), so rows are raw.
      return { body: JSON.stringify(rows), contentType: "application/json; charset=utf-8", ext: "json" };
    case "csv":
    default:
      return { body: toCsv(rows, opts), contentType: "text/csv; charset=utf-8", ext: "csv" };
  }
}
