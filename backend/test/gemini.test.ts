import { test, expect } from "bun:test";
import {
  GeminiExplanationProvider,
  buildExplanationPrompt,
  DEFAULT_GEMINI_MODEL,
  DEFAULT_GEMINI_CONTEXT_MODEL,
} from "../src/providers/gemini.ts";
import { buildWordSchemaObject, requireTargetPromptProfile } from "../src/providers/target-profiles.ts";
import { TARGET_GENERATION_PROFILES, languagePromptName } from "@capecho/lang";
import { validateWordExplanation } from "../src/validate.ts";
import { previewLine, type GenerateRequest } from "../src/provider.ts";

// Tests the provider's CONTRACT with an injected generator — no network, no AI-SDK load (the schema
// builder is a PURE object from target-profiles.ts; the jsonSchema() wrapping lives only in
// gemini-model.ts). The thin SDK glue is verified by `wrangler deploy --dry-run` bundling + the T6 eval.

const req: GenerateRequest = {
  unit: "serendipity",
  normalizedUnit: "serendipity",
  targetLanguage: "en",
  explanationLanguage: "en",
};

test("maps the model's per-POS senses object into a raw payload that passes cache-write validation", async () => {
  const provider = new GeminiExplanationProvider(async () => ({
    readings: [
      {
        pronunciationPrimary: "ˌsɛrənˈdɪpɪti",
        pronunciationSecondary: "ˌsɛrənˈdɪpɪti",
        pos: [{ partOfSpeech: "noun", senses: ["lucky finds made while looking for something else"] }],
      },
    ],
  }));
  const out = await provider.generate(req);
  const v = validateWordExplanation(out);
  expect(v.ok).toBe(true);
  if (v.ok) {
    expect(previewLine(v.value)).toContain("lucky finds");
    expect(v.value.readings[0]!.pos.map((g) => g.partOfSpeech)).toEqual(["noun"]);
    expect(v.value.readings[0]!.pos[0]!.senses[0]).toContain("lucky finds");
  }
});

test("a transport/timeout throw propagates (caller refunds budget — no spend)", async () => {
  const provider = new GeminiExplanationProvider(async () => {
    throw new Error("network timeout");
  });
  await expect(provider.generate(req)).rejects.toThrow("network timeout");
});

test("a malformed model output is returned raw and REJECTED at the gate (never cached)", async () => {
  const provider = new GeminiExplanationProvider(async () => ({ wrong: "shape" }));
  const v = validateWordExplanation(await provider.generate(req));
  expect(v.ok).toBe(false);
});

test("the prompt frames the unit, the target's NAME (never the raw tag), and the explanation-language name", () => {
  const p = buildExplanationPrompt({
    unit: "serendipity",
    normalizedUnit: "serendipity",
    targetLanguage: "en",
    explanationLanguage: "zh-Hans",
  });
  // Stable framing (the founder iterates on prompt WORDING; these are the load-bearing facts a
  // refactor must never drop — the unit, the target language NAME, and the resolved
  // explanation-language name must all reach the model).
  expect(p).toContain("serendipity");
  expect(p).toContain("English"); // target language NAME (profile.promptName)
  expect(p).not.toContain("the en word"); // raw tags never reach the prompt
  expect(p).toContain("Simplified Chinese"); // explanation language name (resolved, not the bcp-47 tag)
  expect(p).toContain("senses"); // the word's explanation field (no prose summary)
  expect(p).toContain("readings"); // the metadata field
  expect(p).toContain("notAWord"); // the non-word exit (L3)
  // Structural invariants: the per-sense gloss layer is GONE (docs/multilingual-explanations.md),
  // and there is no meaning-evolution field of any kind.
  expect(p).not.toContain("gloss");
  expect(p).not.toContain("origin.evolution");
  // Eval-chosen defaults: both layers = 3.1-flash-lite. Words validated on the senses grounded
  // gate; context on the context gate.
  expect(DEFAULT_GEMINI_MODEL).toBe("gemini-3.1-flash-lite");
  expect(DEFAULT_GEMINI_CONTEXT_MODEL).toBe("gemini-3.1-flash-lite");
});

test("the prompt is profile-driven: an unknown target tag is a programming error (gate first)", () => {
  expect(() =>
    buildExplanationPrompt({ ...req, targetLanguage: "es" }),
  ).toThrow(/no target prompt profile/);
});

test("the voice branches on gloss-vs-target: translate when they differ, define when they match (v4)", () => {
  // Bilingual (gloss ≠ target): the translation voice, and the definitional voice is SUPPRESSED — the
  // root cause of "word"→"语言的最小单位…" was the definitional voice overpowering a conditional line.
  const bi = buildExplanationPrompt({
    unit: "word",
    normalizedUnit: "word",
    targetLanguage: "en",
    explanationLanguage: "zh-Hans",
  });
  expect(bi).toContain("TRANSLATING");
  expect(bi).toContain("equivalent"); // the senses job asks for the equivalent term, not a definition
  expect(bi).not.toContain("Explain the thing, not the term");
  // Monolingual (gloss == target): the definitional tutor voice, and NO translate framing.
  const mono = buildExplanationPrompt({
    unit: "word",
    normalizedUnit: "word",
    targetLanguage: "en",
    explanationLanguage: "en",
  });
  expect(mono).toContain("Explain the thing, not the term");
  expect(mono).not.toContain("TRANSLATING");
  // en-GB is still English → monolingual (primary-subtag compare, not exact tag).
  const enGb = buildExplanationPrompt({
    unit: "word",
    normalizedUnit: "word",
    targetLanguage: "en",
    explanationLanguage: "en-GB",
  });
  expect(enGb).not.toContain("TRANSLATING");
});

