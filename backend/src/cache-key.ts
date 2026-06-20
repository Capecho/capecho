import { generationCacheKey } from "@capecho/lang";
import { DEDUP_VERSION } from "./dedup-key.ts";

// Prompt version: bump on ANY prompt change so a regenerated explanation lands on a NEW
// durable key instead of silently serving a stale cached blob (gated by T6; a bump pends a
// paid reference-grounded E3 re-run before deploy — and rekeys the whole word cache).
// The blob is `{ readings[] }` — `readings[{ pronunciationPrimary, pronunciationSecondary,
// kind, pos[{ partOfSpeech, senses[] }] }]`. The MUST-PASS core is the captured unit's
// PRIMARY sense (readings[0].pos[0].senses[0]); pronunciation + extra senses are omit-on-fail.
// The `senses` are written in the EXPLANATION language — a translation when it differs from the
// word's own language, a short definition when it matches. Every field-local STRUCTURAL rule
// lives in the per-target schema descriptions (one home per rule; gemini-model.ts buildWordSchema);
// an optional `notAWord` exit lets the model decline a word-shaped non-word (L3).
//
// v2 — the multilingual word-contract reset (Phase A): senses[] deleted, summary must-pass.
// v3 — the bilingual per-POS reset (overlay-bilingual-plan.md, Phase 1): prose `summary` REPLACED
//   by per-POS `senses` (≤4 + hasMore), per-reading `kind` for idioms, native-language gloss drives
//   translate-vs-define. ⚠ DEPLOY-GATED: a paid E3 holdout re-run (define en→en + translate
//   en→zh-Hans) must pass before this ships, and the bump rekeys + regenerates the whole word cache.
//   Eval harness migration (eval/) + the paid run = T4.
// v4 — translate-don't-define for the bilingual case: when the gloss language ≠ the target language
//   the prompt now BRANCHES AT BUILD TIME to a translation voice (give the equivalent word/expression
//   a bilingual dictionary lists, NEVER a gloss-language definition) — the definitional VOICE was
//   overpowering the conditional "translate" line (e.g. "word"→"语言的最小单位…" instead of "词;单词").
//   Monolingual (gloss == target) still defines. Also tightens hasMore (only when genuinely more
//   common meanings remain). ⚠ Same deploy gate as v3 (paid E3 re-run; rekeys the whole word cache).
// v5 — list ALL common senses (no per-POS cap): the model lists every common meaning under each part
//   of speech (was "up to 4"); the schema bound (12) is only a generation safety ceiling. Every surface
//   shows them all, one line per POS, scrolling if tall. The `hasMore` self-report + the "more senses ·
//   open Dictionary" hint were REMOVED in-place (no key bump): the hint only ever rendered because the
//   CLIENT read `hasMore`, so dropping it from the contract retires the hint for cached AND fresh words
//   without a deploy; the backend cleanup (stop emitting `hasMore`) is quality-neutral — the
//   senses-listing instruction is unchanged, so old v5 blobs (which still carry an ignored `hasMore`
//   key) stay valid and no regeneration / paid re-run is owed. The v5 SENSES contract's paid E3 re-run
//   passed; it is the live deployed contract (rekeyed from v4).
export const PROMPT_VERSION = "v5";

// Grounding-source-set version (spec §13). Distinct axis from PROMPT_VERSION: this
// bumps when the AUTHORITATIVE grounding-source set the generation is constrained to
// changes (§9). Kept separate so a grounding-set change is a clean cache migration
// without conflating it with a prompt change. (Mock generation has no real grounding
// source yet; the constant pins the durable key shape now so a future change is a
// value bump, never a key-shape break.)
export const DICT_SOURCE_VERSION = "v1";

// The free WORD layer is the only SHARED-cached layer. The context ("explain in this
// sentence") layer is private + encrypted per-record and is NEVER written to this
// shared cache, so "word" is the only layer constant here.
export const WORD_LAYER = "word" as const;

export interface WordCacheKeyInput {
  /** server dedup key (from ./dedup-key — deterministic, no lemmatization) */
  normalizedUnit: string;
  /** canonical, generation-ALLOWED BCP-47 target — gate before calling */
  targetLanguage: string;
  /** resolved gloss language (a member of the explanation-language set) */
  explanationLanguage: string;
}

/**
 * Durable shared-cache key for the free word-level explanation. Bounds the keyspace
 * + AI spend: the target collapses via `generationCacheKey`
 * ("en-US"->"en"), and the prompt + normalization versions are baked in so any rule
 * change is a NEW key (never a silent stale serve). Throws if the target isn't
 * generation-allowed — callers MUST pass the allowlist gate first (a programming-
 * error guard, not the gate itself).
 */
export function wordCacheKey(input: WordCacheKeyInput): string {
  const target = generationCacheKey(input.targetLanguage);
  if (target === null) {
    throw new Error(
      `wordCacheKey called for a non-generation-allowed target: ${input.targetLanguage}`,
    );
  }
  if (input.normalizedUnit.length === 0) {
    throw new Error("wordCacheKey requires a non-empty normalized unit");
  }
  // Path-shaped, percent-encoded unit. The headword is public dictionary data, not
  // sensitive context — T8 log-hygiene applies to CONTEXT text, never the unit.
  // Segment order mirrors the spec §13 key tuple:
  // (layer, target, explanation_language, prompt_version, dict_source_version,
  //  dedup_version, unit) — every version axis baked in so any rule
  // change is a NEW key (a cache migration), never a silent stale serve.
  return [
    "explain",
    WORD_LAYER,
    target,
    input.explanationLanguage,
    PROMPT_VERSION,
    DICT_SOURCE_VERSION,
    DEDUP_VERSION,
    encodeURIComponent(input.normalizedUnit),
  ].join("/");
}
