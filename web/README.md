# Capecho — web (marketing site)

The public **marketing / landing site**. Separate from the apps — it ships no product code, and the
browser talks only to this site. Its one backend touchpoint is a **server-side** proxy
([`app/api/beta-signup/route.ts`](app/api/beta-signup/route.ts)) that forwards "Join the Mac beta"
waitlist emails to the Capecho backend (no CORS, no public write endpoint). Otherwise it's just the
site people land on, read, and download from.

**Stack:** [Next.js](https://nextjs.org) 16 (App Router) · React 19 · Tailwind CSS v4 · MDX
(`next-mdx-remote` + `gray-matter`) · `next-themes` (light/dark). Deploys to **Cloudflare Workers**
via the [OpenNext](https://opennext.js.org/cloudflare) adapter (`@opennextjs/cloudflare`).

## Run

This package is part of the pnpm workspace, so install from the repo root once:

```sh
pnpm install            # repo root — installs the whole workspace
cd web
pnpm dev                # http://localhost:3000
pnpm build              # production build
pnpm start              # serve the production build
pnpm lint
```

## Environment (beta-signup proxy)

`app/api/beta-signup/route.ts` forwards waitlist emails to the backend's `POST /beta-signup`. It reads
two server-only vars (never `NEXT_PUBLIC_*` — the browser must not see the token):

| Var | Required | Default | Notes |
| --- | --- | --- | --- |
| `BETA_SIGNUP_TOKEN` | **yes** | — | Shared secret the backend checks. **Unset ⇒ the route returns 503** (fail closed), so signups error instead of silently vanishing. Must MATCH the backend's `BETA_SIGNUP_TOKEN`. |
| `CAPECHO_BACKEND_URL` | no | `https://api.capecho.com` | Backend origin to forward to. |

- **Local dev:** put them in `web/.env.local` (gitignored), and run the backend locally (its own
  `BETA_SIGNUP_TOKEN` must match). With no token set, the form correctly shows its error state.
- **Production:** set the secret on the web Worker with `wrangler secret put BETA_SIGNUP_TOKEN`, and set
  the SAME value on the backend Worker. Apply the backend migration first
  (`cd ../backend && pnpm run migrate:remote`).

## Deploy (Cloudflare Workers)

The site ships to **Cloudflare Workers** through the [OpenNext](https://opennext.js.org/cloudflare)
adapter. Config: [`wrangler.jsonc`](wrangler.jsonc) (worker name, `nodejs_compat`, the `.open-next`
worker + assets binding) and [`open-next.config.ts`](open-next.config.ts) (caching — default for now).

```sh
pnpm install                 # repo root — installs the workspace
cd web
pnpm run preview             # build + run in the workerd runtime locally (≈ production)
pnpm run deploy              # build + deploy to Cloudflare
pnpm run cf-typegen          # regenerate cloudflare-env.d.ts after changing bindings
```

> Use `pnpm run deploy`, not `pnpm deploy` — the latter is a pnpm built-in, not this script.

Notes:
- A first deploy needs a Cloudflare account + `wrangler login` (or `CLOUDFLARE_API_TOKEN` in CI).
- `next dev` (`pnpm dev`) stays the fast inner loop; `preview` is the accurate Workers-runtime check.
- The build logs `ERROR Failed to copy …` for the MDX/remark dependency chain — a benign pnpm +
  OpenNext symlink quirk; those modules are still bundled into the worker.
- pnpm 10 blocks package build scripts by default. `deploy` (upload) doesn't need them, but if
  `pnpm run preview` can't find **workerd**, run `pnpm approve-builds` and allow `workerd` + `esbuild`.

## Structure

```
web/
  app/                 routes (App Router)
    page.tsx           home
    how-it-works/  ·  download/  ·  privacy/  ·  terms/
    blog/              blog index + blog/[slug]
    [slug]/            catch-all content pages
    feed.xml/  ·  sitemap.ts  ·  robots.ts
  content/blog/        the posts, as .mdx (authored by hand)
  components/          brand/ · marketing/ · ui/
  lib/                 helpers (mdx loading, etc.)
```

## Authoring posts

Add an `.mdx` file under [`content/blog/`](content/blog); it's picked up by the `blog/[slug]` route
(front-matter parsed with `gray-matter`). No code change needed for a new post.
