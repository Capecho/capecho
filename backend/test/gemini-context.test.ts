import { test, expect } from "bun:test";
import {
  GeminiContextProvider,
  buildContextPrompt,
  resolveMarkedRange,
} from "../src/providers/gemini-context.ts";
import { validateContextExplanation } from "../src/validate-context.ts";
import type { ContextGenerateRequest } from "../src/context-provider.ts";

// Tests the context provider's CONTRACT with an injected generator — no network, no AI-SDK load. The
// thin SDK glue (gemini-model.ts) is verified by `wrangler deploy --dry-run` bundling + the eval.

const req: ContextGenerateRequest = {
  unit: "bow",
  targetLanguage: "en",
  contextText: "She took a bow as the audience applauded.",
  contextLanguage: null,
  explanationLanguage: "zh-Hans",
};

test("maps the model's { meaning } into a raw payload that passes context cache-write validation", async () => {
  const provider = new GeminiContextProvider(async () => ({
    meaning: "这里 bow 指演员谢幕时的鞠躬；这句话说观众鼓掌时，她鞠了一躬。",
  }));
  const out = await provider.generate(req);
  const v = validateContextExplanation(out);
  expect(v.ok).toBe(true);
  if (v.ok) {
    expect(v.value.meaning).toContain("鞠躬");
  }
});

test("a transport/timeout throw propagates (caller refunds reservation + budget — no spend)", async () => {
  const provider = new GeminiContextProvider(async () => {
    throw new Error("network timeout");
  });
  await expect(provider.generate(req)).rejects.toThrow("network timeout");
});

test("a malformed model output is returned raw and REJECTED at the gate (never stored)", async () => {
  const provider = new GeminiContextProvider(async () => ({ wrong: "shape" }));
  const v = validateContextExplanation(await provider.generate(req));
  expect(v.ok).toBe(false);
});

// --- prompt framing -----------------------------------------------------------

test("the prompt frames the unit, the text, the language names, and asks for word + sentence", () => {
  const p = buildContextPrompt(req);
  expect(p).toContain('"bow"'); // the unit
  expect(p).toContain("She took a"); // the text rides along (sent off-box — the T8 tradeoff)
  expect(p).toContain("Simplified Chinese"); // explanation-language NAME (never the raw tag)
  expect(p).toContain("the English word or phrase"); // target-language NAME
  expect(p).not.toContain("the en word"); // raw tags never reach the prompt
  expect(p).not.toContain("zh-Hans");
  expect(p).toContain("means as it is used in the text"); // the word's in-context meaning
  expect(p).toContain("what the text is saying as a whole"); // the surrounding text's meaning
  expect(p).toContain('simpler than "bow"'); // the Maimemo rule (never a word harder than the headword)
  expect(p).toContain("anything harder"); // the rule's tail; no v2-era constraint pile-up
  // v4: a bare label/single word must not be padded into a fabricated sentence (the 送信 bug).
  expect(p).toContain("bare label or single word");
  expect(p).toContain("never invent a surrounding sentence");
  // v4: the faithful-retelling rule (don't add obligation/cause, don't swap a rate for a total) +
  // the weaker-reading tie-breaker (don't strengthen a claim when unsure).
  expect(p).toContain("keep its claim exact");
  expect(p).toContain("choose the weaker reading");
});

test("the formulaic lead-ins stay gone (no fixed format)", () => {
  const p = buildContextPrompt(req);
  expect(p).not.toContain("Here, "); // «Here, "X" means …»
  expect(p).not.toContain("The sentence is saying"); // «The sentence is saying …»
  expect(p).not.toContain("begins with");
});

test("context language UNKNOWN (null) → 'the text below', never a defaulted/target label", () => {
  const p = buildContextPrompt({ ...req, contextLanguage: null });
  expect(p).toContain("reading the text below");
  expect(p).toContain('the English word or phrase "bow" in it');
  // The target's name still appears as the UNIT's language — but never as the text's.
  expect(p).not.toContain("the English text below");
});

test("a valid-but-UNNAMED context tag is treated as unknown — raw BCP-47 never reaches the prompt", () => {
  // canonicalizeBcp47 passes any structurally valid tag; only tags with a REAL prompt name may
  // label the text. "en-US" is canonical yet unnamed → same as unknown.
  const p = buildContextPrompt({ ...req, contextLanguage: "en-US" });
  expect(p).toContain("reading the text below");
  expect(p).not.toContain("en-US");
});

