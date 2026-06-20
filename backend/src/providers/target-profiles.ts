import { resolveTargetProfile, type TargetGenerationProfile } from "@capecho/lang";

// Per-TARGET model-instruction text packs — the provider-side half of a target profile.
// The language's IDENTITY (tag, prompt name, gating, POS subset, display labels) lives in
// @capecho/lang's TargetGenerationProfile; THIS module holds the words the model reads for
// that target: the per-POS sense policy, the reading-split policy, and the pronunciation
// field rules. Schema `description` strings are model instructions (not docs), so the word
// schema is BUILT per profile (gemini-model.ts) — never a global constant.
//
// Phase 1 (overlay-bilingual-plan.md): the single prose `summary` was replaced by per-POS
// `senses` — the meaning(s) under each part of speech, written in the EXPLANATION language.
// `sensesJob` forks on `bilingual` (PROMPT_VERSION v5): when the gloss language is NOT the word's
// own, give the EQUIVALENT word/expression a bilingual dictionary lists (translate the word, never a
// gloss-language definition); when it matches, give a short plain definition. The fork is decided at
// build time (gemini.ts) so the model gets one unambiguous instruction. The model lists ALL common
// senses per POS (no display cap — every surface shows them all, one line each, scrolling if tall);
// the schema bound is only a generation safety ceiling. THIS pack also carries the load-bearing
// structural rules (frequency order, the idiom branch).

// Generation safety ceiling on the senses array, NOT a display cap: the prompt asks the model to list
// ALL of a word's common meanings per part of speech, and every surface shows them all. This bound only
// stops a runaway hallucinated dump — a real word's common senses never reach it.
const SCHEMA_MAX_SENSES_PER_POS = 12;

export interface TargetPromptProfile {
  /** The lang-registry profile this text pack belongs to (same tag, same gating). */
  lang: TargetGenerationProfile;
  /** A nonsense-keystrokes example for the notAWord branch of the prompt. */
  nonWordExample: string;
  /** FIELD JOBS body for "senses" — how to write the per-POS meanings (prompt prose). `bilingual`
   *  (the gloss language is NOT the word's own) forks translate-the-word vs short-definition; the
   *  caller decides the mode at build time (gemini.ts) so the model gets one unambiguous instruction. */
  sensesJob: (unit: string, explainIn: string, bilingual: boolean) => string;
  /** Trailing template-discipline line for the meanings (prompt prose). */
  sensesTemplateNote: (explainIn: string) => string;
  /** Schema description for each "senses" array (the per-POS meanings). */
  sensesDesc: string;
  /** Schema description for "readings" (the split policy). */
  readingsDesc: string;
  /** Schema description for the per-reading "pos" array (group meanings by part of speech). */
  posDesc: string;
  /** Schema description for "pronunciationPrimary". */
  pronunciationPrimaryDesc: string;
  /** Schema description for "pronunciationSecondary" — null when the target has no second slot
   *  (the schema then omits the field entirely; validation defaults it to ""). */
  pronunciationSecondaryDesc: string | null;
}

const EN: TargetPromptProfile = {
  lang: resolveTargetProfile("en")!,
  nonWordExample: "asdfgh",
  sensesJob: (unit, explainIn, bilingual) =>
    bilingual
      ? `For each distinct meaning of the word, give the ${explainIn} equivalent — the word or short expression a bilingual dictionary lists as the translation, NOT a ${explainIn} definition or description of it. Group by part of speech, most common meaning first; list genuinely distinct meanings as separate senses (a word that is both a tool and an action gets one each), each just the equivalent term(s), never a sentence, never opening with "${unit}". List ALL the common meanings under each part of speech, most common first — do not stop at a fixed number. Cover every part of speech the word is genuinely used in (an entry for "watch" needs both the verb and the wrist thing). Truth first: do not guess; every equivalent must be correct. For a phrase or idiom, set kind="idiom" on the reading and give its established ${explainIn} equivalent. If the word is an inflected form (plural, past tense, -ing, comparative), give the base word's equivalent and note the form. The meanings are read by the learner, who cannot see these instructions: never mention the task.`
      : `Give the word's meanings, grouped by part of speech, as a short plain ${explainIn} definition each. Lead with the most common meaning, most common first — each sense a few words, not a sentence, with NO lead-in formula (never «means», «refers to», «the act of»), never opening with "${unit}" itself. List ALL the common meanings under each part of speech, most common first — do not stop at a fixed number. Cover every part of speech the word is genuinely used in (an entry for "watch" needs both the verb and the wrist thing). Truth first: do not guess; every sense must be factually correct. For a phrase or idiom, set kind="idiom" on the reading and give its established figurative meaning. If the word is an inflected form (plural, past tense, -ing, comparative), give the base word's meaning and note the form. The meanings are read by the learner, who cannot see these instructions: never mention the task.`,
  sensesTemplateNote: (explainIn) =>
    `Any example wording above is only a pattern, not text to copy. Write every sense in ${explainIn}, except the word itself, root words, or older forms may stay in their original language.`,
  sensesDesc:
    `The meaning(s) under this part of speech, in the explanation language. When the explanation language is NOT English, give the equivalent word/expression a bilingual dictionary lists (a translation, NOT a definition); when it IS English, a short plain definition. Most common first; each a few words, no lead-in formula ('means'/'refers to'/'the act of'), never the word itself. List ALL the common meanings, most common first.`,
  readingsDesc:
    "One per distinct pronunciation. Split ONLY when a different pronunciation carries a different meaning or part of speech (a stress-shifted noun/verb pair, or one spelling read two ways); never for a mere accent variant. Most words have exactly one reading.",
  posDesc:
    "One entry per part of speech the word is used in under this pronunciation, most common first; each carries that part of speech's meanings.",
  pronunciationPrimaryDesc:
    "General American IPA, bare — no slashes or brackets. Always give it, even when identical to the British one; empty string ONLY if unsure of this accent, or for a multi-word phrase/idiom.",
  pronunciationSecondaryDesc:
    "British Received Pronunciation IPA, bare — same rules as pronunciationPrimary.",
};

