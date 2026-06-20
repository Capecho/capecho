import type {
  ContextExplanationProvider,
  ContextGenerateRequest,
  ContextGenerateResult,
} from "../context-provider.ts";
import { explanationLanguageName } from "./gemini.ts";

// The PRIVATE context-explanation provider, model-agnostic core (NO AI-SDK import here, so the unit
// tests + `bun test` never load the heavy SDK). The real Gemini wiring lives in `gemini-model.ts`.
//
// Distinct from the free word-layer provider: it explains the unit IN the user's sentence, so the
// (sensitive) context text is sent off-box — this is the ONLY place that happens (§9), and the vendor
// must be zero-retention / no-training (T8). The result is per-request, never shared-cached. Contract:
// the model-call step is injected as a `ContextGlossGenerator`; on a transport/timeout error it THROWS
// (the caller refunds the per-user reservation AND the global budget). A returned-but-malformed result
// still counts as spend and is rejected at the cache-write gate (validate-context.ts). Never log the
// context text.

/** The marker pair wrapped around the asked-about occurrence in the prompt text. Bracket-y enough to
 *  never occur in real captured text; the prompt tells the model the markers are NOT part of the text. */
const MARK_OPEN = "[[TARGET]]";
const MARK_CLOSE = "[[/TARGET]]";

// Letters/digits that glue into their neighbors in space-delimited scripts (Latin incl. accents,
// Greek (incl. Extended), Cyrillic, Latin Extended Additional (Vietnamese ạ/ế/…). CJK is deliberately
// ABSENT: CJK text has no word boundaries, so adjacency there must never reject a real occurrence —
// only a Latin/Cyrillic-edged unit needs word bounds (so a substring hit inside another word — unit
// "art" inside "particular" — is never marked).
const GLUE = /[0-9A-Za-zÀ-ɏͰ-ϿЀ-ԯḀ-ỿἀ-῿]/;

function isWordBounded(text: string, start: number, end: number): boolean {
  const headGlues = GLUE.test(text[start] ?? "");
  const tailGlues = GLUE.test(text[end - 1] ?? "");
  if (headGlues && start > 0 && GLUE.test(text[start - 1]!)) return false;
  if (tailGlues && end < text.length && GLUE.test(text[end]!)) return false;
  return true;
}

/** The occurrence of [unit] to mark in the prompt, or null to not mark (the prompt then falls back to
 *  naming the unit — the pre-span behavior). Exported for regression tests.
 *
 *  Resolution is self-healing, never trusting: the client's span is used only when it is a valid
 *  in-bounds range that actually SELECTS the unit (case-insensitive — the client resolver matches
 *  case-insensitively) on word bounds; anything else falls back to the unique WORD-BOUNDED
 *  case-insensitive occurrence — substring hits inside other words don't count as competition, so
 *  unit "art" in "particular art" still marks the standalone word (a strict superset of the save
 *  path's `UnitSpanResolver` self-healing). A repeated unit without a valid span stays unmarked —
 *  from `(unit, text)` alone the asked-about occurrence is unknowable, and a guessed-wrong marker
 *  is worse than none. */
export function resolveMarkedRange(
  text: string,
  unit: string,
  spanStart: number | null,
  spanEnd: number | null,
): { start: number; end: number } | null {
  const u = unit.trim();
  if (u.length === 0 || text.length === 0) return null;
  // Case-fold for matching — but only when folding preserves offsets (a few code points change
  // length under toLowerCase, e.g. İ); otherwise match case-sensitively on the original.
  const lowerText = text.toLowerCase();
  const lowerUnit = u.toLowerCase();
  const foldSafe = lowerText.length === text.length && lowerUnit.length === u.length;
  const hay = foldSafe ? lowerText : text;
  const needle = foldSafe ? lowerUnit : u;

  if (
    Number.isInteger(spanStart) &&
    Number.isInteger(spanEnd) &&
    (spanStart as number) >= 0 &&
    (spanEnd as number) > (spanStart as number) &&
    (spanEnd as number) <= text.length
  ) {
    const s = spanStart as number;
    const e = spanEnd as number;
    if (hay.slice(s, e) === needle && isWordBounded(text, s, e)) return { start: s, end: e };
  }

  // Fallback: the unique WORD-BOUNDED occurrence. Mid-word substring hits are skipped, not counted
  // as ambiguity (unit "art" in "particular art" → the standalone word marks). Scan advances one
  // past each match's START so overlapping repeats ("ana" in "banana") still read as two.
  let bounded: { start: number; end: number } | null = null;
  for (let i = hay.indexOf(needle); i >= 0; i = hay.indexOf(needle, i + 1)) {
    if (!isWordBounded(text, i, i + needle.length)) continue;
    if (bounded !== null) return null; // two word-bounded occurrences — never guess
    bounded = { start: i, end: i + needle.length };
  }
  return bounded;
}

