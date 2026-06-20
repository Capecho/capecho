import Link from "next/link";

import { Button } from "@/components/ui/button";
import { Container } from "@/components/marketing/primitives";
import { EchoMark } from "@/components/brand/echo-mark";
import { siteConfig } from "@/lib/site";

/** Three concrete reassurances — concrete enough to answer "what do I get?". */
const POINTS = ["On-device OCR", "Free core loop", "Anki & CSV export"];

/**
 * Closing CTA band (web/DESIGN.md §5). A tinted page-palette panel — accent only
 * on the button, NOT a full-bleed bg-primary slab (which becomes a glaring latte
 * panel in dark). Carries an echo-mark grace note, one serif value line, the
 * primary download + a secondary text link (§5 CTA cadence), the three core
 * reassurances, and the one canonical availability line.
 */
export function CtaSection({
  title = "Download Capecho for Mac.",
}: {
  title?: string;
}) {
  return (
    <section className="reveal py-16 sm:py-24">
      <Container>
        <div className="rounded-2xl border border-border bg-[var(--app-primary-soft)] px-8 py-14 text-center sm:px-14 sm:py-16">
          <EchoMark className="mx-auto size-8 text-primary" />
          <h2 className="mx-auto mt-5 max-w-2xl font-display text-3xl font-medium leading-[1.12] tracking-[-0.02em] text-foreground sm:text-4xl">
            {title}
          </h2>
          <p className="mx-auto mt-4 max-w-xl font-serif text-[17px] leading-relaxed text-ink-2">
            Capture a word the moment you meet it, understand it in a popover
            without breaking your flow, and echo it back right before
            you&apos;d forget — no deck-building, and the core loop stays
            free.
          </p>
          <div className="mt-8 flex flex-wrap items-center justify-center gap-x-7 gap-y-3">
            <Button asChild size="lg">
              <Link href="/download">Download for Mac</Link>
            </Button>
            <Link
              href="/how-it-works"
              className="font-sans text-sm font-medium text-primary underline-offset-4 transition-colors hover:underline"
            >
              See how it works →
            </Link>
          </div>
          <ul className="mx-auto mt-9 flex max-w-lg flex-wrap items-center justify-center gap-y-1 border-t border-border pt-6 font-mono text-[11px] uppercase tracking-[0.08em] text-ink-2">
            {POINTS.map((p) => (
              <li
                key={p}
                className="flex items-center before:mx-3 before:text-ink-3 before:content-['·'] first:before:hidden"
              >
                {p}
              </li>
            ))}
          </ul>
          <p className="mx-auto mt-4 font-mono text-[11.5px] uppercase tracking-[0.1em] text-ink-2/80">
            {siteConfig.betaLine}
          </p>
        </div>
      </Container>
    </section>
  );
}