// Enabled target (lang profile enabled=true; paid gate passed). Mirrors the EN structural rules with
// the zh axes swapped in (多音字 as the readings split, Hanyu Pinyin pronunciation).
const ZH_HANS: TargetPromptProfile = {
  lang: resolveTargetProfile("zh-Hans")!,
  nonWordExample: "asdfgh",
  sensesJob: (unit, explainIn, bilingual) =>
    bilingual
      ? `For each distinct meaning of the word, give the ${explainIn} equivalent — the word or short expression a bilingual dictionary lists as the translation, NOT a ${explainIn} definition or description of it. Group by part of speech, most common meaning first; each sense just the equivalent term(s), never a sentence, never opening with "${unit}". For a 多音字 give each reading its meanings (split readings). List ALL the common meanings under each part of speech, most common first — do not stop at a fixed number. Truth first: do not guess; every equivalent must be correct. For a 成语/idiom, set kind="idiom" on the reading and give its established ${explainIn} equivalent. The meanings are read by the learner, who cannot see these instructions: never mention the task.`
      : `Give the word's meanings, grouped by part of speech, as a short plain ${explainIn} definition each. Lead with the most common meaning, most common first — each sense a few words, not a sentence, with NO lead-in formula (never «通常指», «means»), never opening with "${unit}" itself. For a 多音字 give each reading its meanings (split readings). List ALL the common meanings under each part of speech, most common first — do not stop at a fixed number. Truth first: do not guess; every sense must be correct. For a 成语/idiom, set kind="idiom" on the reading and give its established figurative meaning. The meanings are read by the learner, who cannot see these instructions: never mention the task.`,
  sensesTemplateNote: (explainIn) =>
    `Any example wording above is only a pattern, not text to copy. Write every sense in ${explainIn}, except the word itself and its characters may stay in their original script.`,
  sensesDesc:
    `The meaning(s) under this part of speech, in the explanation language. When the explanation language is NOT Chinese, give the equivalent word/expression a bilingual dictionary lists (a translation, NOT a definition); when it IS Chinese, a short plain definition. Most common first; each a few words, no lead-in formula, never the word itself. List ALL the common meanings, most common first.`,
  readingsDesc:
    "One per distinct pronunciation. Split ONLY for a polyphonic word whose different pronunciation changes its meaning or part of speech (多音字, e.g. 行 háng/xíng); most words have exactly one reading.",
  posDesc:
    "One entry per part of speech the word is used in under this pronunciation, most common first; each carries that part of speech's meanings.",
  pronunciationPrimaryDesc:
    "Hanyu Pinyin with tone marks, bare — no brackets. For a multi-character word or idiom, separate each character's syllable with one space (e.g. 朋友 péng you). Empty string ONLY if unsure.",
  pronunciationSecondaryDesc: null,
};

