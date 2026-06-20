import { test, expect } from "bun:test";
import { validateWordExplanation } from "../src/validate.ts";

// The senses blob: { readings[{ pronunciationPrimary, pronunciationSecondary, kind,
// pos[{ partOfSpeech, senses[] }] }] }. The MUST-PASS core is the captured unit's primary
// sense; pronunciation + extra senses are omit-on-fail. Fields are loosely typed so the malformed
// tests can pass garbage (the validator's input is `unknown` anyway).
const pos = (partOfSpeech: string, senses: unknown) => ({ partOfSpeech, senses });
const reading = (primary: string, secondary: string, posGroups: unknown, kind?: string) => ({
  pronunciationPrimary: primary,
  pronunciationSecondary: secondary,
  ...(kind !== undefined ? { kind } : {}),
  pos: posGroups,
});

test("accepts a well-formed senses blob and trims senses + pronunciation", () => {
  const out = validateWordExplanation({
    raw: { readings: [reading("rʌn", "rʌn", [pos("verb", ["  to move quickly  "]), pos("noun", ["an act of running"])])] },
  });
  expect(out.ok).toBe(true);
  if (out.ok) {
    expect(out.value.readings).toHaveLength(1);
    const r = out.value.readings[0]!;
    expect(r.pronunciationPrimary).toBe("rʌn");
    expect(r.kind).toBeNull();
    expect(r.pos[0]!.partOfSpeech).toBe("verb");
    expect(r.pos[0]!.senses).toEqual(["to move quickly"]); // trimmed
    expect(out.pronunciationState).toBe("present");
  }
});

test("a heteronym groups senses under their own reading", () => {
  const out = validateWordExplanation({
    raw: {
      readings: [
        reading("ˈrɛkɚd", "ˈrɛkɔːd", [pos("noun", ["a stored account of facts", "a music disc"])]),
        reading("rɪˈkɔːrd", "rɪˈkɔːd", [pos("verb", ["to store sound for later"])]),
      ],
    },
  });
  expect(out.ok).toBe(true);
  if (out.ok) {
    expect(out.value.readings).toHaveLength(2);
    expect(out.value.readings[0]!.pos[0]!.partOfSpeech).toBe("noun");
    expect(out.value.readings[1]!.pos[0]!.partOfSpeech).toBe("verb");
  }
});

test("an idiom keeps kind='idiom' with empty pronunciation", () => {
  const out = validateWordExplanation({
    raw: { readings: [reading("", "", [pos("idiom", ["打破僵局"])], "idiom")] },
  });
  expect(out.ok).toBe(true);
  if (out.ok) {
    const r = out.value.readings[0]!;
    expect(r.kind).toBe("idiom");
    expect(r.pos[0]!.partOfSpeech).toBe("idiom");
    expect(out.pronunciationState).toBe("absent"); // none offered
  }
});

test("keeps every sense a real word provides (no per-POS display cap, no validate trim)", () => {
  const many = Array.from({ length: 15 }, (_, i) => `s${i + 1}`);
  const out = validateWordExplanation({
    raw: { readings: [reading("rʌn", "rʌn", [pos("verb", many)])] },
  });
  expect(out.ok).toBe(true);
  if (out.ok) {
    // validate never trims — every common sense is always shown (the generation ceiling is the schema's
    // maxItems, enforced at generation, not here); the surfaces scroll if tall.
    expect(out.value.readings[0]!.pos[0]!.senses).toEqual(many);
  }
});

test("dedupes senses within a POS group", () => {
  const out = validateWordExplanation({
    raw: { readings: [reading("rʌn", "rʌn", [pos("verb", ["dup", "dup", "other"])])] },
  });
  expect(out.ok).toBe(true);
  if (out.ok) expect(out.value.readings[0]!.pos[0]!.senses).toEqual(["dup", "other"]);
});

