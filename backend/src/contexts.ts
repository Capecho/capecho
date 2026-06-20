import { canonicalizeBcp47 } from "@capecho/lang";
import type { Sql, SqlValue } from "./sql.ts";
import { EnvelopeCrypto, type Envelope } from "./crypto.ts";
import { getWordById } from "./words.ts";
import type { ContextExplanation } from "./validate-context.ts";

// AAD binds each envelope to its record + field, so a DB-write attacker can't move a
// valid blob to another row or swap context↔gloss↔source-title within a row (distinct prefixes).
const contextAad = (id: string): string => `ctx:${id}`;
const glossAad = (id: string): string => `gloss:${id}`;
const sourceTitleAad = (id: string): string => `srctitle:${id}`;

// Bound the plaintext source-metadata fields (untrusted, from a window title / app name). Titles are
// short; a multi-KB blob is junk we truncate rather than store. The encrypted title shares the
// context size envelope intent but is far tighter.
const MAX_SOURCE_APP_CHARS = 200;
const MAX_SOURCE_TITLE_CHARS = 1000;

// The encrypted gloss payload also records the gloss language + prompt version, so a
// re-view can tell whether a stored gloss still matches the requested language/version.
export interface StoredGloss extends ContextExplanation {
  explanationLanguage: string;
}

// Context storage (T8). Context text + private glosses are ENCRYPTED AT REST via the
// envelope crypto; the decrypt path is server-side, transient, and never logged. A
// context is 1:N under a unit; the gloss lives in the same row (so deleting a context
// deletes its gloss). Editing the context text INVALIDATES the stored gloss (US-7.1).

// A sentence, not a paragraph — bound the input (untrusted OCR/text); the free word
// layer is far tighter (input.ts), but the context layer still rejects an oversized blob.
export const MAX_CONTEXT_CHARS = 2000;

export interface ContextView {
  id: string;
  wordId: string;
  contextLanguage: string | null;
  contextText: string; // DECRYPTED for display (transient; never logged)
  spanStart: number | null;
  spanEnd: number | null;
  // DECRYPTED private gloss (one combined field), or null if not yet generated / a stale-version payload.
  meaning: string | null; // the unit's in-context meaning AND the whole sentence's meaning
  // Capture-source metadata ("where I met this word"). sourceTitle is DECRYPTED for display
  // (transient; never logged). All null when the capture didn't carry them.
  sourceApp: string | null;
  sourceTitle: string | null;
  detectedLanguage: string | null;
  detectedLanguageConfidence: number | null;
  createdAt: number;
}

interface ContextRow {
  id: string;
  word_id: string;
  user_id: string;
  context_language: string | null;
  context_ciphertext: Uint8Array | ArrayBuffer | null;
  context_wrapped_key: Uint8Array | ArrayBuffer | null;
  context_nonce: Uint8Array | ArrayBuffer | null;
  context_key_version: number | null;
  span_start: number | null;
  span_end: number | null;
  gloss_ciphertext: Uint8Array | ArrayBuffer | null;
  gloss_wrapped_key: Uint8Array | ArrayBuffer | null;
  gloss_nonce: Uint8Array | ArrayBuffer | null;
  gloss_key_version: number | null;
  // Capture-source metadata (v3): source_app + detected_language[_confidence] are plaintext;
  // source_title is encrypted at rest (its own envelope, AAD "srctitle:<id>").
  source_app: string | null;
  source_title_ciphertext: Uint8Array | ArrayBuffer | null;
  source_title_wrapped_key: Uint8Array | ArrayBuffer | null;
  source_title_nonce: Uint8Array | ArrayBuffer | null;
  source_title_key_version: number | null;
  detected_language: string | null;
  detected_language_confidence: number | null;
  created_at: number;
}

const ROW_COLS =
  "id, word_id, user_id, context_language, context_ciphertext, context_wrapped_key, context_nonce, context_key_version, span_start, span_end, gloss_ciphertext, gloss_wrapped_key, gloss_nonce, gloss_key_version, source_app, source_title_ciphertext, source_title_wrapped_key, source_title_nonce, source_title_key_version, detected_language, detected_language_confidence, created_at";

/** NFC-normalize + trim a plaintext source field, dropping empties and truncating to [max] chars
 *  (window titles/app names are short — a multi-KB value is junk we bound rather than store). */
function boundedOrNull(v: string | null | undefined, max: number): string | null {
  if (v == null) return null;
  const t = v.normalize("NFC").trim();
  if (t.length === 0) return null;
  return t.length > max ? t.slice(0, max) : t;
}

