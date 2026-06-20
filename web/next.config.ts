import type { NextConfig } from "next";
import { initOpenNextCloudflareForDev } from "@opennextjs/cloudflare";

const nextConfig: NextConfig = {
  async redirects() {
    return [
      // Legal pages moved under /legal in the redesign (the /privacy route is now
      // the trust STORY; the formal policy lives at /legal/privacy-policy).
      { source: "/terms", destination: "/legal/terms", permanent: true },

      // SEO landing-page consolidation: 23 near-duplicate pages collapsed to 10
      // canonicals (one per keyword cluster) to clear Google's "Crawled – currently
      // not indexed" bucket. Each retired slug 301s into the canonical that absorbed
      // its angle + keywords, so inbound signals carry over. Keep in sync with
      // lib/landing-pages.ts — every source here MUST NOT be a live slug there.
      // Capture & OCR -> screen-vocabulary-capture
      { source: "/ocr-vocabulary-app", destination: "/screen-vocabulary-capture", permanent: true },
      { source: "/save-words-from-unselectable-text", destination: "/screen-vocabulary-capture", permanent: true },
      { source: "/screen-translate-to-flashcard", destination: "/screen-vocabulary-capture", permanent: true },
      // Notebook / tracker / cross-platform -> cross-platform-vocabulary-notebook
      { source: "/cross-platform-vocabulary-app", destination: "/cross-platform-vocabulary-notebook", permanent: true },
      { source: "/vocabulary-tracker", destination: "/cross-platform-vocabulary-notebook", permanent: true },
      // AI explanation -> ai-vocabulary-explanation
      { source: "/ai-word-meaning-in-context", destination: "/ai-vocabulary-explanation", permanent: true },
      { source: "/sentence-meaning-explanation", destination: "/ai-vocabulary-explanation", permanent: true },
      // Learn / in-context -> words-in-context
      { source: "/word-meaning-in-context", destination: "/words-in-context", permanent: true },
      { source: "/learn-vocabulary-in-context", destination: "/words-in-context", permanent: true },
      // Review / SRS -> micro-learning-vocabulary-app (kept slug, retargeted to SRS head term)
      { source: "/srs-vocabulary-app", destination: "/micro-learning-vocabulary-app", permanent: true },
      { source: "/review-words-on-the-go", destination: "/micro-learning-vocabulary-app", permanent: true },
      // Anki -> anki-alternative-for-vocabulary
      { source: "/anki-words-in-context", destination: "/anki-alternative-for-vocabulary", permanent: true },
      { source: "/anki-vocabulary-workflow", destination: "/anki-alternative-for-vocabulary", permanent: true },
    ];
  },
};

export default nextConfig;

// Lets `next dev` reach Cloudflare bindings via getCloudflareContext(); it is a
// no-op in the production build. See https://opennext.js.org/cloudflare.
initOpenNextCloudflareForDev();
