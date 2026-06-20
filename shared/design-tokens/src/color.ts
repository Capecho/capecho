export type Rgba = { r: number; g: number; b: number; a: number };

/** Parse a CSS color (#rgb, #rrggbb, #rrggbbaa, rgb()/rgba()). Returns null if not a color. */
export function parseColor(value: string): Rgba | null {
  const v = value.trim();
  let m: RegExpMatchArray | null;
  if ((m = v.match(/^#([0-9a-fA-F]{3})$/))) {
    const h = m[1]!;
    return { r: parseInt(h[0]! + h[0]!, 16), g: parseInt(h[1]! + h[1]!, 16), b: parseInt(h[2]! + h[2]!, 16), a: 1 };
  }
  if ((m = v.match(/^#([0-9a-fA-F]{6})$/))) {
    const h = m[1]!;
    return { r: parseInt(h.slice(0, 2), 16), g: parseInt(h.slice(2, 4), 16), b: parseInt(h.slice(4, 6), 16), a: 1 };
  }
  if ((m = v.match(/^#([0-9a-fA-F]{8})$/))) {
    const h = m[1]!;
    return { r: parseInt(h.slice(0, 2), 16), g: parseInt(h.slice(2, 4), 16), b: parseInt(h.slice(4, 6), 16), a: parseInt(h.slice(6, 8), 16) / 255 };
  }
  if ((m = v.match(/^rgba?\(([^)]+)\)$/i))) {
    const parts = m[1]!.split(",").map((s) => s.trim());
    if (parts.length < 3) return null;
    const r = Number(parts[0]), g = Number(parts[1]), b = Number(parts[2]);
    const a = parts.length >= 4 ? Number(parts[3]) : 1;
    if ([r, g, b, a].some((n) => Number.isNaN(n))) return null;
    return { r, g, b, a };
  }
  return null;
}

/** Dart Color(0xAARRGGBB) literal body. */
export function toArgbHex(c: Rgba): string {
  const hex = (n: number) => Math.round(n).toString(16).padStart(2, "0").toUpperCase();
  return `0x${hex(c.a * 255)}${hex(c.r)}${hex(c.g)}${hex(c.b)}`;
}

/** Round to a fixed number of decimals, trimming trailing zeros (stable codegen). */
export function f(n: number, dp = 4): string {
  return Number(n.toFixed(dp)).toString();
}
