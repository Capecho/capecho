import type { Metadata } from "next";
import Link from "next/link";

import { Container } from "@/components/marketing/primitives";
import { siteConfig } from "@/lib/site";

export const metadata: Metadata = {
  title: "Cookies & Analytics",
  description:
    "How the Capecho website uses analytics: Google Analytics 4 for aggregate traffic, no advertising, no cross-site tracking, no selling. The Capecho app has no third-party analytics.",
  alternates: { canonical: "/legal/cookies" },
};

const sections: { h: string; p: string[] }[] = [
  {
    h: "The short version",
    p: [
      "This website uses Google Analytics 4 (GA4) to understand aggregate traffic — how people find Capecho and which pages actually help them understand it. That's the only analytics here. We do not run advertising, ad-targeting, or cross-site tracking, and your data is never sold.",
    ],
  },
  {
    h: "What GA4 sets",
    p: [
      "Once you accept, GA4 sets a small number of first-party analytics cookies (for example _ga) so it can count visits and sessions without double-counting the same browser. These are used to measure the site in aggregate, not to build an advertising profile of you. If you decline, these cookies are not set.",
    ],
  },
  {
    h: "What we don't use",
    p: [
      "No advertising or retargeting cookies. No social-media pixels. No cross-site trackers, no fingerprinting, and no selling or sharing of your data with data brokers. Analytics here exists to improve the site, nothing more.",
    ],
  },
  {
    h: "The app vs. the website",
    p: [
      "Analytics live on this marketing website only. The Capecho Mac app contains no third-party analytics or trackers in the capture path. Your captured words and context sentences are never used for advertising — see the plain-language privacy story for exactly what the app reads, discards, and keeps.",
    ],
  },
  {
    h: "Your choices",
    p: [
      "Analytics load only with your consent. The first time you visit, a banner lets you Accept or Decline, and analytics stay off by default until you choose (Google Consent Mode v2). You can change your mind by clearing this site's cookies and storage, and you can also block cookies in your browser or send a Do Not Track signal. The site stays fully functional either way — nothing here depends on analytics to work.",
    ],
  },
  {
    h: "Contact and changes",
    p: [
      `This website is operated by ${siteConfig.operator}, the maker of Capecho. Questions about cookies or analytics can be sent to ${siteConfig.contactEmail}.`,
    ],
  },
];

export default function CookiesPage() {
  return (
    <section className="pb-16 pt-14 sm:pt-20">
      <Container className="max-w-2xl">
        <div className="mb-4 font-mono text-xs uppercase tracking-[0.18em] text-ink-2">
          Legal
        </div>
        <h1 className="font-display text-4xl font-medium tracking-[-0.02em] text-foreground sm:text-5xl">
          Cookies &amp; Analytics
        </h1>
        <p className="mt-5 font-mono text-xs uppercase tracking-[0.14em] text-ink-2">
          Effective June 16, 2026
        </p>
        <p className="mt-4 font-sans text-sm text-ink-2">
          The plain-language trust story is on the{" "}
          <Link
            href="/privacy"
            className="text-primary underline-offset-2 hover:underline"
          >
            privacy page
          </Link>
          .
        </p>
        <div className="mt-10 space-y-10">
          {sections.map((s) => (
            <div key={s.h}>
              <h2 className="font-display text-2xl font-medium text-foreground">
                {s.h}
              </h2>
              {s.p.map((para, i) => (
                <p
                  key={i}
                  className="mt-4 font-serif text-[17px] leading-relaxed text-ink-2"
                >
                  {para}
                </p>
              ))}
            </div>
          ))}
        </div>
      </Container>
    </section>
  );
}
