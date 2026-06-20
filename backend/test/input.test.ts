import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { unitWithinBounds, isLikelyJunk, isLikelyGibberish, MAX_UNIT_CHARS, MAX_UNIT_WORDS, MAX_UNIT_CJK_CHARS } from "../src/input.ts";

test("a single word and a short phrase are within bounds", () => {
  expect(unitWithinBounds("serendipity")).toBe(true);
  expect(unitWithinBounds("out of the blue")).toBe(true);
});

test("an empty unit is out of bounds (caught separately as empty, but never valid here)", () => {
  expect(unitWithinBounds("")).toBe(false);
});

test("a sentence exceeds the word-count bound", () => {
  const sentence = Array.from({ length: MAX_UNIT_WORDS + 1 }, (_, i) => `w${i}`).join(" ");
  expect(unitWithinBounds(sentence)).toBe(false);
});

test("exactly MAX_UNIT_WORDS words is allowed; one more is rejected", () => {
  const ok = Array.from({ length: MAX_UNIT_WORDS }, (_, i) => `w${i}`).join(" ");
  const over = Array.from({ length: MAX_UNIT_WORDS + 1 }, (_, i) => `w${i}`).join(" ");
  expect(unitWithinBounds(ok)).toBe(true);
  expect(unitWithinBounds(over)).toBe(false);
});

test("an over-length single token is rejected (OCR junk / a glued paragraph)", () => {
  expect(unitWithinBounds("x".repeat(MAX_UNIT_CHARS + 1))).toBe(false);
  expect(unitWithinBounds("x".repeat(MAX_UNIT_CHARS))).toBe(true);
});

test("a long space-free CJK clause exceeds the CJK ideograph bound (the word bound can't see it)", () => {
  // CJK has no spaces, so split(/\s+/) always sees 1 "word" — the ideograph ceiling is what bounds it.
  expect(unitWithinBounds("人工智能技术")).toBe(true); // 6 ideographs — a compound, a valid unit
  expect(unitWithinBounds("我在学习中文很有意思")).toBe(false); // 10 ideographs — a clause, over the bound
});

test("exactly MAX_UNIT_CJK_CHARS ideographs is allowed; one more is rejected", () => {
  const ideo = String.fromCodePoint(0x4e2d); // 中
  expect(unitWithinBounds(ideo.repeat(MAX_UNIT_CJK_CHARS))).toBe(true);
  expect(unitWithinBounds(ideo.repeat(MAX_UNIT_CJK_CHARS + 1))).toBe(false);
});

// --- isLikelyJunk — the SILENT-FAILURE guard, via the SHARED parity fixture
// The one flagged failure mode: this AUTHORITATIVE gate rejecting a REAL word means that word is NEVER
// explained (server-side decides spend — a false reject is permanent). The vectors live in ONE shared
// file that the Dart client gate (capture-core junk_filter_test) asserts against too, so the two
// hand-ported implementations can't silently diverge. Every "pass" entry MUST stay isLikelyJunk false.
function loadJunkVectors(): { pass: string[]; reject: string[] } {
  const candidates = [
    `${import.meta.dir}/../../shared/capture-core/test/fixtures/junk_gate_vectors.json`, // robust to cwd
    "../shared/capture-core/test/fixtures/junk_gate_vectors.json", // cwd = backend
    "shared/capture-core/test/fixtures/junk_gate_vectors.json", // cwd = repo root
  ];
  for (const p of candidates) {
    try {
      return JSON.parse(readFileSync(p, "utf8")) as { pass: string[]; reject: string[] };
    } catch {
      // try the next candidate path
    }
  }
  throw new Error("junk_gate_vectors.json not found");
}
const VECTORS = loadJunkVectors();

for (const u of VECTORS.pass) {
  test(`MUST pass — real unit reaches /explain: ${JSON.stringify(u)}`, () => {
    expect(isLikelyJunk(u)).toBe(false);
  });
}
for (const j of VECTORS.reject) {
  test(`rejects true junk: ${JSON.stringify(j)}`, () => {
    expect(isLikelyJunk(j)).toBe(true);
  });
}

test("isLikelyJunk trims before judging (parity with the client)", () => {
  expect(isLikelyJunk("  serendipity  ")).toBe(false);
  expect(isLikelyJunk("   学习 ")).toBe(false);
  expect(isLikelyJunk("   ")).toBe(true);
});

// --- isLikelyGibberish — the stricter gate, via the SHARED gibberish parity fixture. Same
// silent-failure discipline as isLikelyJunk: a "pass" word rejected here is never explained. The client
// twin (capture-core gibberish_filter_test) asserts the same vectors, so the two can't diverge.
function loadGibberishVectors(): { pass: string[]; reject: string[] } {
  const candidates = [
    `${import.meta.dir}/../../shared/capture-core/test/fixtures/gibberish_vectors.json`,
    "../shared/capture-core/test/fixtures/gibberish_vectors.json",
    "shared/capture-core/test/fixtures/gibberish_vectors.json",
  ];
  for (const p of candidates) {
    try {
      return JSON.parse(readFileSync(p, "utf8")) as { pass: string[]; reject: string[] };
    } catch {
      // try the next candidate path
    }
  }
  throw new Error("gibberish_vectors.json not found");
}
const GIBBERISH = loadGibberishVectors();

for (const u of GIBBERISH.pass) {
  test(`MUST pass — real unit reaches /explain: ${JSON.stringify(u)}`, () => {
    expect(isLikelyGibberish(u)).toBe(false);
  });
}
for (const j of GIBBERISH.reject) {
  test(`rejects gibberish: ${JSON.stringify(j)}`, () => {
    expect(isLikelyGibberish(j)).toBe(true);
  });
}

// The gibberish gate is STRICTER than the junk gate, so it must never reject a word the junk gate
// already passes (parity with the client's same cross-check).
for (const u of VECTORS.pass) {
  test(`gibberish gate never flags a junk-pass word: ${JSON.stringify(u)}`, () => {
    expect(isLikelyGibberish(u)).toBe(false);
  });
}

test("isLikelyGibberish trims before judging; phrases + non-Latin pass", () => {
  expect(isLikelyGibberish("  asdfg  ")).toBe(true); // a >=5-key walk, trimmed
  expect(isLikelyGibberish("asdf")).toBe(false); // a bare 4-key walk defers to L3 (the >=5 floor)
  expect(isLikelyGibberish("   ")).toBe(false);
  expect(isLikelyGibberish("the asdf")).toBe(false);
  expect(isLikelyGibberish("学習")).toBe(false);
});