/** Build the in-context generation prompt for one unit. Exported so a refactor can't silently drop the
 *  unit / text / explanation-language framing (regression-tested). The answer is ONE free-form field —
 *  what "${unit}" means AS USED here AND what the whole sentence is saying, in the explanation language,
 *  no fixed format (founder decision: keep the input simple, let the model explain freely). The one
 *  load-bearing rule is Maimemo's: never explain with a word harder than the unit itself, which keeps it
 *  plain both cross-language (reads as a translation) and same-language (a plain definition + retelling).
 *
 *  Language axes (all names, never raw BCP-47 tags): the unit's target language and the explanation
 *  language are always known; the TEXT's language is stated only when the client knew it with
 *  script-certainty — when absent the prompt just says "the text below" (the model reads the text
 *  itself; a wrong label is worse than none, which is why this never defaults to the target).
 *
 *  The asked-about occurrence is marked [[TARGET]]…[[/TARGET]] when resolvable (client span, or the
 *  unique occurrence) — so a repeated unit explains the RIGHT occurrence; the markers are introduced
 *  to the model as annotation, not text. */
export function buildContextPrompt(req: ContextGenerateRequest): string {
  const explainIn = explanationLanguageName(req.explanationLanguage);
  const targetName = explanationLanguageName(req.targetLanguage);
  // The text-language label requires a REAL name: explanationLanguageName falls back to the raw tag
  // for an unnamed one (the context layer accepts any canonical value), and a raw "en-US" — or worse —
  // in the prompt violates "names, never tags". Unnamed ⇒ treated as unknown, same as absent.
  const contextName =
    req.contextLanguage == null || req.contextLanguage === ""
      ? null
      : explanationLanguageName(req.contextLanguage);
  const textLabel =
    contextName === null || contextName === req.contextLanguage
      ? "the text below"
      : `the ${contextName} text below`;
  const range = resolveMarkedRange(req.contextText, req.unit, req.spanStart ?? null, req.spanEnd ?? null);
  const text =
    range === null
      ? req.contextText
      : req.contextText.slice(0, range.start) +
        MARK_OPEN +
        req.contextText.slice(range.start, range.end) +
        MARK_CLOSE +
        req.contextText.slice(range.end);
  const textIntro =
    range === null
      ? "Text:"
      : `Text (the asked-about occurrence is marked ${MARK_OPEN}…${MARK_CLOSE}; the markers are NOT part of the text — never mention or copy them):`;
  // When an occurrence is marked, point the explanation AT it: a repeated word can carry a different
  // sense in different spots, and the model otherwise drifts to the word's most common sense (which is
  // usually the first occurrence). Empty when nothing is marked (the unique/unmarked case needs none).
  const markedNote =
    range === null
      ? ""
      : ` The marked word is the one to explain — when the same word appears more than once, the marked occurrence may carry a different sense than the others, so read it in its own spot.`;
  return `A learner who reads ${explainIn} is reading ${textLabel} and asks about the ${targetName} word or phrase "${req.unit}" in it. In ${explainIn}, plainly and briefly, tell them what "${req.unit}" means as it is used in the text, and what the text is saying as a whole.${markedNote} Use only words simpler than "${req.unit}" itself — never explain it with anything harder. Explain only what the text actually contains: if it is a bare label or single word with no full sentence, just give that word's meaning — never invent a surrounding sentence or details that are not there. When you retell what the sentence says, keep its claim exact — do not add obligation, certainty, or cause the text does not state, and do not swap its relationship for a different one (a statement about how fast something changes is not a statement about its total). If you are unsure how strongly to put something, choose the weaker reading over the stronger one.

${textIntro} ${text}`;
}

/** Produces the model's parsed structured object ({ gloss }) for a unit-in-context. May throw (→ no
 *  spend). Injectable so the provider's mapping/contract is unit-testable without the network or SDK. */
export type ContextGlossGenerator = (req: ContextGenerateRequest) => Promise<unknown>;

export class GeminiContextProvider implements ContextExplanationProvider {
  constructor(private readonly generateGloss: ContextGlossGenerator) { }

  async generate(req: ContextGenerateRequest): Promise<ContextGenerateResult> {
    // A throw here propagates to the caller as a no-spend transport error (reservation + budget
    // refunded). The raw object is UNTRUSTED — validate-context.ts is the gate that decides if it may
    // be stored against the user's context.
    const object = await this.generateGloss(req);
    return { raw: object };
  }
}