test("context language KNOWN → named in the text label (mixed case: zh unit in an English article)", () => {
  const p = buildContextPrompt({
    unit: "学习",
    targetLanguage: "zh-Hans",
    contextText: 'The word 学习 means to study.',
    contextLanguage: "en",
    explanationLanguage: "en",
    spanStart: 9,
    spanEnd: 11,
  });
  expect(p).toContain("the Simplified Chinese word or phrase");
  expect(p).toContain("the English text below");
  expect(p).toContain("[[TARGET]]学习[[/TARGET]]");
});

// --- span marking ---------------------------------------------------------------

test("a valid span marks the asked-about occurrence in the text", () => {
  const p = buildContextPrompt({ ...req, spanStart: 11, spanEnd: 14 });
  expect(p).toContain("She took a [[TARGET]]bow[[/TARGET]] as the audience applauded.");
  expect(p).toContain("the markers are NOT part of the text");
});

test("v4: a marked occurrence is steered explicitly; an unmarked prompt is not", () => {
  // marked (a valid span) → tell the model to explain the marked spot's own sense (repeated-unit bug)
  const marked = buildContextPrompt({ ...req, spanStart: 11, spanEnd: 14 });
  expect(marked).toContain("The marked word is the one to explain");
  // an unmarked repeated unit carries no steering clause (and no marker)
  const unmarked = buildContextPrompt({ ...req, contextText: "He gave a bow, then another bow." });
  expect(unmarked).not.toContain("The marked word is the one to explain");
  expect(unmarked).not.toContain("[[TARGET]]");
});

test("a REPEATED unit with a span marks exactly THAT occurrence", () => {
  const text = "He gave a bow, then another bow.";
  const second = text.lastIndexOf("bow");
  const p = buildContextPrompt({ ...req, contextText: text, spanStart: second, spanEnd: second + 3 });
  expect(p).toContain("a bow, then another [[TARGET]]bow[[/TARGET]].");
});

test("no span + UNIQUE occurrence → still marked (self-healing for span-less saved rows)", () => {
  const p = buildContextPrompt(req);
  expect(p).toContain("[[TARGET]]bow[[/TARGET]]");
});

test("no span + REPEATED unit → unmarked (never guess between occurrences)", () => {
  const text = "He gave a bow, then another bow.";
  const p = buildContextPrompt({ ...req, contextText: text });
  expect(p).not.toContain("[[TARGET]]");
  expect(p).toContain("Text: He gave a bow, then another bow.");
  expect(p).toContain('"bow"'); // the unit is still named — today's pre-span framing
});

test("an INVALID span degrades to the unique-occurrence fallback, not garbage marking", () => {
  // Span points at "audience", not the unit → content check fails → unique "bow" still marks.
  const p = buildContextPrompt({ ...req, spanStart: 22, spanEnd: 30 });
  expect(p).toContain("[[TARGET]]bow[[/TARGET]]");
  expect(p).not.toContain("[[TARGET]]audience[[/TARGET]]");
});

test("resolveMarkedRange: bounds, content match (case-insensitive), and word-bound checks", () => {
  const text = "Bow before the king.";
  // Case-insensitive content match: the client resolver matched "Bow" for unit "bow".
  expect(resolveMarkedRange(text, "bow", 0, 3)).toEqual({ start: 0, end: 3 });
  // Out of bounds / inverted / non-integer → fallback (unique occurrence still resolves).
  expect(resolveMarkedRange(text, "bow", -1, 3)).toEqual({ start: 0, end: 3 });
  expect(resolveMarkedRange(text, "bow", 3, 0)).toEqual({ start: 0, end: 3 });
  expect(resolveMarkedRange(text, "bow", 0, 999)).toEqual({ start: 0, end: 3 });
  // A substring hit inside another word is NEVER marked (unit "art" in "particular").
  expect(resolveMarkedRange("This is particular.", "art", null, null)).toBeNull();
  expect(resolveMarkedRange("This is particular.", "art", 9, 12)).toBeNull();
  // …but it doesn't COMPETE either: the unique word-bounded occurrence still marks even when
  // the unit also appears inside another word ("particular art").
  expect(resolveMarkedRange("particular art", "art", null, null)).toEqual({ start: 11, end: 14 });
  // Word bounds extend past basic Latin: Vietnamese ạ (Latin Extended Additional) glues, so a
  // mid-word hit before it never marks.
  expect(resolveMarkedRange("the cafeạ here", "cafe", null, null)).toBeNull();
  // CJK has no word boundaries — adjacency must not reject a real occurrence.
  expect(resolveMarkedRange("我们今天学习新词。", "学习", null, null)).toEqual({ start: 4, end: 6 });
  // Overlapping repeats are detected as ambiguous (search resumes one past the first START).
  expect(resolveMarkedRange("banana", "ana", null, null)).toBeNull();
  // Absent unit → null.
  expect(resolveMarkedRange(text, "study", null, null)).toBeNull();
});
