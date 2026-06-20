import { POS_LABEL_SET } from "@capecho/lang";
import type { GenerateResult, PosGroup, Reading, WordExplanation } from "./provider.ts";

// Cache-write validation (CEO-8 / US-3.1): the gate between an untrusted model output
// and the shared cache. A malformed / empty / refusal / oversized (hallucinated)
// output is REJECTED so it never poisons the cache; the caller sets state=`failed`
// and writes nothing. Only `ok: true` may be cached + served + marked `ready`.
//
// Two-tier gate (Phase 1 senses blob, overlay-bilingual-plan.md): the MUST-PASS core is the
// captured unit's PRIMARY sense — at least one non-blank meaning must survive somewhere in
// `readings[].pos[].senses`; a blob with no sense at all is rejected (there is no prose
// `summary` fallback anymore). Everything else is OMIT-ON-FAIL: a bad transcription is blanked,
// an unknown POS label drops its group, an empty reading disappears — none of that blocks the
// primary sense. Every common sense the model lists is kept (no display cap — always show all).
// `pronunciationState` reports whether any pronunciation survived (E8 observability).

export type ValidationFailure =
  | "empty" // null / missing output
  | "malformed" // wrong shape (not the {readings:[{pronunciationPrimary,…,pos:[{partOfSpeech,senses,…}]}]} contract)
  | "refusal" // a model refusal rather than an explanation
  | "missing_sense" // no non-blank sense survived anywhere — the must-pass core (replaces the old missing_summary)
  | "oversized" // implausibly large — a hallucinated dump, not a concise explanation
  | "not_a_word"; // the model judged the unit a non-word ({"notAWord": true}) — L3 authority, not a failure

// The fate of the omit-on-fail per-reading pronunciation, for observability (E8):
//  - `present`  — ≥1 reading kept a pronunciation;
//  - `absent`   — the model offered none at all (a legitimate "unsure" / a phrase);
//  - `dropped`  — pronunciations were offered but none survived the per-field gate.
export type PronunciationFieldState = "present" | "absent" | "dropped";

export type ValidateOutcome =
  | { ok: true; value: WordExplanation; pronunciationState: PronunciationFieldState }
  | { ok: false; reason: ValidationFailure };

// Bounds. The free layer is deliberately concise (US-3.1); an output past these is
// treated as a hallucination, not content.
const MAX_READINGS = 6; // distinct pronunciations; more is a hallucinated dump
const MAX_POS_PER_READING = 8; // closed-set POS labels (+idiom); a longer list is garbage
const MAX_PRONUNCIATION_LEN = 120; // transcriptions (IPA / pinyin / kana) are short
const MAX_SENSE_LEN = 200; // one sense is a short gloss / translation, not a paragraph

// "idiom" is a valid POS label for a phrase reading (Reading.kind === "idiom") even though it is not in
// the grammatical closed set used for ordinary words.
const IDIOM_LABEL = "idiom";

