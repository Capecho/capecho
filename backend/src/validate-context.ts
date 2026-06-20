import { CONTEXT_PROMPT_VERSION, type ContextGenerateResult } from "./context-provider.ts";

// Cache-write-style validation for the PRIVATE context gloss (CEO-8 parity with the
// word layer): an empty / malformed / refusal / oversized model output is rejected so
// it is never stored against the user's context. The answer is ONE free-form field (v3)
// covering both the unit's in-context meaning and the whole sentence's meaning; it must
// be present and non-empty (a missing field is a non-answer). A rejected gloss refunds
// the user's reservation (the slot isn't spent on a non-answer) — see explain-context.

export type ContextValidationFailure = "empty" | "malformed" | "refusal" | "oversized";

export type ContextValidateOutcome =
  | { ok: true; value: ContextExplanation }
  | { ok: false; reason: ContextValidationFailure };

// The stored (then encrypted) gloss payload. promptVersion travels with it so a future
// prompt change can drive lazy regeneration without a schema column.
export interface ContextExplanation {
  meaning: string; // the unit's in-context meaning AND the whole sentence's meaning, in one answer
  promptVersion: string;
}

// The answer covers a word gloss plus a retelling of the (bounded) sentence; past this it's
// a hallucinated dump, not an answer.
const MAX_MEANING_LEN = 2400;

const REFUSAL_RE =
  /\b(i can'?t|i cannot|i am unable|i'?m unable|as an ai|cannot help|i'?m sorry, but)\b/i;

export function validateContextExplanation(result: ContextGenerateResult): ContextValidateOutcome {
  const raw = result?.raw;
  if (raw == null) return { ok: false, reason: "empty" };
  if (typeof raw !== "object") {
    if (typeof raw === "string" && REFUSAL_RE.test(raw)) return { ok: false, reason: "refusal" };
    return { ok: false, reason: "malformed" };
  }
  const rec = raw as Record<string, unknown>;
  const m = rec.meaning;
  if (typeof m !== "string") return { ok: false, reason: "malformed" };
  const meaning = m.trim();
  if (meaning.length === 0) return { ok: false, reason: "empty" };
  if (meaning.length > MAX_MEANING_LEN) return { ok: false, reason: "oversized" };
  if (REFUSAL_RE.test(meaning)) return { ok: false, reason: "refusal" };
  return { ok: true, value: { meaning, promptVersion: CONTEXT_PROMPT_VERSION } };
}
