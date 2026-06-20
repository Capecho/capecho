import type { Metadata } from "next";
import Link from "next/link";

import { Button } from "@/components/ui/button";
import { Container } from "@/components/marketing/primitives";
import { ChapterRail, Ledger, LedgerCol } from "@/components/marketing/sections";
import { CtaSection } from "@/components/marketing/cta";
import { siteConfig } from "@/lib/site";

export const metadata: Metadata = {
  title: "Capecho pricing — the whole loop is free, pay only for per-use AI",
  description: `Capture, understand, and review — free, with unlimited saved words. The only metered thing is the per-use in-context explanation: ${siteConfig.contextDailyCap} a day free, unlimited on Pro ($6/mo or $48/yr). We price what costs us per use, nothing else.`,
  alternates: { canonical: "/pricing" },
};

export default function PricingPage() {
  return (
    <>
      <section className="reveal mx-auto max-w-[760px] px-5 pt-14 text-center sm:px-8">
        <div className="mb-5 font-mono text-xs uppercase tracking-[0.2em] text-ink-2">
          Pricing
        </div>
        <h1 className="font-display text-[clamp(2.25rem,4.8vw,3.5rem)] font-medium leading-[1.08] text-foreground">
          The whole loop is free.
        </h1>
        <p className="mx-auto mt-[18px] max-w-[56ch] font-serif text-lg leading-relaxed text-ink-2">
          Capture, understand, and review — free, with{" "}
          <b className="font-semibold text-foreground">unlimited saved words</b>.
          The one metered extra is the per-use in-context explanation:{" "}
          {siteConfig.contextDailyCap} a day free, unlimited on Pro. We price what
          costs us every time you use it — and nothing else.
        </p>
        <div className="mt-7 flex flex-wrap justify-center gap-3">
          <Button asChild size="lg">
            <Link href="/download">Download for Mac</Link>
          </Button>
          <Button asChild size="lg" variant="secondary">
            <Link href="/faq">See the FAQ</Link>
          </Button>
        </div>
      </section>

      <section className="reveal py-16">
        <Container>
          <ChapterRail>§ 01 — Free vs Pro</ChapterRail>
          <Ledger>
            <LedgerCol
              label="Free"
              accent
              items={[
                "Capture (OCR + clipboard)",
                "Unlimited saved words — no ceiling on your library",
                "The full word explanation — meaning + POS, senses, pronunciation",
                "The system-Dictionary handoff",
                "Word Book + FSRS review",
                "Cross-device sync + the iPhone review companion",
                "Anki / CSV export",
                `${siteConfig.contextDailyCap} in-context explanations a day`,
              ]}
              note="Everything you save stays readable, reviewable, and exportable — always."
            />
            <LedgerCol
              label="Pro — $6/mo or $48/yr"
              items={[
                "Unlimited in-context explanations — the word as used in your sentence, any time",
              ]}
              note="Save 33% on annual. Pro lifts the one per-use limit; everything else is already free and unlimited."
            />
          </Ledger>
        </Container>
      </section>

      <section className="reveal border-t border-border py-16">
        <Container className="max-w-3xl">
          <ChapterRail>§ 02 — What we charge for</ChapterRail>
          <p className="font-serif text-lg leading-relaxed text-ink-2">
            A simple rule: we price the things that{" "}
            <b className="font-semibold text-foreground">cost us each time you use them</b>
            , and nothing else. The word explanation is generated{" "}
            <b className="font-semibold text-foreground">once and shared with everyone</b>
            , so its cost doesn&apos;t grow with use — free and unlimited. Saving a
            word is just a row in your library — so that&apos;s free and unlimited
            too. The one exception is the{" "}
            <b className="font-semibold text-foreground">in-context explanation</b>
            , which reads the word inside <i>your</i> specific sentence and calls an
            AI model <i>every time</i> — a real, recurring, per-use cost. That, and
            only that, is what Pro covers.
          </p>
          <p className="mt-4 font-serif text-lg leading-relaxed text-ink-2">
            Right now we&apos;d rather you build the habit and grow your library than
            reach for your wallet — so we&apos;ve put as little behind the paywall as
            we honestly can. As we add new AI-powered capabilities, the
            compute-heavy ones will be where Pro grows; the everyday capture →
            understand → review loop will keep costing nothing.
          </p>
        </Container>
      </section>

      <section className="reveal border-t border-border py-16">
        <Container className="max-w-3xl">
          <ChapterRail>§ 03 — Reaching the daily limit</ChapterRail>
          <p className="font-serif text-lg leading-relaxed text-ink-2">
            Use the day&apos;s {siteConfig.contextDailyCap} in-context explanations
            and <b className="font-semibold text-foreground">nothing else pauses</b> —
            capture, unlimited saving, the word explanation, your Word Book, review,
            and export all keep working, and the in-context limit resets at your
            account&apos;s local midnight. Pro removes that single limit.
          </p>
          <h2 className="mt-10 font-display text-2xl font-medium text-foreground">
            Our stance: the loop stays free
          </h2>
          <p className="mt-3 font-serif text-lg leading-relaxed text-ink-2">
            Pro prices the one feature that costs us per use — unlimited in-context
            — not the capture → understand → review loop, and not your library.
            It&apos;s <b className="font-semibold text-foreground">$6 a month</b>,
            or <b className="font-semibold text-foreground">$48 a year</b> (save
            33%), and you upgrade inside the app. Cancel anytime; your saved words
            stay yours either way.
          </p>
        </Container>
      </section>

      <section className="reveal border-t border-border py-16">
        <Container className="max-w-3xl">
          <ChapterRail>§ 04 — Why a subscription, not a one-time price?</ChapterRail>
          <p className="font-serif text-lg leading-relaxed text-ink-2">
            It&apos;s a fair question — paying once for a tool you keep is the
            model a lot of people prefer, and there&apos;s no subscription on the
            things you do every day: capture, unlimited saving, the full word
            explanation, your Word Book, review, and export are free, full stop.
          </p>
          <p className="mt-4 font-serif text-lg leading-relaxed text-ink-2">
            Pro is a subscription for one honest reason. The{" "}
            <b className="font-semibold text-foreground">in-context explanation</b>{" "}
            — the word read inside your specific sentence — calls an AI model{" "}
            <i>every time you use it</i>, so it carries a real cost that comes back
            with every sentence. A one-time price can&apos;t cover a cost that
            recurs; only ongoing access can. So we charge for the one thing that
            actually scales with use, and leave everything that doesn&apos;t cost
            us per use free. If you never need it, you never pay.
          </p>
        </Container>
      </section>

      <CtaSection />
    </>
  );
}
