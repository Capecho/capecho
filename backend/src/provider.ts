import type { ExplanationLanguage } from "@capecho/lang";

// One part of speech under a reading + its meanings — the bilingual per-POS gloss row the overlay
// renders (Phase 1, overlay-bilingual-plan.md). The `senses` are written in the EXPLANATION language:
// when the explanation language differs from the word's target language they read as translations;
// when they match they read as short definitions (same prompt, the language does the rest).
export interface PosGroup {
  partOfSpeech: string; // closed-set short ENGLISH label (@capecho/lang POS_LABELS), or "idiom"
  senses: string[]; // ALL common meanings, frequency-ordered; in the explanation language (every surface shows them all)
}

// One PRONUNCIATION (reading) of a word + the parts of speech (each with its meanings) used under it —
// the entry's organizing axis. Most words have one reading; a heteronym has several (the noun
// /ˈɑbdʒɛkt/ "object" vs the verb /əbˈdʒɛkt/). What a "pronunciation" IS is target-profile-defined
// (en: GenAm + RP IPA; zh-Hans: Hanyu Pinyin, no secondary) — the blob fields are target-neutral;
// display labels ("US"/"UK") come from the profile, never from the data.
export interface Reading {
  pronunciationPrimary: string; // bare transcription; "" when unknown / omit-on-failed (renderer decorates)
  pronunciationSecondary: string; // bare; "" when the target has no second slot / unknown / omit-on-failed
  kind: "idiom" | null; // "idiom" => a phrase/idiom: render a badge, suppress IPA; null for ordinary words
  pos: PosGroup[]; // POS groups, each with its meanings; MUST-PASS at least one sense across the blob
}

// The cached + served word explanation = the model's VALIDATED content only. The request's unit /
// target / explanation-language and the prompt version are deliberately NOT echoed into the blob: each
// is already encoded in the durable cache key (cache-key.ts), and no client or server path reads them
// off the payload — carrying them only bloats every cached blob and every /explain response.
//
// Phase 1 (overlay-bilingual-plan.md): the single prose `summary` was replaced by per-POS `senses`.
// MUST-PASS: the captured unit's PRIMARY sense (readings[0].pos[0].senses[0]); everything else is
// omit-on-fail. Surfaces that still want one line derive it via `previewLine()` — there is no stored
// summary field.
export interface WordExplanation {
  // Pronunciation + per-POS meanings, grouped by reading. The primary sense is must-pass; pronunciation
  // and extra senses are omit-on-fail.
  readings: Reading[];
}

// The one-line preview every COMPACT surface (Word Book list row, Review preview, export definition)
// derives from the structured blob: the captured unit's primary sense. One home for the derivation so
// the surfaces never re-implement it (DRY). "" only for a degenerate blob with no senses at all.
export function previewLine(exp: WordExplanation): string {
  for (const r of exp.readings) {
    for (const p of r.pos) {
      const s = p.senses[0];
      if (typeof s === "string" && s.trim().length > 0) return s.trim();
    }
  }
  return "";
}

export interface GenerateRequest {
  unit: string; // surface unit to explain (already validated as a single unit)
  normalizedUnit: string; // server-normalized form
  targetLanguage: string; // canonical generation tag (a target profile's tag) — gate before calling
  explanationLanguage: ExplanationLanguage;
}

// What a provider hands back BEFORE validation — untrusted (CEO-8): it may be
// malformed / empty / a refusal / hallucinated JSON. `validate.ts` is the gate that
// decides whether it may be cached.
export interface GenerateResult {
  raw: unknown; // raw structured output from the model (shape unknown until validated)
}

export interface ExplanationProvider {
  /**
   * Generate a word-level explanation. MAY throw on transport/timeout — a throw means
   * NO spend (the caller refunds the reserved global budget). A *returned* result
   * counts as spend even if validation later rejects it (the model was already paid).
   *
   * The real provider must be a zero-retention / no-training vendor (T8) and must
   * never receive or log sensitive context — the word layer sends only the unit.
   */
  generate(req: GenerateRequest): Promise<GenerateResult>;
}
