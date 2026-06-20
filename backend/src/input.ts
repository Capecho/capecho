// Free word-layer input bounds (spec §13 "MVP core — thin-but-safe").
//
// The free, shared-cached word layer is for a SINGLE unit — a word or a short
// phrase, NOT a paragraph (a full sentence belongs to the metered, private context
// layer). OCR'd text is untrusted, so this bound is enforced SERVER-SIDE before the
// surface can become a cache key or burn AI spend: without it, "any sentence" makes
// the shared keyspace effectively unbounded and adversarial (§13), defeating the
// "AI cost scales with vocabulary, not usage" property the free tier rests on.
//
// The bound below is just length + unit count, applied to the NORMALIZED unit (what actually gets
// keyed); constants are conservative and tunable. A SEPARATE cheap gate — `isLikelyJunk` — rejects
// degenerate non-vocabulary (pure punctuation / numbers / URLs) so it can't burn AI spend either
// (RFC §B, eng-review). Deeper quality / sense classification remains post-MVP.

export const MAX_UNIT_CHARS = 80;
export const MAX_UNIT_WORDS = 6;
export const MAX_UNIT_CJK_CHARS = 8;

/** How many CJK ideographs are in [s]. CJK has no inter-word spaces, so the word bound never fires
 *  for it — the unit bound counts ideographs directly. The numeric ranges mirror the Dart
 *  Tokenizer.hanCharCount / isHanRun (BMP: Extension A, Unified, Compatibility); `for..of` iterates
 *  whole code points so a non-BMP char (code point > the ranges) correctly doesn't count.
 *
 *  This runs on the NORMALIZED (NFC) unit the server receives, while the client counts raw text: the
 *  7 U+F900-block compatibility ideographs that NFC decomposes to a non-BMP Ext-B char read as 0 here
 *  but are counted client-side — the deferred non-BMP-Han edge (review #4). Harmless: the divergence
 *  only makes the server MORE permissive, and the client is the stricter side that already routes such
 *  a run to the context first. */
function cjkCharCount(s: string): number {
  let n = 0;
  for (const ch of s) {
    const cp = ch.codePointAt(0)!;
    if ((cp >= 0x3400 && cp <= 0x4dbf) || (cp >= 0x4e00 && cp <= 0x9fff) || (cp >= 0xf900 && cp <= 0xfaff)) {
      n++;
    }
  }
  return n;
}

/**
 * True if a normalized unit is within the free word/phrase layer bounds. Callers gate
 * on this before keying/generating; an over-bound selection is rejected (422) with a
 * pointer to the context layer rather than silently cached.
 */
export function unitWithinBounds(normalizedUnit: string): boolean {
  if (normalizedUnit.length === 0 || normalizedUnit.length > MAX_UNIT_CHARS) return false;
  const words = normalizedUnit.split(/\s+/u).filter((w) => w.length > 0).length;
  if (words > MAX_UNIT_WORDS) return false;
  // CJK has no inter-word spaces, so the word bound never fires for it; bound ideograph count directly.
  // A long space-free CJK run is a clause, not a word/short phrase (mirrors the client looksLikeSentence
  // ceiling, so client + server agree on what's a unit vs a sentence).
  return cjkCharCount(normalizedUnit) <= MAX_UNIT_CJK_CHARS;
}

const HAS_LETTER = /\p{L}/u;
// An email's "@" sits BETWEEN word characters (`user@host`); anchoring on `\w@\w` avoids rejecting a
// LEADING-"@" technical term — CSS at-rules (`@media`, `@font-face`) and decorators (`@Override`) are
// real units, not emails (PR #51 review). Mirrors the client `_emailish` in junk_filter.dart.
const EMAILISH = /\w@\w/;

/**
 * SERVER-AUTHORITATIVE degenerate-junk gate (RFC §B): true ⇒ [unit] is non-vocabulary that must NOT
 * cost an `/explain` generation. The authoritative twin of the client's cheap `isLikelyJunk`
 * (`capecho_capture_core`, Dart) — SAME reject set, but THIS is the gate that actually protects spend,
 * since a client gate can be bypassed or diverge across platforms.
 *
 * THE DISCIPLINE (eng-review — the one flagged silent-failure mode): reject TRUE junk ONLY. A false
 * reject means a real word is NEVER explained — far worse than a wasted call. So anything that could
 * be a real word (proper nouns, technical terms, OCR-corrupted words, diacritics, CJK) MUST pass; we
 * reject only degenerate shapes: empty, no letter in ANY script (pure punctuation / number / symbol /
 * emoji), or a URL / email. `\p{L}` matches every script incl. CJK ideographs (category Lo), so a real
 * word in any script keeps its linguistic content and passes. When unsure, PASS.
 */
