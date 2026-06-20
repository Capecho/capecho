/**
 * Central site configuration — copy + navigation follow the product source-of-truth
 * (docs/product-definition.md). Capture is on the Mac (direct download + Mac App
 * Store); review is on the Mac and on the iPhone (App Store). Android is coming.
 *
 * NOTE: production domain is capecho.com. Override with NEXT_PUBLIC_SITE_URL.
 */
export const siteConfig = {
  name: "Capecho",
  category: "A privacy-first, context-first vocabulary tool that captures words off any screen",
  url:
    process.env.NEXT_PUBLIC_SITE_URL?.replace(/\/$/, "") ??
    "https://capecho.com",
  // The free-tier metered lever — SINGLE SOURCE OF TRUTH for all marketing copy.
  // MUST match the backend (CONTEXT_DAILY_CAP). Saving words is free and unlimited
  // (no library cap in the MVP — see docs/product-definition-frontier.md §9), so the
  // only number that appears in pricing copy is the daily in-context allowance.
  // Never hardcode the number in prose; interpolate `siteConfig.contextDailyCap`.
  contextDailyCap: 10,
  // Home meta (content-architecture §3.1).
  title: "Capecho — Capture words off any screen, review in context",
  description:
    "Capture the words you're reading off any screen — a PDF, a subtitle, an image, even text you can't select — understand each one in its own sentence with AI, and echo them back before they fade. Now on Mac and iPhone — capture on your Mac, review on your phone.",
  // The one canonical availability string — reuse verbatim everywhere.
  betaLine: "Now on Mac and iPhone — capture on your Mac, review on your phone.",
  tagline:
    "Capture words off any screen — even text you can't select — and echo them back before they fade.",
  links: {
    // macDownload is the live notarized DMG; the Mac App Store listing is also
    // live now (see appLinks.macAppStore) — both channels coexist.
    appStore: "https://apps.apple.com/us/app/capecho-context-vocabulary/id6771973675",
    macDownload: "https://download.capecho.com/capecho.dmg",
  },
  // Per-platform store / download links surfaced as footer badges + phone QR
  // codes. iOS + macOS are LIVE on the App Store (one listing, id6771973675);
  // Google Play / Microsoft Store stay "#" placeholders until those builds ship
  // (the footer greys an unset badge with a "Soon" tag — see get-app.tsx).
  appLinks: {
    iosAppStore: "https://apps.apple.com/us/app/capecho-context-vocabulary/id6771973675", // iPhone — App Store
    macAppStore: "https://apps.apple.com/us/app/capecho-context-vocabulary/id6771973675?platform=mac", // Mac — App Store (the direct DMG also lives at links.macDownload)
    googlePlay: "#", // Android — Google Play
    microsoftStore: "#", // Windows — Microsoft Store
  },
  // Operating party. During the free beta, Capecho is an INDEPENDENT PROJECT run
  // by an individual — no company is incorporated yet. One will be formed once
  // Capecho has steady revenue; at that point only these values change and the
  // footer + legal pages follow automatically. Until then we never claim a
  // registered entity (it does not exist yet, so claiming it would be false).
  legalEntity: "Capecho", // footer copyright line → "© <year> Capecho"
  operator: "Shawn (Xichuan Liu)", // the person who operates Capecho + its data controller
  contactEmail: "hello@capecho.com", // public contact — forwards to the founder's inbox
  // Google Analytics 4 measurement ID (gtag.js), wired site-wide in app/layout.tsx.
  // Loads in ALL environments while set — set to "" to disable, or gate to prod if
  // you don't want local/dev traffic in GA. Cookies/consent note: /legal/cookies.
  analyticsId: "G-GFVEZ7RJWD",
  // Regions where analytics consent is required (EEA + UK + Switzerland). GA4
  // Consent Mode v2 defaults analytics to DENIED here (the banner asks); every-
  // where else it defaults to GRANTED (auto-report). Used by app/layout.tsx +
  // components/consent-banner.tsx.
  consentRequiredRegions: [
    "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR",
    "HU", "IE", "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK",
    "SI", "ES", "SE", "IS", "LI", "NO", "GB", "CH",
  ],
} as const;

export type NavItem = { title: string; href: string; description?: string };

/** Top navigation — calm + flat; the primary CTA (Download for Mac) is separate. */
export const mainNav: NavItem[] = [
  { title: "How it works", href: "/how-it-works" },
  { title: "Privacy", href: "/privacy" },
  { title: "Blog", href: "/blog" },
];

/**
 * Footer sitemap — deliberately small: the core Product column plus one curated
 * Resources column. The fuller SEO internal-link graph now lives in on-page
 * content + sitemap.xml rather than a five-column footer wall.
 */
export const footerNav: { title: string; items: NavItem[] }[] = [
  {
    title: "Product",
    items: [
      { title: "How it works", href: "/how-it-works" },
      { title: "Privacy", href: "/privacy" },
      { title: "FAQ", href: "/faq" },
      { title: "Pricing", href: "/pricing" },
      { title: "Get Capecho", href: "/download" },
    ],
  },
  {
    title: "Resources",
    items: [
      { title: "About", href: "/about" },
      { title: "Contact", href: "/contact" },
      { title: "Blog", href: "/blog" },
      { title: "Anki alternative", href: "/anki-alternative-for-vocabulary" },
      { title: "Save words in context", href: "/save-words-in-context" },
      { title: "How to remember new words", href: "/how-to-remember-new-words" },
    ],
  },
];
