import { test, expect } from "bun:test";
import { validateContextExplanation } from "../src/validate-context.ts";
import { CONTEXT_PROMPT_VERSION } from "../src/context-provider.ts";

test("a well-formed single-field gloss validates and carries the context prompt version", () => {
  const r = validateContextExplanation({
    raw: { meaning: "  Here it means to move smoothly; the boat moved smoothly over the water.  " },
  });
  expect(r.ok).toBe(true);
  if (r.ok) {
    expect(r.value.meaning).toBe("Here it means to move smoothly; the boat moved smoothly over the water."); // trimmed
    expect(r.value.promptVersion).toBe(CONTEXT_PROMPT_VERSION);
  }
});

test("null / missing output is empty", () => {
  expect(validateContextExplanation({ raw: null })).toEqual({ ok: false, reason: "empty" });
});

test("a missing / wrong-typed field is malformed", () => {
  expect(validateContextExplanation({ raw: { notMeaning: "x" } })).toEqual({ ok: false, reason: "malformed" });
  expect(validateContextExplanation({ raw: { meaning: 42 } })).toEqual({ ok: false, reason: "malformed" });
  expect(validateContextExplanation({ raw: 42 })).toEqual({ ok: false, reason: "malformed" });
});

test("a blank field is empty", () => {
  expect(validateContextExplanation({ raw: { meaning: "   " } })).toEqual({ ok: false, reason: "empty" });
});

test("a refusal is caught (string, or the field)", () => {
  expect(
    validateContextExplanation({ raw: { meaning: "I'm sorry, but I can't help with that." } }),
  ).toEqual({ ok: false, reason: "refusal" });
  expect(validateContextExplanation({ raw: "As an AI, I cannot..." })).toEqual({ ok: false, reason: "refusal" });
});

test("an oversized field is rejected (hallucinated dump, not an answer)", () => {
  // meaning bounds at 2400.
  expect(validateContextExplanation({ raw: { meaning: "x".repeat(2401) } })).toEqual({
    ok: false,
    reason: "oversized",
  });
});
