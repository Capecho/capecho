import type { Metadata } from "next";
import Link from "next/link";

import { Button } from "@/components/ui/button";
import { Container } from "@/components/marketing/primitives";
import { ChapterRail, Ledger, LedgerCol } from "@/components/marketing/sections";
import { CtaSection } from "@/components/marketing/cta";
import { siteConfig } from "@/lib/site";

export const metadata: Metadata = {
  title: "Privacy-first vocabulary capture",
  description:
    "The exact data flow: on-device OCR only when you press the shortcut, only the recognized text returned to Capecho, your sentence never in the shared cache, edit before saving, and a copy/paste mode if you decline the screen-recording permission.",
  alternates: { canonical: "/privacy" },
};

export default function PrivacyPage() {
  return (
    <>
      {/* Hero */}
      <section className="reveal mx-auto max-w-[820px] px-5 pt-14 text-center sm:px-8">
        <div className="mb-5 font-mono text-xs uppercase tracking-[0.2em] text-ink-2">
          Privacy
        </div>
        <h1 className="font-display text-[clamp(2.25rem,4.8vw,3.5rem)] font-medium leading-[1.08] text-foreground">
          Built for vocabulary,<br /> not data collection.
        </h1>
        <p className="mx-auto mt-[18px] max-w-[60ch] font-serif text-lg leading-relaxed text-ink-2">
          Capture is powerful, so trust is part of the product. This page is the
          exact data flow — what&apos;s read, what&apos;s discarded, what&apos;s
          kept, and what (if anything) ever leaves your device.
        </p>
        <div className="mt-7 flex flex-wrap justify-center gap-3">
          <Button asChild size="lg">
            <Link href="/download">Download for Mac</Link>
          </Button>
          <Button asChild size="lg" variant="secondary">
            <Link href="/how-it-works">See how it works</Link>
          </Button>
        </div>
      </section>

      {/* Why the screen-recording permission */}
      <section className="reveal pt-16">
        <Container className="max-w-3xl">
          <ChapterRail>§ 01 — Why capture needs a screen-recording permission</ChapterRail>
          <p className="font-serif text-lg leading-relaxed text-ink-2">
            To turn a word — even one in a subtitle, a PDF, or other text you
            can&apos;t select — into something Capecho can save, it uses
            macOS&apos;s built-in{" "}
            <a
              href="https://developer.apple.com/documentation/vision/recognizing-text-in-images"
              target="_blank"
              rel="noreferrer"
              className="text-primary underline-offset-2 hover:underline"
            >
              on-device text recognition
            </a>{" "}
            (the same OCR behind Live Text). macOS gates that pixel access behind
            a permission it labels{" "}
            <b className="font-semibold text-foreground">Screen Recording</b> — so
            the toggle has a heavy name, but Capecho never records or streams. Here
            is exactly how narrowly it&apos;s used.
          </p>
        </Container>
      </section>

      {/* The lifecycle */}
      <section className="reveal border-t border-border py-16">
        <Container className="max-w-3xl">
          <ChapterRail>§ 02 — When you press the shortcut</ChapterRail>
          <ul className="space-y-3">
            {[
              <>
                Your Mac&apos;s own text recognition runs{" "}
                <b className="font-semibold text-foreground">
                  on your device, only at that instant.
                </b>
              </>,
              <>
                The system hands back{" "}
                <b className="font-semibold text-foreground">
                  only the recognized text
                </b>
                ; the screen image{" "}
                <b className="font-semibold text-foreground">
                  never reaches Capecho
                </b>
                , so there&apos;s nothing to store and nothing to upload.
              </>,
              <>
                You <b className="font-semibold text-foreground">review and confirm</b>{" "}
                in the preview — edit the word, fix a wrong grab, remove sensitive
                text — and <b className="font-semibold text-foreground">only then</b>{" "}
                is anything saved.
              </>,
            ].map((li, i) => (
              <li
                key={i}
                className="relative pl-5 font-serif text-[16px] leading-relaxed text-ink-2"
              >
                <span className="absolute left-0 font-bold text-primary">·</span>
                {li}
              </li>
            ))}
          </ul>
        </Container>
      </section>

      {/* Data map */}
      <section className="reveal border-t border-border py-16">
        <Container>
          <ChapterRail>§ 03 — What stays, and what syncs</ChapterRail>
          <Ledger>
            <LedgerCol
              label="Synced to your account"
              accent
              items={[
                "The word you save and the context sentence.",
                "Its explanation, your review history, and the small settings that go with them (learning / explanation language).",
              ]}
              note="Synced to your private account — that's what makes cross-device review work."
            />
            <LedgerCol
              label="Kept locally / never retained"
              items={[
                "A local cache of your words, so capture and review work offline.",
                "Nothing else from your screen is retained — only what you saved, plus the language + context metadata that rides along.",
              ]}
            />
          </Ledger>
        </Container>
      </section>

      {/* The AI boundary — three layers */}
      <section className="reveal border-t border-border py-16">
        <Container className="max-w-3xl">
          <ChapterRail>§ 04 — Does your sentence go to an AI?</ChapterRail>
          <h2 className="font-display text-3xl font-medium leading-[1.12] text-foreground sm:text-4xl">
            Three layers, never collapsed.
          </h2>
          <ol className="mt-6 space-y-4">
            {[
              <>
                <b className="font-semibold text-foreground">
                  Saving syncs your sentence to your private Capecho account
                </b>{" "}
                so you can review across devices — that&apos;s the only reason it
                leaves your Mac by default.
              </>,
              <>
                It is{" "}
                <b className="font-semibold text-foreground">
                  never added to the shared, public word-explanation cache
                </b>
                : that explanation is built from the word alone, so your sentence
                is never part of what other users get.
              </>,
              <>
                Your sentence is{" "}
                <b className="font-semibold text-foreground">
                  sent to a third-party AI (Gemini) only when you tap the optional
                  in-context explanation
                </b>{" "}
                (the word <i>as used in your sentence</i> — free up to{" "}
                {siteConfig.contextDailyCap}/day). We
                hold that provider to a strict no-training policy (your input is never used to train AI models or reused for anything else).
              </>,
            ].map((li, i) => (
              <li key={i} className="flex gap-4">
                <span className="shrink-0 font-mono text-sm text-primary">
                  {String(i + 1).padStart(2, "0")}
                </span>
                <p className="font-serif text-[16px] leading-relaxed text-ink-2">
                  {li}
                </p>
              </li>
            ))}
          </ol>
        </Container>
      </section>

      {/* Encryption + commitments + control */}
      <section className="reveal border-t border-border py-16">
        <Container>
          <ChapterRail>§ 05 — Encryption, commitments, control</ChapterRail>
          <div className="grid gap-[18px] md:grid-cols-3">
            <div className="rounded-xl border border-border p-6">
              <div className="mb-3 font-mono text-[11px] uppercase tracking-[0.1em] text-primary">
                What&apos;s encrypted
              </div>
              <p className="font-serif text-[14.5px] leading-relaxed text-ink-2">
                Your context sentences and their private in-context glosses are
                encrypted at rest; the rest of your library is kept privately in
                your account.
              </p>
            </div>
            <div className="rounded-xl border border-border p-6">
              <div className="mb-3 font-mono text-[11px] uppercase tracking-[0.1em] text-primary">
                What Capecho doesn&apos;t do
              </div>
              <p className="font-serif text-[14.5px] leading-relaxed text-ink-2">
                No background or continuous screen-reading. The screen image
                never reaches Capecho — the system returns only text. No
                third-party trackers in the capture path. Capecho isn&apos;t built
                around selling or mining your vocabulary.
              </p>
            </div>
            <div className="rounded-xl border border-border p-6">
              <div className="mb-3 font-mono text-[11px] uppercase tracking-[0.1em] text-primary">
                You control your data
              </div>
              <p className="font-serif text-[14.5px] leading-relaxed text-ink-2">
                Export anytime to Anki or CSV — never locked in. Delete your
                account and your encrypted context sentences and private glosses
                are hard-deleted within ~30 days.
              </p>
            </div>
          </div>
        </Container>
      </section>

      {/* Copy/paste + sensitive */}
      <section className="reveal border-t border-border py-16">
        <Container className="max-w-3xl">
          <ChapterRail>§ 06 — If you&apos;d rather not grant permission</ChapterRail>
          <p className="font-serif text-lg leading-relaxed text-ink-2">
            Capecho still works in <b className="font-semibold text-foreground">copy/paste mode</b>:
            select and copy, then press the shortcut. Capecho reads the copied
            selection <b className="font-semibold text-foreground">only after you press it</b>{" "}
            (never clipboard monitoring) — a deliberate reduced mode, not a
            weakened fallback.
          </p>
          <p className="mt-4 font-serif text-lg leading-relaxed text-ink-2">
            Capturing near an email, account ID, or private note?{" "}
            <b className="font-semibold text-foreground">
              Edit or delete that text in the preview before saving
            </b>{" "}
            — the word and context are quiet editable text.
          </p>
          <p className="mt-8 font-serif text-[15px] text-ink-2">
            The formal version: the full{" "}
            <Link
              href="/legal/privacy-policy"
              className="text-primary underline-offset-2 hover:underline"
            >
              Privacy Policy
            </Link>{" "}
            and{" "}
            <Link href="/legal/terms" className="text-primary underline-offset-2 hover:underline">
              Terms
            </Link>
            .
          </p>
        </Container>
      </section>

      <CtaSection />
    </>
  );
}
