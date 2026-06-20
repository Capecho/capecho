import { test, expect } from "bun:test";
import { wordCacheKey, PROMPT_VERSION, DICT_SOURCE_VERSION } from "../src/cache-key.ts";
import { DEDUP_VERSION } from "../src/dedup-key.ts";

test("PROMPT_VERSION is the deliberate literal — a bad-merge revert would silently re-serve stale-shape blobs", () => {
  // v5 = list ALL common senses per POS (was capped at 4). A revert re-keys onto v4's ≤4-sense blobs.
  // Bump this pin only together with a deliberate prompt change.
  expect(PROMPT_VERSION).toBe("v5");
});

test("key bakes in layer, collapsed target, gloss lang, prompt + dict-source + normalization versions", () => {
  const k = wordCacheKey({
    normalizedUnit: "run",
    targetLanguage: "en",
    explanationLanguage: "zh-Hans",
  });
  expect(k).toBe(
    `explain/word/en/zh-Hans/${PROMPT_VERSION}/${DICT_SOURCE_VERSION}/${DEDUP_VERSION}/run`,
  );
});

test("dict_source_version is a distinct key axis (spec §13) — changing it is a new blob", () => {
  // The version segment sits between prompt_version and dedup_version,
  // so a grounding-set bump never collides with the prompt or dedup axes.
  const k = wordCacheKey({ normalizedUnit: "run", targetLanguage: "en", explanationLanguage: "en" });
  expect(k.split("/")).toContain(DICT_SOURCE_VERSION);
  expect(k).toBe(`explain/word/en/en/${PROMPT_VERSION}/${DICT_SOURCE_VERSION}/${DEDUP_VERSION}/run`);
});

test("target collapses (en, en-US, en-GB -> en) so the shared keyspace stays bounded", () => {
  const base = { normalizedUnit: "run", explanationLanguage: "en" };
  const a = wordCacheKey({ ...base, targetLanguage: "en" });
  const b = wordCacheKey({ ...base, targetLanguage: "en-US" });
  const c = wordCacheKey({ ...base, targetLanguage: "en-GB" });
  expect(a).toBe(b);
  expect(b).toBe(c);
});

test("explanation language is part of the key (same word, different gloss = different blob)", () => {
  const base = { normalizedUnit: "run", targetLanguage: "en" };
  expect(wordCacheKey({ ...base, explanationLanguage: "en" })).not.toBe(
    wordCacheKey({ ...base, explanationLanguage: "es" }),
  );
});

test("unit is percent-encoded so phrases / unicode produce safe path keys", () => {
  const k = wordCacheKey({
    normalizedUnit: "out of the blue",
    targetLanguage: "en",
    explanationLanguage: "en",
  });
  expect(k.endsWith("/out%20of%20the%20blue")).toBe(true);
});

test("throws for a non-generation-allowed target (caller must gate first)", () => {
  expect(() =>
    wordCacheKey({ normalizedUnit: "casa", targetLanguage: "es", explanationLanguage: "en" }),
  ).toThrow(/non-generation-allowed/);
});

test("throws for an empty normalized unit", () => {
  expect(() =>
    wordCacheKey({ normalizedUnit: "", targetLanguage: "en", explanationLanguage: "en" }),
  ).toThrow(/non-empty/);
});
