import { test, expect, beforeEach } from "bun:test";
import { freshDb, ids, seedAccount } from "./helpers/db.ts";
import { testCrypto } from "./helpers/crypto.ts";
import { saveWord } from "../src/words.ts";
import {
  createContext,
  listContextsForWord,
  editContextText,
  deleteContext,
  storeGloss,
  getContextRow,
  readGlossPayload,
  MAX_CONTEXT_CHARS,
} from "../src/contexts.ts";
import type { Sql } from "../src/sql.ts";
import type { EnvelopeCrypto } from "../src/crypto.ts";

let sql: Sql;
let crypto: EnvelopeCrypto;
let newId: () => string;
let wordId: string;

beforeEach(async () => {
  ({ sql } = freshDb());
  crypto = await testCrypto();
  newId = ids("c");
  await seedAccount(sql, "u1");
  const w = await saveWord(sql, { userId: "u1", surfaceUnit: "slide", targetLanguage: "en", now: 1, newId });
  wordId = w.status === "created" ? w.word.id : "";
});

const create = (text: string, over: Record<string, unknown> = {}) =>
  createContext(sql, crypto, { userId: "u1", wordId, contextText: text, now: 10, newId, ...over });

test("create stores an ENCRYPTED context; list decrypts it back (round-trip, gloss null)", async () => {
  const out = await create("The kids went down the slide at the park.");
  expect(out.status).toBe("created");

  const list = await listContextsForWord(sql, crypto, "u1", wordId);
  expect(list).toHaveLength(1);
  expect(list[0]!.contextText).toBe("The kids went down the slide at the park.");
  expect(list[0]!.meaning).toBeNull();

  // and the stored bytes are NOT the plaintext
  const row = await getContextRow(sql, "u1", out.status === "created" ? out.id : "");
  const ct = row!.context_ciphertext as Uint8Array;
  expect(String.fromCharCode(...ct)).not.toContain("slide at the park");
});

test("create rejects an empty, oversized, or orphan-word context", async () => {
  expect((await create("   ")).status).toBe("empty_context");
  expect((await create("x".repeat(MAX_CONTEXT_CHARS + 1))).status).toBe("context_too_large");
  expect((await createContext(sql, crypto, { userId: "u1", wordId: "nope", contextText: "x", now: 1, newId })).status).toBe(
    "word_not_found",
  );
});

test("context_language is canonicalized-or-dropped at the chokepoint (covers POST /contexts AND claim)", async () => {
  // Only a real BCP-47 value may be stored; junk degrades to NULL (unknown) — never a wrong label.
  // NULL is the NORMAL value: the client sends a language only when the text's script pins one.
  const cased = await create("a cased tag", { contextLanguage: "EN" });
  const junk = await create("a junk tag", { contextLanguage: "not a tag!!" });
  const absent = await create("no tag at all");
  const list = await listContextsForWord(sql, crypto, "u1", wordId);
  const byId = (o: Awaited<ReturnType<typeof create>>) =>
    list.find((c) => c.id === (o.status === "created" ? o.id : ""));
  expect(byId(cased)?.contextLanguage).toBe("en"); // canonicalized, not raw "EN"
  expect(byId(junk)?.contextLanguage).toBeNull();
  expect(byId(absent)?.contextLanguage).toBeNull();
});

test("a malformed span is normalized away (context stored, no 500) [review-fix: Codex P2]", async () => {
  const inverted = await create("inverted span", { spanStart: 10, spanEnd: 5 });
  expect(inverted.status).toBe("created"); // not a thrown DB CHECK
  const oneSided = await create("one-sided span", { spanStart: 3, spanEnd: null });
  expect(oneSided.status).toBe("created");
  const list = await listContextsForWord(sql, crypto, "u1", wordId);
  for (const c of list) {
    expect(c.spanStart).toBeNull();
    expect(c.spanEnd).toBeNull();
  }
  // a VALID span is still kept
  const ok = await create("good span", { spanStart: 2, spanEnd: 7 });
  const okRow = (await listContextsForWord(sql, crypto, "u1", wordId)).find((c) => c.id === (ok.status === "created" ? ok.id : ""));
  expect(okRow?.spanStart).toBe(2);
  expect(okRow?.spanEnd).toBe(7);
});

test("source metadata: app/language stored plaintext, TITLE encrypted at rest, all decrypt back", async () => {
  const out = await create("The kids went down the slide.", {
    sourceApp: "Google Chrome",
    sourceTitle: "Slides at the park — private journal",
    detectedLanguage: "EN", // canonicalized to "en"
    detectedLanguageConfidence: 0.91,
  });
  expect(out.status).toBe("created");
  const id = out.status === "created" ? out.id : "";

  // Raw row: source_app + detected_language are PLAINTEXT columns; the title is an envelope (no plaintext).
  const row = await getContextRow(sql, "u1", id);
  expect(row!.source_app).toBe("Google Chrome");
  expect(row!.detected_language).toBe("en");
  expect(row!.detected_language_confidence).toBe(0.91);
  expect(row!.source_title_ciphertext).not.toBeNull();
  expect(row!.source_title_key_version).not.toBeNull();
  const titleCt = row!.source_title_ciphertext as Uint8Array;
  expect(String.fromCharCode(...titleCt)).not.toContain("private journal");

  // List decrypts the title and surfaces the plaintext fields.
  const list = await listContextsForWord(sql, crypto, "u1", wordId);
  expect(list[0]!.sourceApp).toBe("Google Chrome");
  expect(list[0]!.sourceTitle).toBe("Slides at the park — private journal");
  expect(list[0]!.detectedLanguage).toBe("en");
  expect(list[0]!.detectedLanguageConfidence).toBe(0.91);
});

