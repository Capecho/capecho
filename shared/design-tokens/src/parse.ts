// Parse design/tokens.css into base / light / dark token maps.
// The @media (prefers-color-scheme: dark) block duplicates the dark values for
// standalone viewing; it is removed before parsing so it can't pollute :root.

export type TokenMaps = {
  base: Record<string, string>;
  light: Record<string, string>;
  dark: Record<string, string>;
};

function stripComments(css: string): string {
  return css.replace(/\/\*[\s\S]*?\*\//g, "");
}

/** Remove every `@media ... { ... }` block (brace-balanced). */
function removeAtMedia(css: string): string {
  let out = "";
  let i = 0;
  while (i < css.length) {
    const at = css.indexOf("@media", i);
    if (at === -1) {
      out += css.slice(i);
      break;
    }
    out += css.slice(i, at);
    const open = css.indexOf("{", at);
    if (open === -1) break;
    let depth = 0;
    let j = open;
    for (; j < css.length; j++) {
      if (css[j] === "{") depth++;
      else if (css[j] === "}") {
        depth--;
        if (depth === 0) { j++; break; }
      }
    }
    i = j;
  }
  return out;
}

function parseDecls(body: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const decl of body.split(";")) {
    const idx = decl.indexOf(":");
    if (idx === -1) continue;
    const name = decl.slice(0, idx).trim();
    const value = decl.slice(idx + 1).trim();
    if (name.startsWith("--") && value.length > 0) out[name] = value;
  }
  return out;
}

export function parseTokensCss(css: string): TokenMaps {
  const cleaned = removeAtMedia(stripComments(css));
  const maps: TokenMaps = { base: {}, light: {}, dark: {} };
  const blockRe = /([^{}]+)\{([^{}]*)\}/g;
  let m: RegExpExecArray | null;
  while ((m = blockRe.exec(cleaned))) {
    const selector = m[1]!.trim();
    const decls = parseDecls(m[2]!);
    if (/\[data-theme="dark"\]/.test(selector)) Object.assign(maps.dark, decls);
    else if (/\[data-theme="light"\]/.test(selector)) Object.assign(maps.light, decls);
    else if (selector === ":root") Object.assign(maps.base, decls);
  }
  return maps;
}

/** `--app-primary` -> `appPrimary`, `--t-display-hero-size` -> `tDisplayHeroSize`. */
export function camel(name: string): string {
  return name
    .replace(/^--/, "")
    .split("-")
    .map((p, i) => (i === 0 ? p : p.charAt(0).toUpperCase() + p.slice(1)))
    .join("");
}
