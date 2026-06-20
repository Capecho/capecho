# Capecho Web — Design System

> **What this is:** the visual source of truth for the Capecho **marketing site** (`web/`, Next.js).
> It defines art direction, color, type, the hero pattern, section patterns, motion, components, states,
> and utility surfaces — the *how it looks* layer for the site.
>
> **Relationship to the app:** the root [`DESIGN.md`](../DESIGN.md) is the **app** design system
> (Caffeine + warm-glass). This doc **inherits** its palette, type, and the echo-mark, then takes more
> freedom for the web. When a shared token's value is in question, the canonical
> [`design/tokens.css`](../design/tokens.css) and the app system win.
> Token **names** on the web are the ones already wired in [`web/app/globals.css`](app/globals.css) (the
> `--app-*` set + shadcn aliases + Tailwind `text-ink-2` / `bg-canvas` / `text-primary` utilities) — this doc
> uses those, never invented names. See the mapping table in §14.
>
> **Status (2026-06-03):** the **hero is locked** (V4.2, light + dark, follow-system) for *composition*. Three
> copy/legal honesty fixes to the locked mockup are pending and flagged in §4 (they supersede the aesthetic
> lock). Section patterns below are derived from it and applied + dual-reviewed (/codex + Claude subagent)
> section by section. This revision incorporates the first dual review.

---

## 0. The one memorable thing

**The loop: capture → echo.** A reader should leave the page *feeling* a word lifted off what they were
reading and come back to them before it faded. Every decision serves that loop. Design that tries to be
memorable for everything is memorable for nothing — so the capture scene and the echo are where we spend the
**boldness budget**, and everything else stays calm.

This is why the hero is a **real capture scene on real devices**, not an abstract graphic, and why the
**))) echo-mark** is the one recurring signature.

> **One bold peak.** The boldness budget has a single peak: **the loop section (§5)**. The hero is *rich* but
> composed; the "problem" band is *quiet* setup, not a second crescendo. If two sections both shout, neither
> is memorable.

---

## 1. Posture — aligned with the app, freer on the web

The web is **the same warm world as the app, given room to breathe**. Not a 1:1 reskin of the app UI.

- **Inherits** from the app: the warm coffee/cream palette, Charter (body) + the Fraunces `Capecho.` wordmark, the
  `)))` echo-mark and its disambiguation rule, the stacked-paper card shadow.
- **Takes web freedom:** larger display type, more negative space, **editorial composition** (chapter rails,
  asymmetry, full-bleed bands), and **photoreal device heroes**. The feel is a literary magazine that happens
  to ship software — premium by restraint, not by decoration.
- **Premium ≠ loud.** No gradients for their own sake, no glassmorphism everywhere, no stock-AI sheen. The
  richness comes from type, paper, one accent, and one real scene.

---

## 2. Color — two themes, follow-system

### 2a. Theme mechanism (how light/dark actually works)

