import { languagePromptName } from "@capecho/lang";
import type { ExplanationProvider, GenerateRequest, GenerateResult } from "../provider.ts";
import { requireTargetPromptProfile } from "./target-profiles.ts";

// Word-level explanation provider, model-agnostic core (NO AI-SDK import here, so the unit tests +
// `bun test` never load the heavy SDK). The real Gemini wiring lives in `gemini-model.ts`.
//
// Contract: the model-call step is injected as a `WordGenerator`. On a transport/timeout error it
// THROWS, which the caller treats as no-spend (the reserved global budget is refunded). A
// returned-but-malformed result still counts as spend and is rejected at the cache-write gate
// (validate.ts) — it is never trusted here.

// Both layers default to gemini-3.1-flash-lite (eval-chosen):
//   • words — v4 senses contract, grounded gate 2026-06-17: 3.1-flash-lite PASSES both axes
//     (en→en pron 92.3 / correct 96.2; en→zh-Hans pron 96.2 / correct 96.2), matching 2.5-flash
//     (100 / 96.2) while being faster + cheaper. 2.5-flash-lite FAILS (en→zh pron 60 / correct 68).
//     The earlier "2.5-flash beats lite 80.8/70" verdict was the PROSE-`summary` contract (≤v2);
//     per-POS senses/translations are an easier task for lite, so that choice no longer holds.
//   • context — 2026-06-11: 3.1-flash-lite PASSES the context gate (91.7/91.7/91.7) where 2.5-flash
//     FAILS voice (66.7% — reverts to "X means to…" templates); cheap for the uncacheable layer.
// GEMINI_MODEL / GEMINI_CONTEXT_MODEL (Worker vars) still override per environment.
export const DEFAULT_GEMINI_MODEL = "gemini-3.1-flash-lite";
export const DEFAULT_GEMINI_CONTEXT_MODEL = "gemini-3.1-flash-lite";

/** Human-readable language name for prompts (lang-package data; raw-tag fallback). Kept under the
 *  historical export name — gemini-context.ts and tests import it from here. */
export function explanationLanguageName(lang: string): string {
  return languagePromptName(lang);
}

/** Build the generation prompt for one unit. Exported so a refactor can't silently drop the
 *  unit / target / explanation-language framing (regression-tested).
 *
 *  Reading-centric metadata: the model organizes pronunciation BY READING — a heteronym groups its
 *  parts of speech under the reading they belong to; pronunciation is OMIT-ON-FAIL per reading. The
 *  meaning is the per-POS `senses` (must-pass: the captured unit's primary sense). There is no prose
 *  summary (Phase 1).
 *
 *  Translate vs define is decided HERE, at build time, from whether the gloss language is the
 *  target's own language — a bilingual gloss gets a TRANSLATION voice (the equivalent word a
 *  bilingual dictionary lists), a monolingual gloss gets the "tutor voice" plain-definition. The
 *  branch is build-time, not a conditional sentence, because the definitional voice otherwise
 *  overpowers a "translate" instruction (e.g. glossing "word" as "语言的最小单位…" instead of "词;单词"). */
export function buildExplanationPrompt(req: GenerateRequest): string {
  const profile = requireTargetPromptProfile(req.targetLanguage);
  const targetName = profile.lang.promptName;
  const explainIn = explanationLanguageName(req.explanationLanguage);
  // Bilingual = the gloss language is NOT the word's own language (compare primary subtags, so
  // en≡en-GB and zh-Hans≡zh). Decides the VOICE + the senses job below.
  const primaryTag = (tag: string) => tag.split("-")[0]!.toLowerCase();
  const bilingual = primaryTag(req.explanationLanguage) !== primaryTag(req.targetLanguage);

  // Persona + the notAWord branch are shared; the VOICE then forks (translate vs define). Every
  // field-local STRUCTURAL rule (counts, pronunciation format, POS labels) lives ONLY in the
  // per-profile schema descriptions (gemini-model.ts), which the model also reads. The in-prompt
  // exemplar word is deliberately disjoint from the E3 eval corpora (must not seed scored units).
  const head = `A learner you tutor points at the ${targetName} word or short phrase "${req.unit}" and asks what it is. Write the meanings in ${explainIn} (the pronunciation stays IPA/pinyin; the part-of-speech label stays a short English word).

NOT A WORD: First, is "${req.unit}" a real ${targetName} word or phrase? If not (a meaningless run of keystrokes, "${profile.nonWordExample}"), invent nothing: return EXACTLY {"notAWord": true} and nothing else. Treat a misspelling or OCR error of a real word AS that real word; when in doubt, explain rather than decline.`;

  const voice = bilingual
    ? `VOICE — you are TRANSLATING, not defining. For each meaning give the ${explainIn} word or short expression a bilingual dictionary lists as the equivalent — the translation of the WORD itself, NEVER a ${explainIn} definition, description, or example, NEVER opening with "${req.unit}". Plain everyday register.`
    : `VOICE — a seasoned learner explaining to a newcomer, in the plain spoken register of ${explainIn}:
- Explain the thing, not the term; concrete first, abstraction may follow but never lead.
- One idea per clause, with a nameable doer.
- Lead with the dominant sense; keep each sense to its essence.
- Every word plainer than the one explained; if plainness and accuracy conflict, keep accuracy — never invent.

NEVER: "the act/process/state of ..."; "refers to / is used to describe"; stacks of abstractions ("X, Y, or Z to A, B, or C"); agentless passives; opening any field with the word itself; example sentences; meta commentary.`;

  return `${head}

${voice}

FIELD JOBS:
- "readings": the word's distinct pronunciations; each reading carries a "pos" list — one entry per part of speech, each with its meanings ("senses").
- "senses": ${profile.sensesJob(req.unit, explainIn, bilingual)}

${profile.sensesTemplateNote(explainIn)}`;
}

/** Produces the model's parsed structured object for a unit. May throw (→ no spend). Injectable so
 *  the provider's mapping/contract is unit-testable without the network or SDK internals. */
export type WordGenerator = (req: GenerateRequest) => Promise<unknown>;

export class GeminiExplanationProvider implements ExplanationProvider {
  constructor(private readonly generateWord: WordGenerator) {}

  async generate(req: GenerateRequest): Promise<GenerateResult> {
    // A throw here propagates to the caller as a no-spend transport error (budget refunded).
    const object = await this.generateWord(req);
    // The raw object is UNTRUSTED — validate.ts is the gate that decides if it may be cached.
    return { raw: object };
  }
}