test("the zh-Hans prompt carries the eval-locked invariants (Phase D1 voice regression)", () => {
  const p = buildExplanationPrompt({
    unit: "银行",
    normalizedUnit: "银行",
    targetLanguage: "zh-Hans",
    explanationLanguage: "en",
  });
  // Load-bearing facts of the D1 voice (wording may iterate; these must survive a refactor):
  expect(p).toContain("银行"); // the unit reaches the model
  expect(p).toContain("Chinese"); // target language NAME, never the raw tag
  expect(p).not.toContain("the zh-Hans word");
  expect(p).toContain("多音字"); // the readings-binding rule names the zh split
  expect(p).toContain("split readings"); // each 多音字 reading carries its own senses (coverage rule)
  expect(p).toContain("do not guess"); // truth-first invariant
  expect(p).not.toContain("Follow this shape"); // the old template scaffold is gone
  expect(p).not.toContain("General American"); // no en pronunciation rules leak into the zh pack
});

test('the word schema is per-profile, has NO top-level required (the bare {"notAWord":true} exit is schema-legal), and enums the POS subset', () => {
  const en = requireTargetPromptProfile("en");
  const schema = buildWordSchemaObject(en);
  expect(schema.required).toBeUndefined(); // the notAWord bare exit must be legal
  const props = schema.properties as Record<string, Record<string, unknown>>;
  expect(props.notAWord).toBeDefined();
  expect(props.summary).toBeUndefined(); // no prose summary — the meaning lives in pos[].senses
  const items = (props.readings as { items: Record<string, unknown> }).items as Record<string, unknown>;
  const itemProps = items.properties as Record<string, Record<string, unknown>>;
  expect(itemProps.pronunciationSecondary).toBeDefined(); // en has the UK slot
  // The per-POS senses group: the POS label enums the closed set (+ "idiom"), and each group carries
  // its meanings under `senses` (described by the profile's sensesDesc).
  const enPos = itemProps.pos as { items: Record<string, unknown> };
  const enPosItems = enPos.items as { required: string[]; properties: Record<string, Record<string, unknown>> };
  expect(enPosItems.required).toEqual(["partOfSpeech", "senses"]);
  expect((enPosItems.properties.partOfSpeech!.enum as string[])).toEqual([...en.lang.posLabels, "idiom"]);
  expect(enPosItems.properties.senses!.description).toBe(en.sensesDesc);

  // zh-Hans (defined-but-disabled profile): pinyin only — NO secondary slot in its schema.
  const zh = requireTargetPromptProfile("zh-Hans");
  const zhSchema = buildWordSchemaObject(zh);
  const zhItems = ((zhSchema.properties as Record<string, { items?: Record<string, unknown> }>).readings!
    .items) as Record<string, unknown>;
  const zhProps = zhItems.properties as Record<string, unknown>;
  expect(zhProps.pronunciationSecondary).toBeUndefined();
  // The syllable-spacing instruction with its exemplar (朋友 péng you) — which must stay OUT of the
  // eval corpus (an exemplar in the schema desc would hand the model the gold answer for that row).
  expect((zhProps.pronunciationPrimary as Record<string, unknown>).description).toContain("péng you");
  expect(zhItems.required).toEqual(["pronunciationPrimary", "pos"]);
});

test('the model\'s {"notAWord": true} verdict validates as reason "not_a_word" (a non-word, not a failure)', async () => {
  const provider = new GeminiExplanationProvider(async () => ({ notAWord: true }));
  const v = validateWordExplanation(await provider.generate({ ...req, unit: "asdfgh", normalizedUnit: "asdfgh" }));
  expect(v.ok).toBe(false);
  if (!v.ok) expect(v.reason).toBe("not_a_word");
});

test("a sense is the must-pass core: a pronunciation/POS-only payload (no sense) is rejected, never cached", async () => {
  const provider = new GeminiExplanationProvider(async () => ({
    readings: [{ pronunciationPrimary: "ˈprɑdʒɛkt", pronunciationSecondary: "ˈprɒdʒɛkt", pos: [{ partOfSpeech: "noun", senses: [] }] }],
  }));
  const v = validateWordExplanation(await provider.generate({ ...req, unit: "project", normalizedUnit: "project" }));
  expect(v.ok).toBe(false);
  if (!v.ok) expect(v.reason).toBe("missing_sense");
});

test("every lang-registry profile has a provider prompt pack that agrees with it (Phase-D template guard)", () => {
  // The lang registry (shared/lang) and the provider's prompt packs (target-profiles.ts) are two
  // halves of one profile. Enabling a future language in only one of them would be a SILENT
  // whole-language outage (every request throws inside the provider -> provider_error, refunded but
  // dead). This forces the Phase-D template to land both halves together.
  for (const lang of TARGET_GENERATION_PROFILES) {
    const pack = requireTargetPromptProfile(lang.tag); // throws if the pack is missing
    expect(pack.lang.tag).toBe(lang.tag);
    // The two registries must agree on whether the language uses a second pronunciation slot —
    // disagreement would desync the schema slots from the client display table.
    expect(lang.hasSecondaryPronunciation).toBe(pack.pronunciationSecondaryDesc !== null);
    // Every profile tag must have a REAL prompt name (the raw-tag fallback in prompts is for the
    // unallowlisted context layer only, never for a generation target).
    expect(languagePromptName(lang.tag)).not.toBe(lang.tag);
    expect(lang.promptName).toBe(languagePromptName(lang.tag));
  }
});
