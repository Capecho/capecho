import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowRight, ArrowUpRight } from "lucide-react";

import { siteConfig } from "@/lib/site";
import {
  getLandingPage,
  landingSlugs,
  landingPages,
} from "@/lib/landing-pages";
import { Container, Eyebrow } from "@/components/marketing/primitives";
import { Button } from "@/components/ui/button";
import { CtaSection } from "@/components/marketing/cta";
import { EchoMark } from "@/components/brand/echo-mark";

// Only the slugs we author render; anything else 404s.
export const dynamicParams = false;

export function generateStaticParams() {
  return landingSlugs().map((slug) => ({ slug }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>;
}): Promise<Metadata> {
  const { slug } = await params;
  const page = getLandingPage(slug);
  if (!page) return {};
  const url = `${siteConfig.url}/${page.slug}`;
  return {
    title: page.metaTitle,
    description: page.metaDescription,
    keywords: [...page.keywords],
    alternates: { canonical: `/${page.slug}` },
    openGraph: {
      type: "article",
      url,
      title: page.metaTitle,
      description: page.metaDescription,
    },
    twitter: {
      card: "summary_large_image",
      title: page.metaTitle,
      description: page.metaDescription,
    },
  };
}

export default async function LandingPageRoute({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
  const page = getLandingPage(slug);
  if (!page) notFound();

  const related = page.related
    .map((slug) => landingPages.find((p) => p.slug === slug))
    .filter((p): p is NonNullable<typeof p> => Boolean(p));

  const jsonLd = {
    "@context": "https://schema.org",
    "@type": "WebPage",
    name: page.metaTitle,
    description: page.metaDescription,
    url: `${siteConfig.url}/${page.slug}`,
    isPartOf: { "@type": "WebSite", name: "Capecho", url: siteConfig.url },
  };

  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />

      {/* Hero — left-aligned within a wide container so its left edge lines up
          with the two-column body and the related band below (DESIGN.md §9). */}
      <section className="pt-16 pb-4 sm:pt-24">
        <Container className="max-w-5xl">
          <Eyebrow>{page.eyebrow}</Eyebrow>
          <h1 className="max-w-3xl font-display text-4xl font-medium leading-[1.08] tracking-[-0.025em] text-foreground sm:text-5xl">
            {page.h1}
          </h1>
          <p className="mt-6 max-w-2xl font-serif text-xl leading-relaxed text-ink-2">
            {page.lede}
          </p>
          <div className="mt-8 flex flex-col gap-3 sm:flex-row">
            <Button asChild size="lg">
              <Link href="/download">
                Start capturing words
                <ArrowRight />
              </Link>
            </Button>
            <Button asChild size="lg" variant="secondary">
              <Link href="/how-it-works">See how the loop works</Link>
            </Button>
          </div>
        </Container>
      </section>

      {/* Body sections — two-column: a sticky heading rail (echo mark + title)
          beside the prose, so the page fills its width and reads editorially
          instead of a narrow column floating in whitespace. */}
      <section className="pb-16 pt-10 sm:pb-24">
        <Container className="max-w-5xl">
          <div className="space-y-10">
            {page.sections.map((section) => (
              <div
                key={section.heading}
                className="grid gap-x-10 gap-y-3 border-t border-border pt-9 md:grid-cols-[220px_minmax(0,1fr)]"
              >
                <h2 className="flex items-start gap-2.5 font-display text-2xl font-medium text-foreground md:sticky md:top-24 md:self-start">
                  <EchoMark className="mt-1 size-5 shrink-0 text-primary" />
                  {section.heading}
                </h2>
                <div className="max-w-[68ch] space-y-4">
                  {section.body.map((p, i) => (
                    <p
                      key={i}
                      className="font-serif text-lg leading-relaxed text-ink-2"
                    >
                      {p}
                    </p>
                  ))}
                </div>
              </div>
            ))}
          </div>
        </Container>
      </section>

      {/* Related */}
      {related.length > 0 && (
        <section className="border-t border-border bg-titlebar/50 py-14 sm:py-16">
          <Container className="max-w-5xl">
            <h2 className="mb-8 font-sans text-[11px] font-semibold uppercase tracking-[0.06em] text-ink-2">
              Keep exploring
            </h2>
            <div className="grid gap-4 sm:grid-cols-2">
              {related.map((rel) => (
                <Link
                  key={rel.slug}
                  href={`/${rel.slug}`}
                  className="group flex items-start justify-between gap-4 rounded-xl border border-border bg-card p-5 shadow-[var(--shadow-edge-soft)] transition-shadow hover:shadow-[var(--shadow-edge-soft-hover)]"
                >
                  <div>
                    <p className="font-display text-lg font-medium text-foreground">
                      {rel.h1}
                    </p>
                    <p className="mt-1 font-serif text-[15px] leading-snug text-ink-2">
                      {rel.lede}
                    </p>
                  </div>
                  <ArrowUpRight className="mt-1 size-5 shrink-0 text-ink-3 transition-colors group-hover:text-primary" />
                </Link>
              ))}
            </div>
          </Container>
        </section>
      )}

      <CtaSection />
    </>
  );
}
