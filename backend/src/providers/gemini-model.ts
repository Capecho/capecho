import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { generateObject, jsonSchema } from "ai";
import type { GenerateRequest } from "../provider.ts";
import type { ContextGenerateRequest } from "../context-provider.ts";
import {
  buildExplanationPrompt,
  DEFAULT_GEMINI_MODEL,
  DEFAULT_GEMINI_CONTEXT_MODEL,
  GeminiExplanationProvider,
  type WordGenerator,
} from "./gemini.ts";
import { buildWordSchemaObject, requireTargetPromptProfile } from "./target-profiles.ts";
import {
  buildContextPrompt,
  GeminiContextProvider,
  type ContextGlossGenerator,
} from "./gemini-context.ts";

// The Google Gemini wiring (Vercel AI SDK). Isolated from gemini.ts so only the production code path
// imports the SDK — the unit tests exercise GeminiExplanationProvider with an injected generator.
//
// `generateObject` constrains the model to the per-target word schema below — the
// `{ readings: [{ pronunciationPrimary, pronunciationSecondary, pos: [{ partOfSpeech, senses }] }] }`
// shape validate.ts consumes (the per-POS `senses` are the must-pass core; there is no prose summary).
// The schema is BUILT PER TARGET PROFILE: its `description` strings are model instructions
// (pronunciation format, reading-split policy), and those differ per language — a global constant
// would teach zh pinyin "General American IPA". Readings group the parts of speech BY PRONUNCIATION
// (a heteronym splits into several readings; a normal word is one). `partOfSpeech` is enum-constrained
// to the profile's closed POS subset; validation re-filters against the full closed set (defense in
// depth). Pronunciation is OMIT-ON-FAIL per reading. On API error generateObject throws → the caller
// refunds the reserved budget (no spend).

interface WordPayload {
  notAWord?: boolean;
  readings?: {
    pronunciationPrimary?: string;
    pronunciationSecondary?: string;
    kind?: string;
    pos?: { partOfSpeech?: string; senses?: string[] }[];
  }[];
}

// One schema per profile — built lazily from the pure schema object (target-profiles.ts holds the
// construction + the notAWord no-required rationale; do NOT add a validate fn to jsonSchema: that
// leniency is what lets the bare exit object through generateObject), reused across requests.
type WordSchema = ReturnType<typeof jsonSchema<WordPayload>>;
const WORD_SCHEMAS = new Map<string, WordSchema>();
function wordSchemaFor(targetTag: string): WordSchema {
  let s = WORD_SCHEMAS.get(targetTag);
  if (!s) {
    s = jsonSchema<WordPayload>(
      buildWordSchemaObject(requireTargetPromptProfile(targetTag)) as Parameters<typeof jsonSchema>[0],
    );
    WORD_SCHEMAS.set(targetTag, s);
  }
  return s;
}

/** The real Gemini-backed word generator. Workers-safe: the API key is passed explicitly (no
 *  process.env); the request goes to Google's Generative Language API. */
export function geminiWordGenerator(apiKey: string, modelId: string = DEFAULT_GEMINI_MODEL): WordGenerator {
  const google = createGoogleGenerativeAI({ apiKey });
  const model = google(modelId);
  return async (req: GenerateRequest) => {
    const { object } = await generateObject({
      model,
      schema: wordSchemaFor(req.targetLanguage),
      temperature: 0.2, // low → reliable structured output + stable cached summaries
      // Cost-amplification guard: the word payload is a few readings → POS → short senses, so it never
      // needs many tokens. Without a cap, per-call cost is bounded only by the model default; a crafted
      // input can't then drive output (and $) up while the generation COUNT stays budget-capped. 1024 is
      // generous headroom for even a multi-heteronym word — real payloads sit well under it.
      maxOutputTokens: 1024,
      prompt: buildExplanationPrompt(req),
    });
    return object;
  };
}

/** Construct the production Gemini provider from a Worker secret. */
export function makeGeminiProvider(apiKey: string, modelId?: string): GeminiExplanationProvider {
  return new GeminiExplanationProvider(geminiWordGenerator(apiKey, modelId));
}

// The PRIVATE context layer's gloss schema — ONE free-form field (v3): a single explanation covering
// both the unit's in-context meaning and the whole sentence's meaning. `generateObject` constrains the
// model to `{ meaning }`, which validate-context.ts consumes. The description is structure-only — the
// prose prompt (gemini-context.ts) is the single home of the "explain freely + never a word harder than
// the headword" rule, with no fixed format.
const CONTEXT_GLOSS_SCHEMA = jsonSchema<{ meaning: string }>({
  type: "object",
  additionalProperties: false,
  required: ["meaning"],
  properties: {
    meaning: {
      type: "string",
      description:
        "A plain explanation in the explanation language: what the unit means as used in the text, and what the text says as a whole — without inventing anything the text does not contain.",
    },
  },
});

/** The real Gemini-backed context-gloss generator. Workers-safe: the API key is passed explicitly (no
 *  process.env). Sends the user's sentence to Google — the zero-retention vendor requirement (T8). */
export function geminiContextGlossGenerator(
  apiKey: string,
  modelId: string = DEFAULT_GEMINI_CONTEXT_MODEL,
): ContextGlossGenerator {
  const google = createGoogleGenerativeAI({ apiKey });
  const model = google(modelId);
  return async (req: ContextGenerateRequest) => {
    const { object } = await generateObject({
      model,
      schema: CONTEXT_GLOSS_SCHEMA,
      temperature: 0.2, // low → reliable structured output
      // Cost-amplification guard: the payload is a single short `meaning` string. Without a cap, a
      // crafted context (up to MAX_CONTEXT_CHARS) could elicit a maximal-length response and inflate
      // per-call $ even though the generation COUNT stays budget-capped. 512 is generous for one gloss.
      maxOutputTokens: 512,
      prompt: buildContextPrompt(req),
    });
    return object;
  };
}

/** Construct the production Gemini context provider from a Worker secret. */
export function makeGeminiContextProvider(apiKey: string, modelId?: string): GeminiContextProvider {
  return new GeminiContextProvider(geminiContextGlossGenerator(apiKey, modelId));
}
