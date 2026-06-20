import { defineCloudflareConfig } from "@opennextjs/cloudflare";
import staticAssetsIncrementalCache from "@opennextjs/cloudflare/overrides/incremental-cache/static-assets-incremental-cache";

// Every page is prerendered at build time — fully-static routes plus the SSG
// routes built with generateStaticParams (/[slug] landing pages, /blog/[slug]).
// There is no ISR / on-demand revalidation.
//
// With NO incrementalCache configured, the Cloudflare default cache always
// returns MISS, so the runtime can't find that prerendered output. Fully-static
// routes survived only because they re-render on demand; the generateStaticParams
// routes 404'd, because dynamicParams=false leaves nothing to fall back to. That
// is why the blog posts and the landing-page footer links were unreachable.
//
// The static-assets incremental cache serves the prerendered output straight
// from Workers static assets — no R2/KV binding required, which fits a fully
// prerendered marketing site. If we ever add ISR, switch to the R2 incremental
// cache (needs an R2 binding) — see https://opennext.js.org/cloudflare/caching.
export default defineCloudflareConfig({
  incrementalCache: staticAssetsIncrementalCache,
});
