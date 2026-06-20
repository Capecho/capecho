import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { parseTokensCss, camel } from "../src/parse.ts";
import { TOKENS_CSS } from "../src/generate.ts";

const maps = parseTokensCss(readFileSync(TOKENS_CSS, "utf8"));

test("base carries mode-agnostic scalars + fonts, no palette colors", () => {
  expect(maps.base["--space-4"]).toBe("16px");
  expect(maps.base["--ovl-radius"]).toBe("16px");
  expect(maps.base["--t-display-hero-size"]).toBe("56px");
  expect(maps.base["--font-display"]).toContain("Fraunces");
  expect(maps.base["--app-primary"]).toBeUndefined(); // colors live in light/dark
});

test("light + dark palettes split correctly", () => {
  expect(maps.light["--app-primary"]).toBe("#644a40");
  expect(maps.dark["--app-primary"]).toBe("#e6c49b");
  expect(maps.light["--ovl-accent"]).toBe("#644a40");
  expect(maps.dark["--ovl-accent"]).toBe("#e6c49b");
});

test("XS-2 token is present at the source (closed via tokens.css)", () => {
  expect(maps.light["--ovl-active-fg"]).toBe("#2c211a");
  expect(maps.dark["--ovl-active-fg"]).toBe("#f6efe6");
});

test("@media block did not pollute base/dark with duplicates or type tokens", () => {
  // type tokens are base-only; the @media dark block must not have leaked them into dark
  expect(maps.dark["--font-display"]).toBeUndefined();
  expect(maps.dark["--space-4"]).toBeUndefined();
  // dark must carry exactly the themed values, not a doubled set
  expect(maps.dark["--app-canvas"]).toBe("#221b17");
});

test("camelCase naming", () => {
  expect(camel("--app-primary")).toBe("appPrimary");
  expect(camel("--t-display-hero-size")).toBe("tDisplayHeroSize");
  expect(camel("--ovl-active-fg")).toBe("ovlActiveFg");
  expect(camel("--space-4")).toBe("space4");
});
