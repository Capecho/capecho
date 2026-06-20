import type { Metadata } from "next";
import Link from "next/link";

import { Button } from "@/components/ui/button";
import { Container } from "@/components/marketing/primitives";
import { ChapterRail, Ledger, LedgerCol } from "@/components/marketing/sections";
import { CtaSection } from "@/components/marketing/cta";
import { siteConfig } from "@/lib/site";

export const metadata: Metadata = {
  title: "How Capecho works — capture, understand, review",
  description:
    "The loop, step by step: on-device OCR capture, AI understanding in context, and spaced-repetition review — plus exactly how the screen-recording permission (macOS Screen Recording) is used.",
  alternates: { canonical: "/how-it-works" },
};

function Kbd({ children }: { children: React.ReactNode }) {
  return (
    <kbd className="rounded-[5px] border border-ink-2 border-b-2 bg-card px-1.5 py-0.5 font-mono text-[0.86em] leading-none text-foreground">
      {children}
    </kbd>
  );
}

function Tag({ children, warm }: { children: React.ReactNode; warm?: boolean }) {
  return (
    <span
      className={`rounded-md border px-2.5 py-1.5 font-mono text-[11px] uppercase tracking-[0.04em] ${
        warm ? "border-primary text-primary" : "border-ink-3 text-ink-2"
      }`}
    >
      {children}
    </span>
  );
}