export function isLikelyJunk(unit: string): boolean {
  const trimmed = unit.trim();
  if (trimmed.length === 0) return true;
  if (!HAS_LETTER.test(trimmed)) return true;
  // URL / email shapes carry letters but are never a vocabulary unit: "://" anywhere, or an "@" between
  // word chars (an email local@domain). A LEADING "@" (a CSS at-rule / decorator) is a real unit → PASS.
  if (trimmed.includes("://") || EMAILISH.test(trimmed)) return true;
  return false;
}

// QWERTY rows (lowercased); a learner mashing keys slides along one of these. Mirrors the client
// gibberish_filter.dart, asserted against the SAME shared gibberish_vectors fixture so the two
// hand-ported gates can't silently diverge (same lockstep discipline as isLikelyJunk above).
const KB_ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"];
const KB_POS = new Map<string, { row: number; col: number }>();
KB_ROWS.forEach((row, r) => {
  for (let c = 0; c < row.length; c++) KB_POS.set(row[c]!, { row: r, col: c });
});

/** True ⇒ the SAME character repeats >= 4 times consecutively (a held key / OCR stutter). */
function hasLongRepeat(s: string): boolean {
  let run = 1;
  for (let i = 1; i < s.length; i++) {
    if (s[i] === s[i - 1]) {
      if (++run >= 4) return true;
    } else {
      run = 1;
    }
  }
  return false;
}

/** True ⇒ the ENTIRE token is a single monotonic run of >= 5 keys along ONE QWERTY row (a "walk":
 *  "qwerty", "asdfgh"). Whole-token, NOT substring: every key same-row, horizontally adjacent, one
 *  direction — so a word merely CONTAINING a run ("liberty" holds "erty") fails at its first off-row
 *  pair, and a flip ("were") fails too. The >= 5 floor excludes the lone 4-key single-row real word
 *  "wert"; a bare 4-key mash ("asdf") defers to the L3 model gate → provably zero real-word
 *  false-rejects (313k-word brute-force). (The substring form false-rejected liberty/property — dual CR.) */
function isKeyboardWalk(s: string): boolean {
  const lower = s.toLowerCase();
  if (lower.length < 5) return false;
  const first = KB_POS.get(lower[0]!);
  if (!first) return false;
  const row = first.row;
  let prevCol = first.col;
  let dir: number | null = null; // +1 rightward / -1 leftward; fixed by the first step
  for (let i = 1; i < lower.length; i++) {
    const p = KB_POS.get(lower[i]!);
    if (!p || p.row !== row) return false; // every key on the SAME row…
    const d = p.col - prevCol;
    if (d !== 1 && d !== -1) return false; // …horizontally adjacent…
    if (dir === null) dir = d;
    else if (d !== dir) return false; // …keeping one direction
    prevCol = p.col;
  }
  return true;
}

/**
 * SERVER-AUTHORITATIVE gibberish gate ("L1" twin): true ⇒ [unit] is a single keyboard-mash /
 * repeated-key token that must NOT cost an `/explain` generation. Companion to isLikelyJunk (which
 * rejects no-letter / URL shapes); THIS rejects letter strings that are still not words ("asdfgh",
 * "aaaa"). SAME silent-failure discipline: it fires on ONLY the two signals no real word produces (a
 * >=4-key monotonic walk along one QWERTY row, or a >=4 identical-char repeat) and is the authority for
 * nothing — the word-SHAPED ambiguous middle is left to the model gate. Phrases + non-Latin scripts
 * pass. When unsure, PASS.
 */
export function isLikelyGibberish(unit: string): boolean {
  const t = unit.trim();
  if (t.length === 0) return false; // empties are isLikelyJunk's job
  if (/\s/u.test(t)) return false; // a real phrase is never pure mash → defer to the model gate
  return hasLongRepeat(t) || isKeyboardWalk(t);
}
