# @capecho/design-tokens

One source of truth for design tokens — `design/tokens.css` —
generated into platform code so the Flutter clients and the macOS native overlay
can't drift from the canonical token values (DES-2).

The generator reads **`tokens.css`** (not DESIGN.md prose), so foundation-level
fixes made in the CSS — e.g. the WCAG-legible language-picker active row
(`--ovl-active-fg`/`--ovl-active-bg`, XS-2) — flow through automatically.

## Outputs (`generated/`, committed)

| File | For |
|---|---|
| `tokens.json` | canonical extraction: `{ base, light, dark }` (complete — every var) |
| `capecho_tokens.dart` | `CapechoColors.light/.dark` (Color) + `CapechoDimens` (scalars) |
| `CapechoDesignTokens.swift` | `CapechoColors.light/.dark` + `CapechoDimens` |

Colors emit light + dark; mode-agnostic px/em/number tokens emit as scalars. Fonts,
shadows, and composite values are in `tokens.json` (typed Dart/Swift emission for
those is the next increment).

## Commands

```sh
bun run generate   # rewrite generated/ from tokens.css
bun run check      # CI drift gate — exits non-zero if generated/ is stale
bun test           # parser + color + drift + determinism
```

## Drift gate

`generated/` is committed and CI runs `bun run check`: if anyone edits `tokens.css`
without regenerating (or hand-edits a generated file), the build fails. Editing
tokens = edit `tokens.css` → `bun run generate` → commit both.