// Catch the common refusal registers before they reach the cache.
const REFUSAL_RE =
  /\b(i can'?t|i cannot|i am unable|i'?m unable|as an ai|cannot help|i'?m sorry, but)\b/i;

// Gate one pronunciation string: trim, bound the length, reject a leaked refusal. Returns "" when the
// value is missing / empty / oversized / a refusal — OMIT-ON-FAIL, never a blob rejection.
function cleanPronunciation(raw: unknown): string {
  if (typeof raw !== "string") return "";
  const p = raw.trim();
  if (p.length === 0 || p.length > MAX_PRONUNCIATION_LEN) return "";
  if (REFUSAL_RE.test(p)) return "";
  return p;
}

// Gate one sense string: trim, bound the length, reject a leaked refusal. Returns "" to DROP the sense
// (omit-on-fail) — the must-pass check downstream rejects the whole blob only if EVERY sense drops.
function cleanSense(raw: unknown): string {
  if (typeof raw !== "string") return "";
  const s = raw.trim();
  if (s.length === 0 || s.length > MAX_SENSE_LEN) return "";
  if (REFUSAL_RE.test(s)) return "";
  return s;
}

export function validateWordExplanation(result: GenerateResult): ValidateOutcome {
  const raw = result?.raw;
  if (raw == null) return { ok: false, reason: "empty" };
  if (typeof raw !== "object") {
    if (typeof raw === "string" && REFUSAL_RE.test(raw)) {
      return { ok: false, reason: "refusal" };
    }
    return { ok: false, reason: "malformed" };
  }
  const ro = raw as Record<string, unknown>;

  // The model's explicit non-word verdict (L3): {"notAWord": true} instead of an invented explanation.
  // Checked FIRST — a distinct reason from a malformed/empty FAILURE: the caller maps it to status
  // `not_a_word`, not a retryable failure, and never caches it as a blob.
  if (ro.notAWord === true) return { ok: false, reason: "not_a_word" };

  // --- readings: pronunciation + per-POS senses ---------------------------------
  // Absent readings (the schema has no top-level `required` for the notAWord exit) degrade to [];
  // a PRESENT-but-wrong-shaped readings is malformed (a sign of a garbled output).
  const readingsRaw = ro.readings ?? [];
  if (!Array.isArray(readingsRaw)) return { ok: false, reason: "malformed" };
  if (readingsRaw.length > MAX_READINGS) return { ok: false, reason: "oversized" };

  const readings: Reading[] = [];
  let anySenseSurvived = false; // the must-pass signal: ≥1 non-blank meaning anywhere
  let anyPronunciationOffered = false; // ≥1 non-empty pronunciation string (pre-gate)
  let anyPronunciationSurvived = false; // ≥1 pronunciation passed the gate

  for (const r of readingsRaw) {
    if (r == null || typeof r !== "object") return { ok: false, reason: "malformed" };
    const rr = r as Record<string, unknown>;

    if (
      (typeof rr.pronunciationPrimary === "string" && rr.pronunciationPrimary.trim().length > 0) ||
      (typeof rr.pronunciationSecondary === "string" && rr.pronunciationSecondary.trim().length > 0)
    ) {
      anyPronunciationOffered = true;
    }
    const pronunciationPrimary = cleanPronunciation(rr.pronunciationPrimary);
    const pronunciationSecondary = cleanPronunciation(rr.pronunciationSecondary);
    if (pronunciationPrimary.length > 0 || pronunciationSecondary.length > 0) {
      anyPronunciationSurvived = true;
    }

    const kind: Reading["kind"] = rr.kind === IDIOM_LABEL ? IDIOM_LABEL : null;

    // POS groups, each with its meanings. A wrong container is malformed; an unknown label or an
    // empty senses list DROPS that group (omit-on-fail), never a blob rejection.
    const posRaw = rr.pos ?? [];
    if (!Array.isArray(posRaw)) return { ok: false, reason: "malformed" };

    const pos: PosGroup[] = [];
    const seenLabels = new Set<string>();
    for (const g of posRaw) {
      if (pos.length >= MAX_POS_PER_READING) break;
      if (g == null || typeof g !== "object") return { ok: false, reason: "malformed" };
      const gg = g as Record<string, unknown>;

      // Label: closed grammatical set (+ "idiom"); unknown / non-string / duplicate → drop the group.
      if (typeof gg.partOfSpeech !== "string") continue;
      const label = gg.partOfSpeech.trim().toLowerCase();
      if (!(POS_LABEL_SET.has(label) || label === IDIOM_LABEL)) continue;
      if (seenLabels.has(label)) continue;

      const sensesRaw = gg.senses ?? [];
      if (!Array.isArray(sensesRaw)) return { ok: false, reason: "malformed" };
      const senses: string[] = [];
      for (const s of sensesRaw) {
        const clean = cleanSense(s);
        if (clean.length === 0) continue;
        if (!senses.includes(clean)) senses.push(clean);
      }
      if (senses.length === 0) continue; // a POS group carrying no surviving sense contributes nothing

      seenLabels.add(label);
      pos.push({ partOfSpeech: label, senses }); // every common sense kept — the generation ceiling is the schema's maxItems
    }

    // A reading with no surviving sense renders nothing in the senses-first overlay → drop it (its
    // pronunciation alone is not a card). The must-pass check below catches "every reading dropped".
    if (pos.length === 0) continue;
    if (pos.some((p) => p.senses.length > 0)) anySenseSurvived = true;

    readings.push({ pronunciationPrimary, pronunciationSecondary, kind, pos });
  }

  // MUST-PASS: at least one non-blank sense survived somewhere (the captured unit's meaning). No
  // sense at all = nothing to show = reject (replaces the old missing_summary core).
  if (!anySenseSurvived) return { ok: false, reason: "missing_sense" };

  const pronunciationState: PronunciationFieldState = anyPronunciationSurvived
    ? "present"
    : anyPronunciationOffered
      ? "dropped"
      : "absent";

  return { ok: true, value: { readings }, pronunciationState };
}