/** Normalize a BLOB read (bun:sqlite → Uint8Array, D1 → ArrayBuffer) to bytes. */
function toBytes(v: Uint8Array | ArrayBuffer | null): Uint8Array | null {
  if (v == null) return null;
  return v instanceof Uint8Array ? v : new Uint8Array(v);
}

function contextEnvelope(row: ContextRow): Envelope | null {
  const ciphertext = toBytes(row.context_ciphertext);
  const wrappedKey = toBytes(row.context_wrapped_key);
  const nonce = toBytes(row.context_nonce);
  if (!ciphertext || !wrappedKey || !nonce || row.context_key_version == null) return null;
  return { ciphertext, wrappedKey, nonce, keyVersion: row.context_key_version };
}

function glossEnvelope(row: ContextRow): Envelope | null {
  const ciphertext = toBytes(row.gloss_ciphertext);
  const wrappedKey = toBytes(row.gloss_wrapped_key);
  const nonce = toBytes(row.gloss_nonce);
  if (!ciphertext || !wrappedKey || !nonce || row.gloss_key_version == null) return null;
  return { ciphertext, wrappedKey, nonce, keyVersion: row.gloss_key_version };
}

function sourceTitleEnvelope(row: ContextRow): Envelope | null {
  const ciphertext = toBytes(row.source_title_ciphertext);
  const wrappedKey = toBytes(row.source_title_wrapped_key);
  const nonce = toBytes(row.source_title_nonce);
  if (!ciphertext || !wrappedKey || !nonce || row.source_title_key_version == null) return null;
  return { ciphertext, wrappedKey, nonce, keyVersion: row.source_title_key_version };
}

export type CreateContextOutcome =
  | { status: "created"; id: string }
  | { status: "word_not_found" }
  | { status: "context_too_large" }
  | { status: "empty_context" };

export interface CreateContextInput {
  userId: string;
  wordId: string;
  contextText: string;
  contextLanguage?: string | null;
  spanStart?: number | null;
  spanEnd?: number | null;
  /** Capture-source provenance ("where I met this word"). sourceApp + detectedLanguage[Confidence]
   *  are stored PLAINTEXT; sourceTitle is sealed in its own envelope. All optional — absent for a
   *  manually-typed context (POST /contexts) or a backlog row captured before this shipped. */
  sourceApp?: string | null;
  sourceTitle?: string | null;
  detectedLanguage?: string | null;
  detectedLanguageConfidence?: number | null;
  now: number;
  newId: () => string;
  /** Explicit row id (default: newId()). The pre-login claim passes a DETERMINISTIC id
   *  derived from the client-row-id so a retry-after-partial-failure can't duplicate the
   *  context (insert is ON CONFLICT(id) DO NOTHING). */
  id?: string;
}

