import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { parseTokensCss } from "./parse.ts";
import { emitJson, emitDart, emitSwift } from "./emit.ts";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..", ".."); // shared/design-tokens/src -> repo root
export const TOKENS_CSS = join(repoRoot, "design/tokens.css");
export const OUT_DIR = join(here, "..", "generated");

/** Build the generated file set in memory (the single source for both writing + drift-check). */
export function build(): Record<string, string> {
  const css = readFileSync(TOKENS_CSS, "utf8");
  const maps = parseTokensCss(css);
  return {
    "tokens.json": emitJson(maps),
    "capecho_tokens.dart": emitDart(maps),
    "CapechoDesignTokens.swift": emitSwift(maps),
  };
}

if (import.meta.main) {
  const check = process.argv.includes("--check");
  const files = build();
  mkdirSync(OUT_DIR, { recursive: true });
  let drift = false;
  for (const [name, content] of Object.entries(files)) {
    const path = join(OUT_DIR, name);
    if (check) {
      let existing: string | null = null;
      try { existing = readFileSync(path, "utf8"); } catch { existing = null; }
      if (existing !== content) {
        console.error(`DRIFT: generated/${name} is out of date — run \`bun run generate\``);
        drift = true;
      }
    } else {
      writeFileSync(path, content);
      console.log(`wrote generated/${name}`);
    }
  }
  if (check) {
    if (drift) process.exit(1);
    console.log("design-tokens: no drift ✓");
  }
}
