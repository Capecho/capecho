import { test, expect } from "bun:test";
import golden from "../fixtures/golden.json" with { type: "json" };
import {
  canonicalizeBcp47,
  isGenerationAllowed,
  generationCacheKey,
  isSupportedExplanationLanguage,
  isValidTargetLanguage,
  effectiveExplanationLanguage,
  resolveTargetProfile,
  TARGET_GENERATION_PROFILES,
  POS_LABEL_SET,
  EXPLANATION_LANGUAGES,
  languagePromptName,
} from "../src/index.ts";

for (const c of golden.canonicalize) {
  test(`canonicalize ${JSON.stringify(c.in)} -> ${JSON.stringify(c.expected)}`, () => {
    expect(canonicalizeBcp47(c.in)).toBe(c.expected);
    expect(isValidTargetLanguage(c.in)).toBe(c.expected !== null);
  });
}

for (const c of golden.generationAllowed) {
  test(`generationAllowed ${JSON.stringify(c.in)} -> ${c.expected}`, () => {
    expect(isGenerationAllowed(c.in)).toBe(c.expected);
  });
}

for (const c of golden.generationCacheKey) {
  test(`generationCacheKey ${JSON.stringify(c.in)} -> ${JSON.stringify(c.expected)}`, () => {
    expect(generationCacheKey(c.in)).toBe(c.expected);
  });
}

for (const c of golden.explanationLanguage) {
  test(`explanationLanguage ${JSON.stringify(c.in)} -> ${c.expected}`, () => {
    expect(isSupportedExplanationLanguage(c.in)).toBe(c.expected);
  });
}

// canonicalization is idempotent — re-canonicalizing a canonical tag is a no-op
// (server re-validation on sync must not drift the tag).
test("canonicalization is idempotent", () => {
  for (const c of golden.canonicalize) {
    const once = canonicalizeBcp47(c.in);
    if (once !== null) expect(canonicalizeBcp47(once)).toBe(once);
  }
});

// effective gloss language: follows the learning language (immersion) unless an explicit pick is set.
test("effectiveExplanationLanguage follows learning, else uses the explicit pick", () => {
  // follows=true → resolve the learning language to a gloss language…
  expect(effectiveExplanationLanguage(true, "en", "de")).toBe("de");
  expect(effectiveExplanationLanguage(true, "en", "de-AT")).toBe("de"); // region tag resolves
  expect(effectiveExplanationLanguage(true, "zh-Hans", "ja")).toBe("ja");
  // …falling back to "en" when learning is unset or isn't a supported gloss language.
  expect(effectiveExplanationLanguage(true, "zh-Hans", null)).toBe("en");
  expect(effectiveExplanationLanguage(true, "zh-Hans", "ru")).toBe("en"); // ru not a gloss language
  expect(effectiveExplanationLanguage(true, "zh-Hans", "zh-Hant")).toBe("en"); // Traditional unsupported
  // follows=false → the explicit explanation language wins, regardless of learning.
  expect(effectiveExplanationLanguage(false, "zh-Hans", "de")).toBe("zh-Hans");
  expect(effectiveExplanationLanguage(false, "en", "de")).toBe("en");
});

// the non-negotiable security property: generation is gated to the allowlist,
// never trusting an arbitrary client string.
test("only the gate-passed targets generate (en + zh-Hans + ja); everything else is refused", () => {
  expect(isGenerationAllowed("en")).toBe(true);
  expect(isGenerationAllowed("zh-Hans")).toBe(true);
  expect(isGenerationAllowed("ja")).toBe(true);
  for (const tag of ["zh-Hant", "es", "de", "fr", "ko", "x-evil", ""]) {
    expect(isGenerationAllowed(tag)).toBe(false);
  }
});

// Profile RESOLUTION is independent of gating — a defined-but-disabled profile
// resolves (so keying/lookup is locked now) but never generates.
for (const c of golden.targetProfile) {
  test(`targetProfile ${JSON.stringify(c.in)} -> ${JSON.stringify(c.expected)}`, () => {
    expect(resolveTargetProfile(c.in)?.tag ?? null).toBe(c.expected);
  });
}

test("zh-CN resolves to the zh-Hans profile, now ENABLED by the D5 gate", () => {
  const p = resolveTargetProfile("zh-CN");
  expect(p?.tag).toBe("zh-Hans");
  expect(p?.enabled).toBe(true);
  expect(generationCacheKey("zh-CN")).toBe("zh-Hans");
});

// Every profile's POS subset stays inside the closed union set — the validation
// contract (unknown labels are dropped server-side) depends on it.
test("profile POS labels are subsets of POS_LABELS", () => {
  for (const p of TARGET_GENERATION_PROFILES) {
    expect(p.posLabels.length).toBeGreaterThan(0);
    for (const label of p.posLabels) expect(POS_LABEL_SET.has(label)).toBe(true);
  }
});

// The cache-key tag IS the profile tag — and the script axis must never collapse:
// zh-Hans and zh-Hant can never share a key, enabled or not.
test("script axis never collapses (zh-Hans vs zh-Hant)", () => {
  expect(resolveTargetProfile("zh-Hant")).toBe(null);
  expect(resolveTargetProfile("zh-TW")).toBe(null);
  expect(resolveTargetProfile("zh-Hans")?.tag).toBe("zh-Hans");
});

test("every explanation language and target profile has a REAL prompt name (no raw-tag fallthrough)", () => {
  // languagePromptName falls back to the raw tag by design (the context layer serves any target) —
  // but for the FINITE sets we ship, a missing name means a prompt that reads "explain in zh-Hans"
  // and risks wrong-language output cached against the right key. Adding a gloss language or a
  // generation profile without naming it must fail here, not in production prompts.
  for (const tag of EXPLANATION_LANGUAGES) {
    expect(languagePromptName(tag)).not.toBe(tag);
  }
  for (const profile of TARGET_GENERATION_PROFILES) {
    expect(languagePromptName(profile.tag)).not.toBe(profile.tag);
  }
});
