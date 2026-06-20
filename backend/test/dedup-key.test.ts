import { test, expect } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { dedupKey, DEDUP_VERSION } from "../src/dedup-key.ts";

// The dedup key is deterministic + NOT a lemmatizer (T21): only trivial noise (case, NFC,
// whitespace, edge punctuation) collapses; inflections and homographs stay DISTINCT cards.

test("trivial noise collapses: case, trailing punctuation, internal whitespace", () => {
  expect(dedupKey("study")).toBe("study");
  expect(dedupKey("Study")).toBe("study");
  expect(dedupKey("study.")).toBe("study");
  expect(dedupKey("  study  ")).toBe("study");
  expect(dedupKey("out  of   the blue")).toBe("out of the blue"); // internal whitespace collapses
});

test("NO lemmatization — inflections and homographs are DISTINCT keys", () => {
  expect(dedupKey("saw")).not.toBe(dedupKey("see"));
  expect(dedupKey("studied")).not.toBe(dedupKey("study"));
  expect(dedupKey("ran")).not.toBe(dedupKey("run"));
  expect(dedupKey("gatas")).not.toBe(dedupKey("gato"));
});

test("NFC: combining vs precomposed diacritics produce ONE key", () => {
  const combining = "café"; // e + combining acute accent
  const precomposed = "café"; // é
  expect(combining).not.toBe(precomposed); // different code points...
  expect(dedupKey(combining)).toBe(dedupKey(precomposed)); // ...same dedup key
  expect(dedupKey(precomposed)).toBe("café");
});

test("phrases are preserved (no one-word constraint); edge punctuation stripped", () => {
  expect(dedupKey("out of the blue")).toBe("out of the blue");
  expect(dedupKey("¡Hola!")).toBe("hola");
  expect(dedupKey("«mot»")).toBe("mot");
});

test("diacritics + ß stay (letters); ß is NOT casefolded to ss (accepted simplification)", () => {
  expect(dedupKey("niño")).toBe("niño");
  expect(dedupKey("groß")).toBe("groß");
  expect(dedupKey("Straße")).not.toBe(dedupKey("Strasse")); // lowercase, not full casefold
});

test("numbers are kept (OCR digits / covid19); pure punctuation/space normalizes to empty", () => {
  expect(dedupKey("covid19")).toBe("covid19");
  expect(dedupKey("word2")).toBe("word2");
  expect(dedupKey("...")).toBe("");
  expect(dedupKey("   ")).toBe("");
});

test("DEDUP_VERSION is set (the cache-key re-key axis)", () => {
  expect(DEDUP_VERSION.length).toBeGreaterThan(0);
});

test("matches the shared cross-port parity fixture (the macOS client asserts the same JSON)", () => {
  // NFC-stable vectors both `dedupKey` (TS) and `localDedupKey` (Dart) must reproduce identically — the
  // drift guard for the two hand-ported normalizers (same pattern as junk_gate_vectors.json).
  const path =
    [
      `${import.meta.dir}/../../shared/capture-core/test/fixtures/dedup_key_vectors.json`,
      "../shared/capture-core/test/fixtures/dedup_key_vectors.json", // cwd = backend
      "shared/capture-core/test/fixtures/dedup_key_vectors.json", // cwd = repo root
    ].find((p) => existsSync(p)) ?? null;
  if (path === null) throw new Error("dedup_key_vectors.json not found");
  const { cases } = JSON.parse(readFileSync(path, "utf8")) as { cases: { in: string; out: string }[] };
  expect(cases.length).toBeGreaterThan(0);
  for (const c of cases) expect(dedupKey(c.in)).toBe(c.out);
});
