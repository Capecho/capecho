// The word DEDUP KEY — the deterministic, offline, language-independent normalization that answers
// "is this the same captured unit?" It is NOT a lemmatizer: `study` and `studied` (and `saw`/`see`) stay
// DISTINCT cards — capture-faithful, and what the market ships (Vocably). Only trivial noise collapses:
// `Study` / `study` / `study.` → one key. Deliberately NOT a lemmatizer (no @shared/normalization,
// no English-only machinery) — capture-faithful and language-independent.
//
// Steps: NFC (canonical Unicode) → lowercase → collapse internal whitespace → trim → strip leading/trailing
// non-(letter | mark | number). Native + total: pure-punctuation input normalizes to "" (the caller's
// empty-unit guard + the `isLikelyJunk` gate handle junk). NOTE: lowercase, NOT full Unicode casefold —
// German ß is not folded to ss (`straße` ≠ `strasse`), an accepted simplification of dropping the Rust core.

export const DEDUP_VERSION = "v1"; // bump to re-key (pre-launch: free; post-launch: a target-scoped re-key)

/** The deterministic dedup/cache key for a captured surface. Language-independent — dedup stays scoped by
 *  `(user_id, target_language, dedupKey)`, so the same string in two target languages never collides. */
export function dedupKey(surface: string): string {
  return surface
    .normalize("NFC")
    .toLowerCase()
    .replace(/\s+/gu, " ")
    .trim()
    .replace(/^[^\p{L}\p{M}\p{N}]+|[^\p{L}\p{M}\p{N}]+$/gu, "");
}