test("source metadata: confidence is paired with a valid language and clamped; junk drops to null", async () => {
  // No language ⇒ confidence dropped (never a bare number with no language).
  const noLang = await create("no language here", { detectedLanguageConfidence: 0.8 });
  // Junk language ⇒ null language ⇒ null confidence.
  const junk = await create("junk language", { detectedLanguage: "not a tag!!", detectedLanguageConfidence: 0.5 });
  // Out-of-range confidence is clamped into [0,1].
  const hot = await create("too confident", { detectedLanguage: "en", detectedLanguageConfidence: 9 });
  const list = await listContextsForWord(sql, crypto, "u1", wordId);
  const byId = (o: Awaited<ReturnType<typeof create>>) => list.find((c) => c.id === (o.status === "created" ? o.id : ""));
  expect(byId(noLang)?.detectedLanguage).toBeNull();
  expect(byId(noLang)?.detectedLanguageConfidence).toBeNull();
  expect(byId(junk)?.detectedLanguage).toBeNull();
  expect(byId(junk)?.detectedLanguageConfidence).toBeNull();
  expect(byId(hot)?.detectedLanguageConfidence).toBe(1);
});

test("source metadata: a context with none stored reads back all-null", async () => {
  const out = await create("plain context, no source");
  expect(out.status).toBe("created");
  const row = await getContextRow(sql, "u1", out.status === "created" ? out.id : "");
  expect(row!.source_app).toBeNull();
  expect(row!.source_title_ciphertext).toBeNull();
  expect(row!.detected_language).toBeNull();
  const view = (await listContextsForWord(sql, crypto, "u1", wordId))[0]!;
  expect(view.sourceApp).toBeNull();
  expect(view.sourceTitle).toBeNull();
  expect(view.detectedLanguage).toBeNull();
  expect(view.detectedLanguageConfidence).toBeNull();
});

test("a different account cannot create a context against another user's word", async () => {
  await seedAccount(sql, "u2");
  const out = await createContext(sql, crypto, { userId: "u2", wordId, contextText: "x", now: 1, newId });
  expect(out.status).toBe("word_not_found"); // same-owner check
});

test("storeGloss + readGlossPayload round-trips the encrypted private gloss", async () => {
  const out = await create("She gave a knowing slide of her eyes.");
  const id = out.status === "created" ? out.id : "";
  const before = await getContextRow(sql, "u1", id);
  expect(
    await storeGloss(
      sql,
      crypto,
      "u1",
      id,
      {
        meaning: "a smooth sideways movement; she gave a knowing sideways glance.",
        promptVersion: "v1",
        explanationLanguage: "en",
      },
      before!.context_nonce!,
    ),
  ).toBe(true);

  const row = await getContextRow(sql, "u1", id);
  const payload = await readGlossPayload(crypto, row!);
  expect(payload?.meaning).toBe("a smooth sideways movement; she gave a knowing sideways glance.");

  const list = await listContextsForWord(sql, crypto, "u1", wordId);
  expect(list[0]!.meaning).toBe("a smooth sideways movement; she gave a knowing sideways glance.");
});

test("editing the context text re-encrypts AND invalidates the stored gloss (US-7.1)", async () => {
  const out = await create("original sentence");
  const id = out.status === "created" ? out.id : "";
  const before = await getContextRow(sql, "u1", id);
  await storeGloss(
    sql,
    crypto,
    "u1",
    id,
    {
      meaning: "stale answer for the original sentence",
      promptVersion: "v1",
      explanationLanguage: "en",
    },
    before!.context_nonce!,
  );

  const edit = await editContextText(sql, crypto, "u1", id, "a totally different sentence");
  expect(edit.status).toBe("updated");

  const list = await listContextsForWord(sql, crypto, "u1", wordId);
  expect(list[0]!.contextText).toBe("a totally different sentence");
  expect(list[0]!.meaning).toBeNull(); // gloss invalidated by the edit
});

test("delete removes the context (and its gloss, which lives in the same row)", async () => {
  const out = await create("delete me");
  const id = out.status === "created" ? out.id : "";
  const before = await getContextRow(sql, "u1", id);
  await storeGloss(
    sql,
    crypto,
    "u1",
    id,
    { meaning: "s", promptVersion: "v1", explanationLanguage: "en" },
    before!.context_nonce!,
  );
  expect(await deleteContext(sql, "u1", id)).toBe(true);
  expect(await listContextsForWord(sql, crypto, "u1", wordId)).toHaveLength(0);
  expect(await deleteContext(sql, "u1", id)).toBe(false); // idempotent-ish: already gone
});