- **Production (`web/`):** **next-themes** drives a **`.dark` class** on `<html>` (`globals.css` already binds
  Tailwind's dark variant to it: `@custom-variant dark (&:is(.dark *))`). Configure the provider
  `defaultTheme="system"` + `enableSystem` — **that** is "follow-system." A header toggle (§11) can override to
  light/dark and persists the choice.
- **Hand-authored mockups:** use the `tokens.css` convention instead — `:root`/`[data-theme="light"]` light,
  `[data-theme="dark"]` dark, plus a `prefers-color-scheme` block so a standalone file follows the OS. Same
  values, different switch. Don't ship `data-theme` to production; wire next-themes.

### 2b. Page palette — *theme-aware* (flips with the OS / `.dark`)

Site chrome: background, body text, headings, nav, buttons, rules, bands, ledgers, tables. **Use the existing
tokens** (CSS var → Tailwind utility; all already in `globals.css`):

| Concept | CSS var | Tailwind | Light | Dark |
|---|---|---|---|---|
| page canvas | `--background` / `--app-canvas` | `bg-background` / `bg-canvas` | `#f6f3ef` | `#221b17` |
| primary text | `--foreground` / `--app-ink` | `text-foreground` / `text-ink` | `#2b2320` | `#f0e9e0` |
| secondary text | `--app-ink-2` | `text-ink-2` | `#6b5d54` | `#c3b4a6` |
| muted **(non-text only)** | `--app-ink-3` | `text-ink-3` | `#a2958a` | `#8d7e71` |
| hairline / border | `--app-line` / `--border` | `border-border` | `#ece5dc` | `#3a302a` |
| **brand accent** (coffee→latte) | `--primary` / `--app-primary` | `text-primary` / `bg-primary` | `#644a40` | `#e6c49b` |
| on-accent text | `--primary-foreground` | `text-primary-foreground` | `#fff` | `#2b1f18` |
| chip / in-text highlight | `--app-chip` | `bg-chip` | `#ffdfb5` | `rgba(230,196,155,.16)` |
| chip text | `--app-chip-fg` | `text-chip-foreground` | `#582d1d` | `#e6c49b` |
| focus ring | `--ring` (= `--app-primary`) | `ring-ring` | coffee | latte |

> **Naming trap (do not repeat):** the brand accent is **`--primary`**, *not* `--accent`. In `globals.css`
> `--accent` is the **soft wash** (`--app-primary-soft`, a 13–18% coffee tint for hovers) — using it for a
> button or the em-word gives a near-invisible result. Coffee = `--primary` / `text-primary`.

### 2c. Device palette — *theme-aware* (mirrors the app's light/dark)

The screens **inside** the device heroes (the Mac's article, the warm-glass overlay, the phone's review card)
**flip with the page** — a dark-mode visitor sees the product as it *actually* looks at night, not a bright
slab on an espresso page. The device scene keeps its **own token set** (so it can't accidentally pick up a
page-chrome value), but those tokens now carry light values in `:root` and the espresso dark values under
`.dark`, byte-mirroring the app's own dark tokens:

```css
/* device-scene tokens — light in :root, espresso under .dark (mirror app dark) */
:root {
  --device-canvas:#f6f3ef; --device-card:#fff;
  --device-coffee:#644a40; --device-chip:#ffdfb5; --device-chip-fg:#582d1d;
  --device-ovl-tint:rgba(247,243,237,.92); --device-ovl-ink:#241c17;
  --device-ovl-ink-2:#6a5b50; --device-ovl-rule:rgba(62,45,34,.28); --device-ovl-accent:#644a40;
}
.dark {
  --device-canvas:#221b17; --device-card:#2c241f;
  --device-coffee:#e6c49b; --device-chip:rgba(230,196,155,.18); --device-chip-fg:#e6c49b;
  --device-ovl-tint:rgba(31,24,19,.92); --device-ovl-ink:#f1eae0;
  --device-ovl-ink-2:#b6a698; --device-ovl-rule:rgba(240,233,224,.2); --device-ovl-accent:#e6c49b;
}
```

> Dark values byte-mirror the app's espresso tokens (`globals.css` / `tokens.css`), not hand-picked.
> **Still forbidden:** wiring a device scene to the flipping `--app-*` / `--primary` page tokens directly —
> route everything through the `--device-*` set so the scene stays a self-contained, swappable palette.
> The accent flips coffee→latte *inside* the device too (it's a real screenshot of the latte-accent dark app).

**Physical parts stay dark.** Only the *screen content* flips. The MacBook lid/bezel, the aluminum deck, the
phone frame and the notch/island are physical hardware — they stay dark in both modes, which is also what
gives the dark-mode device its edge against the espresso page (lid bezel + deck + contact shadow = the lift).

### 2d. Palette assignment — the edge-case classifier (resolve every surface)

To kill "which palette?" ambiguity:

- **Page palette (flips):** nav, hero text, all section copy/headings, **CTA band**, **comparison table**,
  **privacy ledger**, **what's-free ledger**, FAQ teaser, footer, the "why context" comparison card, any
  in-prose chip/highlight, buttons, forms.
- **Device palette (theme-aware §2c):** *only* what is rendered **inside a device frame** — the Mac article +
  warm-glass overlay, the phone review card and its chrome. It flips light/dark like the page, but stays a
  self-contained `--device-*` set. A saved-word card shown **outside** a device frame is **page palette** (it's
  an editorial illustration; both palettes flip, so the distinction is now about token vocabulary, not whether
  it flips).

### 2e. Semantic (shared with the app)

`--success #5a6a48` · `--warning #a8741e` · `--error #8a2a1e` · `--info #4a5a6a` (constant in both modes). Used
sparingly (form states, the quota note), and **always paired with text/icon, never color alone** — `--error`
oxblood on the espresso page is low-contrast as a fill. The beta/quota framing stays **calm**, never alarm-red.

### 2f. Contrast law (non-negotiable)

Measured ratios: `--ink-2` passes everywhere (light **5.72:1**, dark **8.41:1**). `--ink-3` **fails AA for
text** — light `#a2958a` on `#f6f3ef` = **2.64:1** (fails even the 3:1 large/UI bar), dark `#8d7e71` on
`#221b17` = **4.33:1** (fails the 4.5:1 body bar).

> **Rule:** `--ink-3` is **text-illegal below 18px** — never use it for trust microlines, kickers, ordinals,
> the quota counter, labels, links, or a ghost-button border. Route all of those to **`--ink-2`**. `--ink-3`
> is allowed only for **pure ornament/hairlines** or large (≥24px) numerals. (This mirrors the app's own rule:
> overlay eyebrows use `--ovl-ink-2`, *never* `--ovl-ink-3`.)

---

## 3. Typography

Three serif/mono roles plus chrome, each a different voice. **Never** mix the display serif into UI chrome or
the mono into prose. Families: `--font-display` / `--logo` **Fraunces** (one display serif: web headings + the
`Capecho.` wordmark + the in-device app UI), `--font-serif` Charter→Source Serif 4 (body), `--font-sans` system
(chrome), `--font-mono` JetBrains Mono (data).

- **Display — Fraunces** (variable `opsz`, web headings + wordmark + device UI). Hero + section headings, weight
  **500**, `letter-spacing -.018em`, `opsz 72`. One **em-accent word** per hero in `text-primary`. *Unified to
  Fraunces (founder call, 2026-06-12):* the web previously used Fraunces for headings, which made it read as a
  separate brand from the app. One display serif now spans the wordmark, hero, section headings, and the in-device
  app UI, so the web reads as the same product as the macOS/iOS app. Swap is one `--font-display` line.
- **Body — Charter → Source Serif 4 → Georgia.** Reading copy, ledes, card sentences. `16–18px`, `line-height
  1.6`, secondary copy in **`--ink-2`** (not ink-3).
- **Chrome — system sans.** Nav, buttons, form fields, table chrome, footer links. `14–15px`, weight `500–600`.
- **Data / marginalia — JetBrains Mono.** Kickers (uppercase, tracked), trust microlines, chapter ordinals
  (`§ 01 — Capture`), card meta (`№ 112`, `DUE TODAY`), IPA, the quota counter. **Mono = the machine speaking.**
  All mono *text* uses **`--ink-2`** per §2f. Kicker tracking `.14–.22em` on desktop; **cap at `.08em` below
  640px** so small mono doesn't shred.

**Scale:** kicker `11.5–12` · body `16–18` · H2 `clamp(26,3vw,38)` · hero word `clamp(60,11vw,150)`. Hero
line-height `1.0–1.12`; section headings `1.1`.

---

## 4. The hero pattern (LOCKED — V4.2, composition)

Shared skeleton; only the heading + scene specialize.

1. **Mono kicker** — expresses the loop **without present-tense phone claims**, e.g.
   `CAPTURE ON YOUR MAC · REVIEW BEFORE THEY FADE`. (See honesty fixes below.)
2. **Fraunces headline**, centered, one **em-accent word** ("echo") in `text-primary`. Calm, literary.
3. **CTAs** — primary **Join the Mac beta** (`bg-primary`), secondary **See how it works** (ghost, §8).
4. **Mono trust microline** (`--ink-2`) — `LOCAL-FIRST RECOGNITION · REVIEW BEFORE SAVING · SENSITIVE DETAILS CAN BE MASKED`.
5. **Canonical beta line** (required, `--ink-2`) — *"Mac beta first — the phone review companion is coming."*
6. **The device stage** (the art): a **real MacBook** (wide notch + camera, glare, aluminum deck) showing a
   **real capture scene** — an article with one word highlighted + the **warm-glass overlay** open — beside a
   **real iPhone** (titanium frame, realistic status bar) showing the **review card** (word centered lower-half,
   `Forget / Hard / Good / Easy`). Device screens use the **theme-aware device palette** (§2c).

**Rules:** the capture scene **is** the art (no floating/abstract echo graphic — removed in V4.2). The MacBook
proves *capture*, the iPhone proves *echo*; the two devices literally are the loop.

> **Honesty fixes pending on the locked mockup (supersede the aesthetic lock — flagged by the dual review):**
> 1. **Kicker** currently reads `REVIEW ON YOUR PHONE` (present tense) → change to a non-present-tense loop
>    line (above). The phone is *coming*.
> 2. **Phone "coming" affordance** — the iPhone in the scene can imply shipped mobile. Add a small, calm
>    `COMING` tag on/under the phone (mono, `--ink-2`), and keep the §4.5 beta line visible. The phone shows
>    the *vision*, the copy stays honest.
> 3. **Masthead is "The Atlantic"** → replace with a **fictional / founder-authored masthead** (e.g. an
>    invented literary-magazine name) styled editorially. Using a real publication's name + styling is a
>    trademark / passing-off risk.

---

## 5. Section patterns

Home order is defined here. Each names its
palette (all **page palette** per §2d unless it's inside a device) and an **approved shape** so it can't drift
into slop.

- **Chapter rail** — thin hairline (`--app-line`) + mono ordinal (`§ 02 — The problem`) in **`--ink-2`**. The
  editorial spine.
- **The problem** — *quiet* setup: one Fraunces line on lots of canvas, `--ink-2` lede, no product. Smaller and
  calmer than the loop (it is not the bold peak).
- **The loop (capture → echo)** — **the signature section, the boldness peak.** Three editorial steps
  (capture · understand · review) connected by the **echo-mark** (the *one* animated echo: a single ripple
  expansion on scroll-in, reduced-motion respected). *Approved shape:* a horizontal/stepped sequence with the
  echo-mark as connective tissue — **not** three equal feature cards.
- **Why context** — *show, don't tell:* a saved card (your own sentence, highlighted word in `bg-chip`) beside
  a flat dictionary line. **The card shows word-level explanation + your sentence only** — *not* the metered
  in-context gloss (keep it free-layer so it carries no paywall framing). Page palette (it's outside a device).
- **Features** — *Approved shape:* an **editorial definition-list or asymmetric 2-up**, words first, **no
  icon-per-feature, no 3-column icon grid** (the old slop). Six capabilities.
- **Where it fits** — *Approved shape:* a quiet comparison **table**, `--app-line` rules, `--ink-2` cells, the
  Capecho row marked with a restrained `text-primary` label (not a loud highlight fill). Framed as
  *complement*, not *replacement* (esp. Anki).
- **Privacy ledger** — *Approved shape:* two columns, mono labels (`--ink-2`) + serif values — **what never
  leaves** (the screen image) beside **what's kept** (confirmed word + context + explanation + review history +
  the small settings). Both halves always.
- **What's-free ledger** — same ledger shape: **free & unmetered** beside **metered** (the *optional* in-context
  explanation, **10/day free**). Reassures; never reads as a paywall.
- **FAQ teaser** — 3–4 mono-numbered questions → `/faq`.
- **CTA band** — *Approved shape:* a **tinted page-palette panel** (`--background` shifted / `--app-primary-soft`
  wash, `--app-line` top border), Fraunces *Join the Mac beta*, the button in `bg-primary`. **Not** a full-bleed
  `bg-primary` slab — in dark that becomes a glaring latte panel and breaks "premium ≠ loud."
- **CTA cadence (founder note — don't wall the page in identical buttons)** — at most **one** primary
  *Join the Mac beta* per page (in the hero) **plus** this closing band. Mid-page repeats are recast as
  **secondary text links** (e.g. *Read the privacy model →*). The persistent **header** CTA reads **Get Capecho**
  (a quiet nav action, not a third identical button). `/download` carries only its **signup form** — no closing band.
- **Footer band** — the SEO link surface (§1 groups), page palette, mono group labels in **`--ink-2`**,
  system-sans links (§8 link states).

---

## 6. The echo-mark `)))`

Three concentric arcs opening rightward. Geometry is **regenerated from the app's `_EchoPainter`**
(`shared/app-core/lib/src/design/chrome.dart`) — the *current* mark:

```html
<!-- viewBox "3 6 27 16" (left-padded so the innermost C never clips), stroke=currentColor, no fill, round caps -->
<path d="M22.17 19.88 A 8.13 6.25 0 0 1 22.17 8.13"/>
<path d="M14.17 18.63 A 6.25 5.13 0 0 1 14.17 9.38"/>
<path d="M7.30 16.5  A 2.88 2.88 0 0 1 7.30 11.5"/>
```

> **Don't copy the SVG in the app `DESIGN.md`** — that one (`viewBox "0 0 22 22"`) is the older hand-drawn mark
> and is now stale relative to `_EchoPainter`. Use the geometry above. (App-doc reconciliation tracked
> separately.)

- **Color is per-context:** on the **page** (nav wordmark, loop section, footer) it's `text-primary` (flips
  coffee↔latte). **Inside a device** scene it's `--device-coffee`, which now flips coffee↔latte too (§2c) — the
  device is a real screenshot of the latte-accent dark app.
- **Disambiguation (inherited):** **static = memory state; motion = working/syncing.** On the web motion is
  **rare** — the only animated echo is the loop section's beat. Everywhere else it is still.
- Wordmark is always **`Capecho.`** with the period in `text-primary`.

---

## 7. Motion

Restrained; **`prefers-reduced-motion` always respected** (disable all of the below when set).

- **Allowed:** gentle scroll-reveal (opacity + 8–12px translate), the loop's **one** echo ripple, button/card
  hover lift, the sticky header condensing on scroll.
- **Never:** parallax, autoplay video, looping background motion, springy/bouncy easing, count-up numbers,
  carousels. Easing `ease-out`, 180–260ms.

---

## 8. Components

- **Buttons** — primary: `bg-primary` / `text-primary-foreground`, radius **`--radius-sm` (8px)**, system-sans
  `14–15` weight `500–600`. Carry a **soft warm elevation** (`--shadow-btn` — a low two-layer drop shadow, warm
  ink in light / black in dark) that **lifts** on `:hover` (`-translate-y-px` + the deeper `--shadow-btn-hover`,
  `brightness 1.02`) and **sinks** on `:active` (`translate-y-px` + the minimal `--shadow-btn-press`),
  `:focus-visible` ring. The marketing site **deliberately drops the app's hard stacked-paper button edge** here —
  the soft elevation reads cleaner against the editorial type (the hard `--shadow-edge*` tokens stay defined for the
  card motif below). Secondary: `--app-card` ground, `1px --app-line` border, same soft elevation. Ghost:
  transparent, `1px` **`--ink-2` or `--app-line`** border (never `--ink-3` — fails the 3:1 boundary). Sizes:
  default `11px 19px`, lg `13–14px 22–24px`.
- **Cards** — `--app-card` ground, `1px --app-line`, radius `--radius` (11px). **Light:** stacked-paper
  double-edge shadow (`--shadow-edge`, `--shadow-edge-soft`). **Dark:** reuse **`--shadow-edge-soft`** (the
  inherited token is defined for dark in `globals.css`) — name it, don't say "a soft deep shadow." The capture
  card may sit at `~2°` rotation (it's a clipping, not a UI panel).
- **Chip / highlight** — `bg-chip` / `text-chip-foreground`, radius `--radius-sm` derived (3–8px), `0 4px`
  padding. How a word is highlighted *in its sentence* — the visual rhyme of "save the context."
- **Beta email form field** (the #1 conversion element — `/download` + every CTA band): one `<input type=email>`
  with a **real `<label>`** (visually-hidden ok), `--app-card` ground, `1px --app-line` (focus → `ring-ring`),
  radius `--radius-sm`, height ≥44px, placeholder in `--ink-2` (not ink-3). Inline submit button (`bg-primary`).
  States in §10.
- **Links** (§10 covers states) — body links `text-primary` with underline-on-hover; footer/nav links
  `--ink-2` → `--ink` on hover; visible `:focus-visible` ring; set `:visited` so it doesn't fall back to browser
  blue.
- **Device frames** — MacBook (lid bezel, wide notch + camera, glare, aluminum deck) and iPhone (titanium
  frame, realistic status bar: ascending signal bars, wifi, outlined battery). Reusable; contents vary per page.
  Contact shadow `--contact`/`--window-ambient` (theme-aware) + the §2c dark-lift rim.

---

## 9. Layout & responsive

- Content max-width `~1100–1240px`; side padding `44–48px` desktop, `20–24px` mobile.
- Editorial asymmetry is fine (chapter rail, off-center ledes), but keep one consistent left margin so the page
  reads as a column, not a scatter.
- **Mobile:** nav collapses to a menu, **the CTA stays visible**; the device stage stacks (Mac above phone, or
  phone-only on the smallest); type scales via the `clamp()`s in §3; kicker tracking caps per §3.

---

## 10. States & interaction (don't ship a happy-path-only design)

- **Beta form:** *idle* → *focus* (`ring-ring`) → *submitting* (button shows a quiet echo-ripple spinner, field
  disabled) → *success* (the field swaps to a calm confirmation: *"You're on the list — we'll email a signed
  download link when your spot opens,"* `--success` + text) → *error* (`--error` + text, field re-enabled,
  message is human, never a raw code) → *already-on-list* (friendly, not an error).
- **Link/interaction states:** define `:hover`, `:focus-visible`, `:active`, `:visited`, and nav **active**
  (current page) for every link; never rely on color alone (add underline/weight).
- **Sticky header condensed state:** on scroll, height shrinks (≈72→`56px`), a `--app-line` bottom hairline +
  faint `--background` blur appear, the wordmark stays, the CTA stays; the §11 theme toggle stays reachable.
- **Loading / empty:** blog, FAQ, and SEO lists get a calm skeleton (paper-toned blocks), and a real **empty
  state** (e.g. a category with no posts) rather than a blank region.

---

## 11. Utility & brand surfaces

- **404 / not-found:** page palette, the echo-mark, a one-line warm message, links to the core pages + **Join
  the Mac beta**. Not a jokey 404.
- **OG / social share image:** the locked **hero device scene** (light), the `Capecho.` wordmark + echo-mark,
  one-line value prop. One template, per-page title overlaid. (`globals.css` + metadata wire it.)
- **Favicon / app icon (site):** the **echo-mark** in `text-primary` on `--background`, light + dark variants;
  the wordmark period is the alternate monogram. Distinct from the macOS app icon.
- **Theme toggle control:** a small header control. Default = **system**; clicking sets light or dark and
  persists (next-themes). Reconcile with §2a "follow-system default": system is the default, the toggle is an
  override. Icon-only (sun/moon), labelled for SR.
- **Cookie / consent:** **no banner** — there are no third-party trackers/analytics in the build (this *is* a
  privacy claim, §privacy). If analytics is ever added, the consent UI lands here and the claim changes.

---

## 12. Accessibility

- **Contrast law §2f is binding** — `--ink-3` is text-illegal; `--ink-2` is the floor for any reading text in
  both themes (verified 5.72 / 8.41).
- IPA + mono data **labelled for screen readers** (mirrors the app's DR4 IPA a11y) — don't let `/ˈwɜːd/` read as
  noise.
- Visible focus rings (`:focus-visible`, never `outline:none` without a replacement). Device scenes carry
  descriptive **alt text** (they hold the product story). Decorative echo ripples are `aria-hidden`.
- Reduced-motion disables all of §7. Forms: real labels, semantic state colors **+ text**.

---

## 13. Anti-patterns + positive fences

**Banned (these made the old site "slop"):**
- A centered badge + a **3-column icon grid** of features; **icon-per-feature** anywhere.
- Stock-AI gradients, glassmorphism everywhere, neon-on-dark "tech" sheen; **glossy 3D device templates**
  (devices are photoreal, not rendered toys).
- Manufactured urgency (countdowns, "limited spots", fake live counters).
- **Etymology as a headline** — demand rank #15, dead last; not on the marketing site at all (CLAUDE.md).
- Present-tense **"review on your phone"** — the phone companion is *coming*.
- A disabled/placeholder **"Download for Mac"** button — the CTA is **Join the Mac beta** until the binary ships.
- **Full-bleed `bg-primary` panels in dark** (the latte slab).

**Positive fences (the approved replacements — use these so "editorial" can't genericize):**
- **One accent moment per section** — `text-primary` is a guest, not the wallpaper.
- Features = **editorial definition-list / asymmetric 2-up** (§5), words first.
- Comparison = **quiet table** with a restrained `text-primary` Capecho row (§5).
- CTA = **tinted page-panel band**, accent only on the button (§5).
- Privacy + pricing = the **two-column ledger** shape (§5).
- Devices = **photoreal frames** (§8) with the theme-aware device palette (§2c).

---

## 14. Implementation notes

- **Token vocabulary:** use the names in §2b (already in `web/app/globals.css`: the `--app-*` set, shadcn
  aliases, and the `@theme inline` Tailwind utilities `text-ink` / `text-ink-2` / `text-ink-3` / `bg-canvas` /
  `text-primary` / `bg-chip` / `text-chip-foreground`). **Add only:** the theme-aware `--device-*` set (§2c) and
  the hero `clamp()` type scale (§3). Not a token rewrite. Brand accent = **`--primary`**, never `--accent`.
- **Theme:** wire **next-themes** (`.dark`, `defaultTheme="system"`, `enableSystem`) + the §11 toggle. The
  `data-theme` mechanism is mockup-only.
- **Reference:** the locked **V4.2 hero mockup** (hand-authored HTML, light + dark) is the 1:1 build reference —
  *with* the three §4 honesty fixes applied (kicker, phone "coming" tag, fictional masthead).
- **IA dependency:** `sitemap.xml` / `robots.txt` / RSS must follow the rationalized §5 IA from the content doc
  (16 SEO pages, the 301 map), not the old 24.
- **Precedence:** this doc owns the *look*; the product spec owns the
  product facts. On conflict, product facts win.