test("drops an unknown POS label but keeps a valid sibling group", () => {
  const out = validateWordExplanation({
    raw: { readings: [reading("rʌn", "rʌn", [pos("frobnicate", ["nope"]), pos("verb", ["yes"])])] },
  });
  expect(out.ok).toBe(true);
  if (out.ok) {
    expect(out.value.readings[0]!.pos).toHaveLength(1);
    expect(out.value.readings[0]!.pos[0]!.partOfSpeech).toBe("verb");
  }
});

test("pronunciation is omit-on-fail: a blank slot blanks without rejecting the blob", () => {
  const out = validateWordExplanation({
    raw: { readings: [reading("", "", [pos("noun", ["a thing"])])] },
  });
  expect(out.ok).toBe(true);
  if (out.ok) {
    expect(out.value.readings[0]!.pronunciationPrimary).toBe("");
    expect(out.pronunciationState).toBe("absent");
  }
});

test("reports pronunciationState='dropped' when an offered pronunciation fails the gate", () => {
  const longPron = "x".repeat(200); // > MAX_PRONUNCIATION_LEN
  const out = validateWordExplanation({
    raw: { readings: [reading(longPron, "", [pos("noun", ["a thing"])])] },
  });
  expect(out.ok).toBe(true);
  if (out.ok) expect(out.pronunciationState).toBe("dropped");
});

// --- reject: must never be cached ----------------------------------------------
test("rejects when no sense survives anywhere (missing_sense)", () => {
  const out = validateWordExplanation({ raw: { readings: [reading("rʌn", "rʌn", [pos("verb", [])])] } });
  expect(out).toEqual({ ok: false, reason: "missing_sense" });
});

test("rejects an all-blank-senses blob (missing_sense)", () => {
  const out = validateWordExplanation({ raw: { readings: [reading("rʌn", "rʌn", [pos("verb", ["   ", ""])])] } });
  expect(out).toEqual({ ok: false, reason: "missing_sense" });
});

test("rejects an empty / refusal / not-a-word output", () => {
  expect(validateWordExplanation({ raw: null })).toEqual({ ok: false, reason: "empty" });
  expect(validateWordExplanation({ raw: undefined })).toEqual({ ok: false, reason: "empty" });
  expect(validateWordExplanation({ raw: "I'm sorry, but I can't help with that." })).toEqual({ ok: false, reason: "refusal" });
  expect(validateWordExplanation({ raw: { notAWord: true } })).toEqual({ ok: false, reason: "not_a_word" });
  // even fabricated readings alongside the verdict don't rescue it
  expect(validateWordExplanation({ raw: { notAWord: true, readings: [reading("rʌn", "rʌn", [pos("verb", ["x"])])] } })).toEqual({ ok: false, reason: "not_a_word" });
});

test("drops a sense that leaks a refusal, rejecting if it was the only one", () => {
  const out = validateWordExplanation({ raw: { readings: [reading("rʌn", "rʌn", [pos("verb", ["As an AI I cannot define this."])])] } });
  expect(out).toEqual({ ok: false, reason: "missing_sense" });
});

test("rejects malformed shapes", () => {
  expect(validateWordExplanation({ raw: "plain string" })).toEqual({ ok: false, reason: "malformed" });
  expect(validateWordExplanation({ raw: { readings: "noun: a thing" } })).toEqual({ ok: false, reason: "malformed" });
  expect(validateWordExplanation({ raw: { readings: ["rʌn"] } })).toEqual({ ok: false, reason: "malformed" });
  expect(validateWordExplanation({ raw: { readings: [reading("rʌn", "rʌn", "noun: a thing")] } })).toEqual({ ok: false, reason: "malformed" });
  expect(validateWordExplanation({ raw: { readings: [reading("rʌn", "rʌn", [pos("noun", "a thing")])] } })).toEqual({ ok: false, reason: "malformed" });
});

test("rejects an oversized readings dump", () => {
  const many = Array.from({ length: 7 }, () => reading("rʌn", "rʌn", [pos("noun", ["x"])]));
  expect(validateWordExplanation({ raw: { readings: many } })).toEqual({ ok: false, reason: "oversized" });
});
