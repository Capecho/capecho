import { test, expect } from "bun:test";
import { parseColor, toArgbHex } from "../src/color.ts";

test("hex", () => {
  expect(parseColor("#644a40")).toEqual({ r: 100, g: 74, b: 64, a: 1 });
  expect(toArgbHex(parseColor("#644a40")!)).toBe("0xFF644A40");
});

test("rgba carries alpha", () => {
  const c = parseColor("rgba(100, 74, 64, 0.13)")!;
  expect(c).toEqual({ r: 100, g: 74, b: 64, a: 0.13 });
  expect(toArgbHex(c)).toBe("0x21644A40"); // round(0.13*255)=33=0x21
});

test("rgb without alpha", () => {
  expect(parseColor("rgb(255,255,255)")).toEqual({ r: 255, g: 255, b: 255, a: 1 });
});

test("non-colors return null", () => {
  for (const v of ["16px", "Fraunces, serif", "3px 3px 0 var(--app-edge)", "500", "65ch"]) {
    expect(parseColor(v)).toBeNull();
  }
});
