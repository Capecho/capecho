// The PRIVATE, metered context-explanation provider (US-3.2). Distinct from the free
// word-layer provider: it explains the unit IN the user's sentence, so it receives the
// (sensitive) context text — it MUST be a zero-retention / no-training vendor (T8),
// and the sentence is sent off-box ONLY here (§9). Per-request, never shared-cached.

// Versioned independently of the word-layer PROMPT_VERSION: the context prompt can
// change without re-keying the shared word cache. Stored inside the encrypted gloss
// payload so a re-view can tell which prompt produced a stored gloss (a version-mismatched
// stored gloss simply regenerates on next view; the re-view ALSO guards on the SHAPE —
// see explain-context.ts).
// The in-context answer is ONE field (v3): a single free-form explanation that covers BOTH the word's
// meaning AS USED in this sentence AND what the whole sentence is saying — no fixed format, no forced
// order (founder decision). The one load-bearing rule is Maimemo's: never explain with a word harder
// than the unit itself ("use only words simpler than the headword"), which keeps the answer plain in
// both the cross-language case (the gloss reads as a translation) and the same-language case (a plain
// definition + a plainer retelling). The prompt names the text's language only when the client knew it
// with script-certainty (contextLanguage NEVER defaults to the target — a zh unit captured in an
// English article is the normal mixed case), and marks the asked-about occurrence in the text when a
// span resolves (see gemini-context.ts).
// v4 (2026-06-18): three fixes — a bare label/single word must NOT be padded into a fabricated sentence;
// a marked occurrence is steered explicitly (a repeated word's marked spot may carry a different sense
// than the others, which the model otherwise ignored); and a faithful-retelling rule (don't add
// obligation/certainty/cause the text doesn't state; don't swap a rate/comparison for a total; when
// unsure, prefer the weaker reading — these were real model distortions that mislead the reader).
// Per-user lazy regen; no rekey.
export const CONTEXT_PROMPT_VERSION = "v4";

export interface ContextGenerateRequest {
  unit: string; // the surface unit being explained
  targetLanguage: string; // canonical target of the unit
  contextText: string; // the user's sentence (SENSITIVE — never logged)
  /** The TEXT's language, only when known with script-certainty; null = unknown (the prompt then
   *  says "the text below"). Never defaulted from the target — the languages genuinely diverge
   *  (a zh-Hans unit captured inside an English article). */
  contextLanguage: string | null;
  explanationLanguage: string; // resolved gloss language (a member of EXPLANATION_LANGUAGES)
  spanStart?: number | null;
  spanEnd?: number | null;
}

// Untrusted raw model output (validated before it is encrypted + stored).
export interface ContextGenerateResult {
  raw: unknown;
}

export interface ContextExplanationProvider {
  /**
   * Generate a sentence-specific explanation. MAY throw on transport/timeout — a throw
   * means NO spend (the caller refunds both the per-user reservation and the global
   * budget). A *returned* result counts as spend even if validation later rejects it.
   * Must never log the context text.
   */
  generate(req: ContextGenerateRequest): Promise<ContextGenerateResult>;
}