export async function createContext(
  sql: Sql,
  crypto: EnvelopeCrypto,
  input: CreateContextInput,
): Promise<CreateContextOutcome> {
  const text = (input.contextText ?? "").normalize("NFC");
  if (text.trim().length === 0) return { status: "empty_context" };
  if (text.length > MAX_CONTEXT_CHARS) return { status: "context_too_large" };

  // Canonicalize-or-drop the (optional) context language at the chokepoint (covers POST /contexts AND
  // the pre-login claim): only a real BCP-47 value is stored — junk degrades to "unknown" (NULL),
  // never to a wrong label. NULL is the NORMAL value: the client sends a language only when the
  // text's script makes it certain; it is never defaulted from the target.
  const contextLanguage = input.contextLanguage == null ? null : canonicalizeBcp47(input.contextLanguage);

  // The captured span is optional rendering metadata (the UI falls back to plain text),
  // and the schema CHECK requires both-null or a non-negative start<=end pair. NORMALIZE a
  // malformed / one-sided / inverted span to none (keep the context) rather than throw the
  // DB constraint into a 500 — never lose the captured text over a bad highlight offset.
  const ss = input.spanStart ?? null;
  const se = input.spanEnd ?? null;
  const spanOk =
    Number.isInteger(ss) && Number.isInteger(se) && (ss as number) >= 0 && (se as number) >= (ss as number);
  const spanStart = spanOk ? ss : null;
  const spanEnd = spanOk ? se : null;

  // Capture-source metadata. source_app + detected_language are PLAINTEXT (canonicalize/bound-or-drop);
  // source_title is sealed in its own envelope below. Confidence is PAIRED with the language — kept only
  // when both a real BCP-47 language AND a finite number are present, clamped into [0,1].
  const sourceApp = boundedOrNull(input.sourceApp, MAX_SOURCE_APP_CHARS);
  const sourceTitlePlain = boundedOrNull(input.sourceTitle, MAX_SOURCE_TITLE_CHARS);
  const detectedLanguage = input.detectedLanguage == null ? null : canonicalizeBcp47(input.detectedLanguage);
  const detectedLanguageConfidence =
    detectedLanguage != null &&
    typeof input.detectedLanguageConfidence === "number" &&
    Number.isFinite(input.detectedLanguageConfidence)
      ? Math.min(1, Math.max(0, input.detectedLanguageConfidence))
      : null;

  // Same-owner word must exist (the composite FK enforces this at insert, but check
  // first for a clean 404 instead of a thrown constraint error).
  const word = await getWordById(sql, input.userId, input.wordId);
  if (!word || word.deleted_at !== null) return { status: "word_not_found" };

  const id = input.id ?? input.newId();
  const env = await crypto.seal(text, contextAad(id));
  // Seal the source title under its own per-record DEK + AAD ("srctitle:<id>"), so a DB-write attacker
  // can't transplant it into the context/gloss columns. Null when there was no title.
  const titleEnv = sourceTitlePlain == null ? null : await crypto.seal(sourceTitlePlain, sourceTitleAad(id));
  await sql
    .prepare(
      `INSERT INTO word_contexts
         (id, word_id, user_id, context_language, context_ciphertext, context_wrapped_key, context_nonce, context_key_version, span_start, span_end,
          source_app, source_title_ciphertext, source_title_wrapped_key, source_title_nonce, source_title_key_version, detected_language, detected_language_confidence, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (id) DO NOTHING`,
    )
    .bind(
      id,
      input.wordId,
      input.userId,
      contextLanguage,
      env.ciphertext as SqlValue,
      env.wrappedKey as SqlValue,
      env.nonce as SqlValue,
      env.keyVersion,
      spanStart,
      spanEnd,
      sourceApp,
      (titleEnv?.ciphertext ?? null) as SqlValue,
      (titleEnv?.wrappedKey ?? null) as SqlValue,
      (titleEnv?.nonce ?? null) as SqlValue,
      titleEnv?.keyVersion ?? null,
      detectedLanguage,
      detectedLanguageConfidence,
      input.now,
    )
    .run();
  return { status: "created", id };
}

/** Internal: fetch a single context row, scoped to its owner. */
export async function getContextRow(sql: Sql, userId: string, id: string): Promise<ContextRow | null> {
  return sql
    .prepare(`SELECT ${ROW_COLS} FROM word_contexts WHERE id = ? AND user_id = ?`)
    .bind(id, userId)
    .first<ContextRow>();
}

/** Decrypt a context row's sentence (transient; never logged). */
export async function decryptContextText(crypto: EnvelopeCrypto, row: ContextRow): Promise<string> {
  const env = contextEnvelope(row);
  if (!env) throw new Error("context row has no encrypted context");
  return crypto.open(env, contextAad(row.id));
}

/** Decrypt a row's stored private gloss payload, or null if none/invalid. */
export async function readGlossPayload(crypto: EnvelopeCrypto, row: ContextRow): Promise<StoredGloss | null> {
  const env = glossEnvelope(row);
  if (!env) return null;
  try {
    return JSON.parse(await crypto.open(env, glossAad(row.id))) as StoredGloss;
  } catch {
    return null;
  }
}

/** GET path: list a unit's contexts, DECRYPTED for display (context text + any gloss). */
export async function listContextsForWord(
  sql: Sql,
  crypto: EnvelopeCrypto,
  userId: string,
  wordId: string,
): Promise<ContextView[]> {
  const rows = await sql
    .prepare(`SELECT ${ROW_COLS} FROM word_contexts WHERE user_id = ? AND word_id = ? ORDER BY created_at ASC, id ASC`)
    .bind(userId, wordId)
    .all<ContextRow>();
  const out: ContextView[] = [];
  for (const row of rows) {
    const env = contextEnvelope(row);
    const gloss = await readGlossPayload(crypto, row);
    const titleEnv = sourceTitleEnvelope(row);
    out.push({
      id: row.id,
      wordId: row.word_id,
      contextLanguage: row.context_language,
      contextText: env ? await crypto.open(env, contextAad(row.id)) : "",
      spanStart: row.span_start,
      spanEnd: row.span_end,
      // ?? null degrades a stale-version payload (an old two-field shape, no `meaning`) to "not explained".
      meaning: gloss?.meaning ?? null,
      sourceApp: row.source_app,
      sourceTitle: titleEnv ? await crypto.open(titleEnv, sourceTitleAad(row.id)) : null,
      detectedLanguage: row.detected_language,
      detectedLanguageConfidence: row.detected_language_confidence,
      createdAt: row.created_at,
    });
  }
  return out;
}