export default function HowItWorksPage() {
  return (
    <>
      {/* Page hero */}
      <section className="reveal mx-auto max-w-[920px] px-5 pt-14 text-center sm:px-8">
        <div className="mb-5 font-mono text-xs uppercase tracking-[0.2em] text-ink-2">
          How it works
        </div>
        <h1 className="mx-auto max-w-2xl font-display text-[clamp(2.25rem,4.8vw,3.6rem)] font-medium leading-[1.08] text-foreground">
          From screen to memory,<br /> in one shortcut.
        </h1>
        <p className="mx-auto mt-[18px] max-w-[60ch] font-serif text-lg leading-relaxed text-ink-2">
          Each step removes friction from the one before it — so reading turns
          into remembering without breaking your flow. Here is the whole loop,
          and exactly what it does with your screen.
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

      {/* The loop, in depth */}
      <section className="reveal pt-16">
        <Container>
          <ChapterRail>§ 01 — The loop, in depth</ChapterRail>
          <div>
            {/* 01 Capture */}
            <div className="grid items-start gap-10 border-t border-border py-9 md:grid-cols-[210px_1fr]">
              <div>
                <span className="block font-mono text-[11px] uppercase tracking-[0.12em] text-primary">
                  01 — Capture
                </span>
                <h3 className="mt-3 font-display text-[26px] font-medium tracking-[-0.01em] text-foreground">
                  Press the shortcut
                </h3>
              </div>
              <div className="max-w-[64ch]">
                <p className="font-serif text-[15.5px] leading-[1.72] text-ink-2">
                  Rest the cursor near a word and press the shortcut — default{" "}
                  <Kbd>⌥E</Kbd>. macOS&apos;s on-device text recognition (OCR){" "}
                  <b className="font-semibold text-foreground">
                    tries to read the word and the sentence around it
                  </b>{" "}
                  in whatever you&apos;re reading: articles, PDFs, subtitles,
                  images, text you can&apos;t select. It often gets both;
                  sometimes just the word, and you fill the rest.
                </p>
                <p className="mt-3 font-serif text-[15.5px] leading-[1.72] text-ink-2">
                  Want to be exact? Select and copy first, then press the shortcut
                  — the clipboard path,{" "}
                  <b className="font-semibold text-foreground">
                    triggered by you, never background monitoring
                  </b>
                  . A fleeting overlay shows the word, the learning language, the
                  explanation, and your sentence.{" "}
                  <b className="font-semibold text-foreground">
                    You edit or fix the word, then press <Kbd>Enter</Kbd> to
                    save.
                  </b>
                </p>
                <div className="mt-4 flex flex-wrap gap-2">
                  <Tag>Best-effort OCR</Tag>
                  <Tag>OCR or clipboard</Tag>
                  <Tag warm>You edit before saving</Tag>
                </div>
              </div>
            </div>
            {/* 02 Understand */}
            <div className="grid items-start gap-10 border-t border-border py-9 md:grid-cols-[210px_1fr]">
              <div>
                <span className="block font-mono text-[11px] uppercase tracking-[0.12em] text-primary">
                  02 — Understand
                </span>
                <h3 className="mt-3 font-display text-[26px] font-medium tracking-[-0.01em] text-foreground">
                  Meaning, in its context
                </h3>
              </div>
              <div className="max-w-[64ch]">
                <p className="font-serif text-[15.5px] leading-[1.72] text-ink-2">
                  A concise{" "}
                  <b className="font-semibold text-foreground">
                    core meaning + part of speech
                  </b>
                  , shown in the preview{" "}
                  <b className="font-semibold text-foreground">
                    when it&apos;s ready — your save never waits on it
                  </b>
                  . Behind a calm{" "}
                  <b className="font-semibold text-foreground">expand</b>: the
                  word&apos;s distinct senses (the noun vs the verb) and per-POS pronunciation.
                </p>
                <p className="mt-3 font-serif text-[15.5px] leading-[1.72] text-ink-2">
                  A <b className="font-semibold text-foreground">Dictionary</b>{" "}
                  button hands off to the macOS system dictionary for the
                  exhaustive entry. And when you want it, an{" "}
                  <b className="font-semibold text-foreground">
                    optional in-context explanation
                  </b>{" "}
                  — the word <i>as used in your sentence</i> — free up to{" "}
                  {siteConfig.contextDailyCap} a day.
                </p>
                <div className="mt-4 flex flex-wrap gap-2">
                  <Tag>Shown when ready</Tag>
                  <Tag>Senses · pronunciation · Dictionary</Tag>
                  <Tag warm>In-context · optional, {siteConfig.contextDailyCap}/day free</Tag>
                </div>
              </div>
            </div>
            {/* 03 Review */}
            <div className="grid items-start gap-10 border-t border-border py-9 md:grid-cols-[210px_1fr]">
              <div>
                <span className="block font-mono text-[11px] uppercase tracking-[0.12em] text-primary">
                  03 — Review
                </span>
                <h3 className="mt-3 font-display text-[26px] font-medium tracking-[-0.01em] text-foreground">
                  Before they fade
                </h3>
              </div>
              <div className="max-w-[64ch]">
                <p className="font-serif text-[15.5px] leading-[1.72] text-ink-2">
                  Saved words become{" "}
                  <b className="font-semibold text-foreground">
                    spaced-repetition (FSRS) cards
                  </b>
                  , fronted by your own sentence with the word highlighted. Rate{" "}
                  <Kbd>Forget</Kbd> <Kbd>Hard</Kbd> <Kbd>Good</Kbd> <Kbd>Easy</Kbd>{" "}
                  and the schedule returns each word just before you&apos;d forget
                  it.
                </p>
                <p className="mt-3 font-serif text-[15.5px] leading-[1.72] text-ink-2">
                  <b className="font-semibold text-foreground">
                    Review on your Mac, or on your iPhone on the go
                  </b>{" "}
                  — your words sync across both, so idle minutes on the go become
                  review minutes.
                </p>
                <div className="mt-4 flex flex-wrap gap-2">
                  <Tag>FSRS scheduling</Tag>
                  <Tag>Fronted by your sentence</Tag>
                  <Tag warm>Review on Mac + iPhone</Tag>
                </div>
              </div>
            </div>
          </div>
        </Container>
      </section>

      {/* What you need */}
      <section className="reveal border-t border-border py-16">
        <Container>
          <ChapterRail>§ 02 — What you need</ChapterRail>
          <h2 className="font-display text-3xl font-medium leading-[1.12] text-foreground sm:text-4xl">
            What you need.
          </h2>
          <div className="mt-7 grid gap-[18px] md:grid-cols-3">
            {[
              {
                lab: "The machine",
                a: "A Mac you read on.",
                b: "Requires macOS 14 or later; the Mac app is a directly notarized download.",
              },
              {
                lab: "The language",
                a: "Built first for English.",
                b: "Other languages can still be captured, saved, and reviewed today — generated explanations expand after quality validation. Never English-only.",
              },
              {
                lab: "The surfaces",
                a: "Capture is Mac-only today; you review on the Mac or your iPhone.",
                b: "Phone review is live on the App Store; mobile capture is a later add.",
              },
            ].map((n) => (
              <div key={n.lab} className="rounded-xl border border-border p-6">
                <div className="mb-3 font-mono text-[11px] uppercase tracking-[0.1em] text-primary">
                  {n.lab}
                </div>
                <p className="font-serif text-[14.5px] leading-relaxed text-foreground">
                  {n.a} <span className="text-ink-2">{n.b}</span>
                </p>
              </div>
            ))}
          </div>
        </Container>
      </section>

      {/* The capture moment */}
      <section className="reveal border-t border-border py-16">
        <Container>
          <ChapterRail>§ 03 — The capture moment</ChapterRail>
          <h2 className="font-display text-3xl font-medium leading-[1.12] text-foreground sm:text-4xl">
            Keyboard-first, and forgiving.
          </h2>
          <div className="mt-8 grid items-center gap-11 md:grid-cols-2">
            <div className="m-capframe" aria-hidden="true">
              <div className="src">The Hearth · Essay</div>
              <div className="art-mini">
                …a low, <span className="m-tgt">ineffable</span> sense that the
                streets were holding their breath, waiting for the day to begin.
              </div>
              <div className="m-ovl">
                <div className="hw">ineffable</div>
                <div className="pos">adjective</div>
                <div className="mean">
                  too great or extreme to be expressed or described in words.
                </div>
                <div className="field">
                  <span className="flab">Your sentence</span>
                  <span className="ctx">
                    …a low, ineffable sense that the streets were holding their
                    breath
                  </span>
                </div>
                <div className="row">
                  <span className="lang">Learning: English ▾</span>
                  <span className="save">
                    <span className="dot" />
                    Save
                  </span>
                </div>
              </div>
            </div>
            <div>
              <h3 className="mb-3 font-display text-[25px] font-medium tracking-[-0.01em] text-foreground">
                Two fields. One keystroke to save.
              </h3>
              <p className="max-w-[48ch] font-serif text-[15px] leading-relaxed text-ink-2">
                The word, and your sentence. <Kbd>Tab</Kbd> moves between them,{" "}
                <Kbd>Enter</Kbd> saves, <Kbd>Esc</Kbd> dismisses. If OCR or the
                clipboard grabbed the wrong token, correct the word inline; change
                the learning language inline too.
              </p>
              <div className="my-[18px] flex gap-2.5">
                <Kbd>Tab</Kbd>
                <Kbd>Enter</Kbd>
                <Kbd>Esc</Kbd>
              </div>
              <p className="max-w-[48ch] font-serif text-[15px] leading-relaxed text-ink-2">
                Only the word is required — the sentence is optional, and a
                context-less save is fine.
              </p>
              <p className="mt-4 max-w-[48ch] font-serif text-[12.5px] italic leading-relaxed text-ink-2">
                Text recognition runs only when you press the shortcut. The full
                model is on the{" "}
                <Link href="/privacy" className="text-primary underline-offset-2 hover:underline">
                  privacy page
                </Link>{" "}
                →
              </p>
            </div>
          </div>
        </Container>
      </section>

      {/* The permission model */}
      <section className="reveal border-t border-border py-16" id="why-screen-recording">
        <Container>
          <ChapterRail>§ 04 — The permission model</ChapterRail>
          <h2 className="max-w-[24ch] font-display text-3xl font-medium leading-[1.12] text-foreground sm:text-4xl">
            Why capture needs a screen-recording permission.
          </h2>
          <p className="mt-4 max-w-[60ch] font-serif text-lg leading-relaxed text-ink-2">
            To turn the word under your cursor into text, Capecho uses
            macOS&apos;s built-in{" "}
            <a
              href="https://developer.apple.com/documentation/vision/recognizing-text-in-images"
              target="_blank"
              rel="noreferrer"
              className="text-primary underline-offset-2 hover:underline"
            >
              on-device text recognition
            </a>{" "}
            (the OCR behind Live Text). macOS gates that pixel access behind a
            permission it labels{" "}
            <b className="font-semibold text-foreground">Screen Recording</b> —
            but Capecho never records or streams: the system reads the pixels at
            the instant you press the shortcut and returns only the recognized
            text — the screen image never reaches Capecho, and you edit before
            saving.
          </p>
          <Ledger>
            <LedgerCol
              label="What it does"
              items={[
                <>
                  On-device OCR,{" "}
                  <b className="font-semibold">only at the instant you press the shortcut</b>.
                </>,
                "The system returns only the recognized text — the screen image never reaches Capecho, so there's nothing to upload.",
              ]}
            />
            <LedgerCol
              label="What is kept"
              accent
              items={[
                "Only the word + the context you keep + its explanation + your review history.",
                "The small settings that ride along — your learning / explanation language.",
                "Synced to your private account so you can review across devices. Nothing else from your screen.",
              ]}
            />
          </Ledger>
          <div className="mt-5 rounded-xl border border-dashed border-border p-5">
            <div className="mb-2 font-mono text-[11px] uppercase tracking-[0.1em] text-ink-2">
              Prefer not to grant it?
            </div>
            <p className="font-serif text-[14.5px] leading-relaxed text-foreground">
              Copy/paste mode still works: select and copy, then press the
              shortcut. Capecho reads the copied selection{" "}
              <b className="font-semibold">only after you press it</b> — never
              clipboard monitoring. A deliberate reduced mode, not a weakened
              fallback.
            </p>
          </div>
          <div className="mt-8">
            <Button asChild size="lg" variant="outline">
              <Link href="/privacy">Read the privacy model</Link>
            </Button>
          </div>
        </Container>
      </section>

      <CtaSection />
    </>
  );
}
