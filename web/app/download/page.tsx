import type { Metadata } from "next";
import Link from "next/link";

import { Container } from "@/components/marketing/primitives";
import { ChapterRail, Ledger, LedgerCol } from "@/components/marketing/sections";
import { MacDownloadButton } from "@/components/marketing/mac-download-button";
import { siteConfig } from "@/lib/site";

export const metadata: Metadata = {
  title: "Download Capecho for Mac",
  description:
    "Download the Mac capture app: capture words off any screen — even text you can't select — review them in context with spaced repetition. Now on Mac and iPhone — capture on your Mac, review on your phone.",
  alternates: { canonical: "/download" },
};

export default function DownloadPage() {
  return (
    <>
      {/* Hero + download */}
      <section className="reveal mx-auto max-w-[760px] px-5 pt-14 text-center sm:px-8">
        <div className="mb-5 font-mono text-xs uppercase tracking-[0.2em] text-ink-2">
          Get Capecho
        </div>
        <h1 className="font-display text-[clamp(2.25rem,4.8vw,3.5rem)] font-medium leading-[1.08] text-foreground">
          Download Capecho for Mac.
        </h1>
        <p className="mx-auto mt-[18px] max-w-[52ch] font-serif text-lg leading-relaxed text-ink-2">
          Capture words off any screen as you read on your Mac — a PDF, a
          subtitle, an image, even text you can&apos;t select — understand them in
          context, and start building a vocabulary you actually review. Now on
          Mac and iPhone — capture on your Mac, review on your phone.
        </p>
        <MacDownloadButton />
        <div className="mt-5 flex flex-wrap justify-center gap-x-5 gap-y-1 font-sans text-sm text-ink-2">
          <Link href="/how-it-works" className="hover:text-foreground">
            See how it works
          </Link>
          <Link href="/privacy" className="hover:text-foreground">
            Read the privacy model
          </Link>
        </div>
      </section>

      {/* The two halves */}
      <section className="reveal pt-16">
        <Container>
          <ChapterRail>§ 01 — The two halves</ChapterRail>
          <div className="grid gap-[18px] md:grid-cols-2">
            <div className="rounded-xl border border-border bg-card p-7 shadow-[var(--shadow-edge-soft)]">
              <div className="font-mono text-[11px] uppercase tracking-[0.1em] text-primary">
                Capecho for macOS — the capture half
              </div>
              <p className="mt-3 font-serif text-[15px] leading-relaxed text-ink-2">
                A global shortcut, on-device recognition, a free word explanation
                (core meaning + POS, with senses + pronunciation behind an
                expand), and one-keystroke save. You review right here on the Mac
                too.
              </p>
              <p className="mt-4 font-mono text-[11px] uppercase tracking-[0.06em] text-primary">
                Status: available now · direct download
              </p>
            </div>
            <div className="rounded-xl border border-border bg-card p-7 shadow-[var(--shadow-edge-soft)]">
              <div className="font-mono text-[11px] uppercase tracking-[0.1em] text-primary">
                The phone review companion — the review half
              </div>
              <p className="mt-3 font-serif text-[15px] leading-relaxed text-ink-2">
                Your captured words sync to your iPhone and come back as
                spaced-repetition reviews, so idle minutes become review minutes.
              </p>
              <p className="mt-4 font-mono text-[11px] uppercase tracking-[0.06em] text-primary">
                Status: available now · App Store
              </p>
            </div>
          </div>
        </Container>
      </section>

      {/* What to expect */}
      <section className="reveal border-t border-border py-16">
        <Container>
          <ChapterRail>§ 02 — What to expect</ChapterRail>
          <h2 className="max-w-[24ch] font-display text-3xl font-medium leading-[1.12] text-foreground sm:text-4xl">
            Early, honest, and actively developed.
          </h2>
          <div className="mt-7 grid gap-[18px] md:grid-cols-3">
            {[
              {
                lab: "What's available",
                p: "Mac capture and review are available now, and the iPhone review companion is on the App Store. Mobile capture is a later add. Things will change, and your feedback shapes what ships next.",
              },
              {
                lab: "How it updates",
                p: "The app is notarized and auto-updates itself, so you stay on the latest build without re-downloading. An honest cadence, not manufactured urgency.",
              },
              {
                lab: "What it costs",
                p: `The core loop is free, with unlimited saved words. The only metered extra is ${siteConfig.contextDailyCap} in-context explanations a day; Pro ($6/mo or $48/yr) makes those unlimited, and hitting the limit never locks what you've saved.`,
              },
            ].map((c) => (
              <div key={c.lab} className="rounded-xl border border-border p-6">
                <div className="mb-3 font-mono text-[11px] uppercase tracking-[0.1em] text-primary">
                  {c.lab}
                </div>
                <p className="font-serif text-[14.5px] leading-relaxed text-ink-2">
                  {c.p}
                </p>
              </div>
            ))}
          </div>
        </Container>
      </section>

      {/* What's free + what you need */}
      <section className="reveal border-t border-border py-16">
        <Container>
          <ChapterRail>§ 03 — What&apos;s free, what you&apos;ll need</ChapterRail>
          <Ledger>
            <LedgerCol
              label="Free"
              accent
              items={[
                "Capture, unlimited saved words, the full word explanation (meaning + POS, senses, pronunciation)",
                "Word Book, FSRS review, cross-device sync, Anki / CSV export",
              ]}
              note={`Free, with ${siteConfig.contextDailyCap} in-context explanations a day. Pro lifts that one limit — $6/mo or $48/yr.`}
            />
            <LedgerCol
              label="What you'll need"
              items={[
                "A Mac you read on (macOS 14 or later).",
                "The screen-recording permission (macOS labels it Screen Recording) — used only at your keypress; the system returns just the recognized text, the screen image never reaches Capecho, nothing uploaded. Or use copy/paste mode.",
                "On the Mac App Store, or as a directly notarized, signed download. Sign-in is Google or email.",
              ]}
            />
          </Ledger>
          <p className="mt-4 font-serif text-sm text-ink-2">
            More in the{" "}
            <Link href="/pricing" className="text-primary underline-offset-2 hover:underline">
              pricing
            </Link>{" "}
            and{" "}
            <Link href="/faq" className="text-primary underline-offset-2 hover:underline">
              FAQ
            </Link>
            .
          </p>
        </Container>
      </section>

      {/* After you download */}
      <section className="reveal border-t border-border py-16">
        <Container>
          <ChapterRail>§ 04 — After you download</ChapterRail>
          <h2 className="max-w-[22ch] font-display text-3xl font-medium leading-[1.12] text-foreground sm:text-4xl">
            What happens next.
          </h2>
          <p className="mt-4 max-w-[60ch] font-serif text-lg leading-relaxed text-ink-2">
            Open the app, grant the one permission (or use copy/paste mode), and
            press the shortcut on your first word. Sign in whenever you want to
            sync and review across devices — including the iPhone review
            companion, now on the App Store.
          </p>
          <p className="mt-4 max-w-[60ch] font-mono text-[12px] uppercase tracking-[0.06em] text-ink-2">
            Screen never uploaded · core loop is free · now on Mac and iPhone
          </p>
        </Container>
      </section>
    </>
  );
}