// Enabled target (lang profile enabled=true; paid gate passed). Mirrors the
// EN/ZH structural rules with the ja axes swapped in: the kana reading as the pronunciation, and the
// readings split for a word whose different reading carries a different meaning (辛い からい / つらい).
const JA: TargetPromptProfile = {
  lang: resolveTargetProfile("ja")!,
  nonWordExample: "あすせぬ",
  sensesJob: (unit, explainIn, bilingual) =>
    bilingual
      ? `For each distinct meaning of the word, give the ${explainIn} equivalent — the word or short expression a bilingual dictionary lists as the translation, NOT a ${explainIn} definition or description of it. Group by part of speech, most common meaning first; each sense just the equivalent term(s), never a sentence, never opening with "${unit}". For a word with more than one reading that carries different meanings, give each reading its meanings (split readings). List ALL the common meanings under each part of speech, most common first — do not stop at a fixed number. Truth first: do not guess; every equivalent must be correct. For a 慣用句/idiom or 四字熟語, set kind="idiom" on the reading and give its established ${explainIn} equivalent. The meanings are read by the learner, who cannot see these instructions: never mention the task.`
      : `Give the word's meanings, grouped by part of speech, as a short plain ${explainIn} definition each. Lead with the most common meaning, most common first — each sense a few words, not a sentence, with NO lead-in formula (never «means», «…を指す»), never opening with "${unit}" itself. For a word with more than one reading that carries different meanings, give each reading its meanings (split readings). List ALL the common meanings under each part of speech, most common first — do not stop at a fixed number. Truth first: do not guess; every sense must be correct. For a 慣用句/idiom or 四字熟語, set kind="idiom" on the reading and give its established figurative meaning. The meanings are read by the learner, who cannot see these instructions: never mention the task.`,
  sensesTemplateNote: (explainIn) =>
    `Any example wording above is only a pattern, not text to copy. Write every sense in ${explainIn}, except the word itself and its characters may stay in their original script.`,
  sensesDesc:
    `The meaning(s) under this part of speech, in the explanation language. When the explanation language is NOT Japanese, give the equivalent word/expression a bilingual dictionary lists (a translation, NOT a definition); when it IS Japanese, a short plain definition. Most common first; each a few words, no lead-in formula, never the word itself. List ALL the common meanings, most common first.`,
  readingsDesc:
    "One per distinct pronunciation. Split ONLY when a different reading changes the meaning or part of speech (e.g. 辛い からい 'spicy' / つらい 'painful'; an on'yomi vs kun'yomi that mean different things); a mere euphonic/accent variant is NOT a split. Most words have exactly one reading.",
  posDesc:
    "One entry per part of speech the word is used in under this pronunciation, most common first; each carries that part of speech's meanings.",
  pronunciationPrimaryDesc:
    "The reading in kana — hiragana for native/Sino-Japanese words, katakana for a katakana loanword; bare, no brackets and NO romaji. For a word already written in kana, repeat it as-is. Empty string ONLY if unsure.",
  pronunciationSecondaryDesc: null,
};

const PROFILES: ReadonlyMap<string, TargetPromptProfile> = new Map(
  [EN, ZH_HANS, JA].map((p) => [p.lang.tag, p]),
);

/**
 * The prompt profile for a canonical generation tag (a lang-registry profile tag, i.e. what
 * `generationCacheKey` returned). Throws on an unknown tag — callers MUST pass the allowlist
 * gate first (a programming-error guard, same contract as `wordCacheKey`).
 */
export function requireTargetPromptProfile(tag: string): TargetPromptProfile {
  const p = PROFILES.get(tag);
  if (!p) throw new Error(`no target prompt profile for tag: ${tag}`);
  return p;
}

/** Build the word-generation JSON schema OBJECT for one target profile (pure data — the AI-SDK
 *  `jsonSchema()` wrapping happens in gemini-model.ts, so unit tests stay SDK-free). NO top-level
 *  `required`: the prompt's bare `{"notAWord": true}` exit must be schema-LEGAL under constrained
 *  decoding (with `required` the model was FORCED to fabricate readings on the non-word path).
 *  validate.ts is the gate that hard-requires the primary sense for real words. The schema
 *  `description` strings ARE model instructions — per-profile by construction. */
export function buildWordSchemaObject(profile: TargetPromptProfile): Record<string, unknown> {
  const pronunciationProps: Record<string, unknown> = {
    pronunciationPrimary: { type: "string", description: profile.pronunciationPrimaryDesc },
  };
  const readingRequired = ["pronunciationPrimary", "pos"];
  if (profile.pronunciationSecondaryDesc !== null) {
    pronunciationProps.pronunciationSecondary = {
      type: "string",
      description: profile.pronunciationSecondaryDesc,
    };
    readingRequired.splice(1, 0, "pronunciationSecondary");
  }
  return {
    type: "object",
    additionalProperties: false,
    properties: {
      notAWord: {
        type: "boolean",
        description:
          "true ONLY when the unit is no real word or phrase in the target language; then omit every other field.",
      },
      readings: {
        type: "array",
        minItems: 1,
        maxItems: 6,
        description: profile.readingsDesc,
        items: {
          type: "object",
          additionalProperties: false,
          required: readingRequired,
          properties: {
            ...pronunciationProps,
            kind: {
              type: "string",
              enum: ["idiom"],
              description:
                'Set to "idiom" ONLY for a multi-word phrase or idiom (then the pronunciation may be empty); omit for an ordinary word.',
            },
            pos: {
              type: "array",
              minItems: 1,
              maxItems: 8,
              description: profile.posDesc,
              items: {
                type: "object",
                additionalProperties: false,
                required: ["partOfSpeech", "senses"],
                properties: {
                  partOfSpeech: {
                    type: "string",
                    enum: [...profile.lang.posLabels, "idiom"],
                    description:
                      "The part of speech (short English label whatever the explanation language); 'idiom' for a phrase.",
                  },
                  senses: {
                    type: "array",
                    minItems: 1,
                    maxItems: SCHEMA_MAX_SENSES_PER_POS,
                    items: { type: "string" },
                    description: profile.sensesDesc,
                  },
                },
              },
            },
          },
        },
      },
    },
  };
}
