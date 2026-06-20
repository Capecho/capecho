import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { build, OUT_DIR } from "../src/generate.ts";

// The drift gate, as a test: the committed generated/ files must equal a fresh
// build from tokens.css. If this fails, run `bun run generate` and commit.
test("committed generated files have no drift from tokens.css", () => {
  const fresh = build();
  for (const [name, content] of Object.entries(fresh)) {
    const onDisk = readFileSync(join(OUT_DIR, name), "utf8");
    expect(`${name}:\n${onDisk}`).toBe(`${name}:\n${content}`);
  }
});

test("generation is deterministic", () => {
  expect(build()).toEqual(build());
});