/**
 * Export helper (M5): the MOST-RECENT context per ACTIVE unit for a user, DECRYPTED, as a
 * map word_id → { text, contextLanguage }. One window-function query (+ in-process decrypt —
 * crypto is local CPU, not a subrequest), so context-gathering is O(1) D1 round-trips no
 * matter how large the word book is. Soft-deleted units are excluded (their contexts aren't
 * cascaded away by a tombstone, so the JOIN filters them). Ordering is created_at DESC; the
 * `id DESC` second key is only a STABLE tiebreaker for same-millisecond contexts (row ids are
 * random uuids, so it picks deterministically, not by true recency — an acceptable edge).
 */
export async function latestContextsByWord(
  sql: Sql,
  crypto: EnvelopeCrypto,
  userId: string,
): Promise<Map<string, { text: string; contextLanguage: string | null }>> {
  const rows = await sql
    .prepare(
      `SELECT ${ROW_COLS} FROM (
         SELECT wc.*, ROW_NUMBER() OVER (PARTITION BY wc.word_id ORDER BY wc.created_at DESC, wc.id DESC) AS rn
         FROM word_contexts wc
         JOIN words w ON w.id = wc.word_id AND w.user_id = wc.user_id
         WHERE wc.user_id = ? AND w.deleted_at IS NULL
       ) WHERE rn = 1`,
    )
    .bind(userId)
    .all<ContextRow>();
  const out = new Map<string, { text: string; contextLanguage: string | null }>();
  for (const row of rows) {
    const env = contextEnvelope(row);
    out.set(row.word_id, {
      text: env ? await crypto.open(env, contextAad(row.id)) : "",
      contextLanguage: row.context_language,
    });
  }
  return out;
}

/** Edit the context text: re-encrypt AND invalidate the stored gloss (US-7.1) so a
 *  re-view regenerates (and re-charges) rather than showing a gloss for the old text. */
export async function editContextText(
  sql: Sql,
  crypto: EnvelopeCrypto,
  userId: string,
  id: string,
  newText: string,
): Promise<{ status: "updated" | "not_found" | "context_too_large" | "empty_context" }> {
  const text = (newText ?? "").normalize("NFC");
  if (text.trim().length === 0) return { status: "empty_context" };
  if (text.length > MAX_CONTEXT_CHARS) return { status: "context_too_large" };
  const env = await crypto.seal(text, contextAad(id));
  const r = await sql
    .prepare(
      `UPDATE word_contexts
         SET context_ciphertext = ?, context_wrapped_key = ?, context_nonce = ?, context_key_version = ?,
             gloss_ciphertext = NULL, gloss_wrapped_key = NULL, gloss_nonce = NULL, gloss_key_version = NULL
       WHERE id = ? AND user_id = ?`,
    )
    .bind(env.ciphertext as SqlValue, env.wrappedKey as SqlValue, env.nonce as SqlValue, env.keyVersion, id, userId)
    .run();
  return { status: r.rowsWritten === 1 ? "updated" : "not_found" };
}

/**
 * Encrypt + store the private gloss against a context (the metered result, US-3.2).
 * GUARDED by `expectedContextNonce` — the context nonce read when generation started:
 * if the user edited the context mid-generation (editContextText re-seals with a fresh
 * nonce and clears the gloss), the WHERE matches no row and we return false, so a
 * gloss for the OLD sentence is never written onto the NEW ciphertext (TOCTOU guard).
 */
export async function storeGloss(
  sql: Sql,
  crypto: EnvelopeCrypto,
  userId: string,
  contextId: string,
  payload: StoredGloss,
  expectedContextNonce: Uint8Array | ArrayBuffer,
): Promise<boolean> {
  const env = await crypto.seal(JSON.stringify(payload), glossAad(contextId));
  const guard = toBytes(expectedContextNonce)!;
  const r = await sql
    .prepare(
      `UPDATE word_contexts
         SET gloss_ciphertext = ?, gloss_wrapped_key = ?, gloss_nonce = ?, gloss_key_version = ?
       WHERE id = ? AND user_id = ? AND context_nonce = ?`,
    )
    .bind(
      env.ciphertext as SqlValue,
      env.wrappedKey as SqlValue,
      env.nonce as SqlValue,
      env.keyVersion,
      contextId,
      userId,
      guard as SqlValue,
    )
    .run();
  return r.rowsWritten === 1;
}

/** Delete a context (its gloss lives in the same row, so it goes too). */
export async function deleteContext(sql: Sql, userId: string, id: string): Promise<boolean> {
  const r = await sql
    .prepare(`DELETE FROM word_contexts WHERE id = ? AND user_id = ?`)
    .bind(id, userId)
    .run();
  return r.rowsWritten === 1;
}
