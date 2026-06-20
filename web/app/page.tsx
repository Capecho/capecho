import Link from "next/link";

import { Button } from "@/components/ui/button";
import { Container } from "@/components/marketing/primitives";
import { HeroDevices } from "@/components/marketing/hero-devices";
import { LoopSteps } from "@/components/marketing/loop";
import { CtaSection } from "@/components/marketing/cta";
import { ChapterRail, Ledger, LedgerCol } from "@/components/marketing/sections";
import { siteConfig } from "@/lib/site";

const COMPARE: { row: string; cells: string[] }[] = [
  { row: "Capture off any screen", cells: ["—", "—", "—", "✓", "✓"] },
  { row: "Explain the word", cells: ["✓", "partial", "—", "—", "✓"] },
  { row: "Keeps your sentence", cells: ["—", "—", "manual", "—", "✓"] },
  { row: "Schedules review (SRS)", cells: ["—", "—", "✓", "—", "✓"] },
  { row: "No card-building", cells: ["—", "—", "—", "—", "✓"] },
];
const COMPARE_COLS = ["Dictionary", "Translator", "Anki", "OCR tool", "Capecho"];

const FEATURES: { dt: string; dd: string }[] = [
  {
    dt: "Off any screen, one keystroke",
    dd: "A word in a PDF, a subtitle, a paused video, an image — press the shortcut and it's caught off whatever's on screen, even when you can't select the text. You never leave the page.",
  },
  {
    dt: "The sentence comes with it",
    dd: "Not just the word — the line you met it in, so you remember which meaning was live. You edit before anything is saved.",
  },
  {
    dt: "What it means, right here",
    dd: "A plain explanation — meaning, part of speech, how it sounds — and, when you ask, what the word means inside your own sentence.",
  },
  {
    dt: "It comes back before you forget",
    dd: "Every word turns into a review that resurfaces just in time. No deck to build — catching the word already made the card.",
  },
  {
    dt: "Your words, not a word list",
    dd: "Everything comes from what you actually read. No word-of-the-day trivia you'll never use.",
  },
  {
    dt: "Never locked in",
    dd: "One tidy Word Book, and one-click export to Anki or CSV. Your vocabulary is always yours to take.",
  },
];

const FAQS: { q: string; a: string }[] = [
  {
    q: "Will it slow my reading down?",
    a: "That's the whole point of one keystroke — you catch the word and its sentence without leaving the page or opening another app. Review happens later, on your own time.",
  },
  {
    q: "What if I can't select the text?",
    a: "Subtitles, scanned PDFs, images, a paused video — Capecho reads what's on screen, so you can catch words you could never copy.",
  },
  {
    q: "Is my screen recorded or uploaded?",
    a: "No. Your Mac reads the text at your keypress and hands Capecho only the words — the screen image never leaves your machine, and you edit before it's saved.",
  },
  {
    q: "What does it cost?",
    a: `The core loop is free, with unlimited saved words. The only metered extra is the per-use in-context explanation — ${siteConfig.contextDailyCap} a day free, unlimited on Pro ($6/mo or $48/yr). No subscription on the everyday loop.`,
  },
];

export default function HomePage() {
  return (
    <>
      {/* Hero */}
      <section className="reveal mx-auto max-w-5xl px-5 pt-24 text-center sm:px-8 sm:pt-32">
        <h1 className="mx-auto max-w-5xl font-display text-[clamp(1.6rem,5.4vw,3rem)] font-medium leading-[1.1] tracking-[-0.018em] text-foreground sm:leading-[1.07]">
          <em className="italic text-primary">Capture</em>{" "}the new
          words off any screen,<br className="hidden sm:block" />{" "}
          <em className="italic text-primary">echo</em> them back before they fade.
        </h1>
        <p className="mx-auto mt-5 max-w-xl font-serif text-lg leading-relaxed text-ink-2">
          One keystroke to look up any word — even text you can&apos;t select.
          Save it, and Capecho does the rest, bringing each word with context back
          before you&apos;d forget.
        </p>
        <div className="mt-7 flex flex-wrap justify-center gap-3">
          <Button asChild size="lg">
            <Link href="/download">Download for Mac Free</Link>
          </Button>
          <Button asChild size="lg" variant="secondary">
            <Link href="/how-it-works">See how it works</Link>
          </Button>
        </div>
        <div className="mt-5 font-mono text-[11.5px] uppercase tracking-[0.08em] text-ink-2">
          Off any screen · One keystroke · In context · Spaced repetition
        </div>
      </section >

      <div className="reveal mt-4 px-5 sm:px-8">
        <HeroDevices />
      </div>
      <p className="reveal mx-auto mt-6 px-5 text-center font-mono text-[11.5px] uppercase tracking-[0.14em] text-ink-2/90">
        Now on Mac and iPhone · capture at your desk, review on the go
      </p>

      {/* The problem */}
      <section className="reveal mt-16 border-t border-border py-20">
        <Container>
          <ChapterRail>§ 02 — The problem</ChapterRail>
          <p className="max-w-[26ch] font-display text-[clamp(1.625rem,3.1vw,2.3rem)] font-medium leading-[1.3] tracking-[-0.015em] text-foreground">
            You look a word up. You understand it for one sentence. By the next
            page it&apos;s gone — so you{" "}
            <em className="italic text-ink-2">look it up again,</em> and again,
            and it never quite sticks.
          </p>
        </Container>
      </section>

      {/* Own both ends — where it fits */}
      <section className="reveal border-t border-border py-20">
        <Container>
          <ChapterRail>§ 03 — Where it fits</ChapterRail>
          <h2 className="max-w-[28ch] font-display text-3xl font-medium leading-[1.12] text-foreground sm:text-4xl">
            The tools that capture won&apos;t help you remember. The ones that
            remember won&apos;t capture for you.
          </h2>
          <p className="mt-4 max-w-[62ch] font-serif text-lg leading-relaxed text-ink-2">
            Capecho is the one that does both — it catches the word in the
            sentence you met it in, then echoes it back until it sticks. Not a
            replacement but a complement: keep your dictionary and your Anki
            deck;{" "}
            <strong>Capecho</strong> is the capture-to-review thread between them.
          </p>
          <div className="mt-8 overflow-x-auto max-w-full overflow-auto">
            <table className="w-full border-collapse font-sans">
              <thead>
                <tr>
                  <td className="border-b border-border" />
                  {COMPARE_COLS.map((c) => (
                    <th
                      key={c}
                      scope="col"
                      className={`border-b w-10 border-border md:p-3.5 p-1 text-center font-mono text-[11px] font-medium uppercase tracking-[0.05em] ${c === "Capecho"
                        ? "rounded-t-md bg-[var(--app-primary-soft)] text-primary"
                        : "text-ink-2"
                        }`}
                    >
                      {c}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {COMPARE.map((r, ri) => (
                  <tr key={r.row}>
                    <th
                      scope="row"
                      className="border-b border-border md:p-3.5 p-1 text-left font-serif text-[14.5px] font-normal text-foreground"
                    >
                      {r.row}
                    </th>
                    {r.cells.map((cell, i) => (
                      <td
                        key={i}
                        className={`border-b border-border md:p-3.5 p-1 text-center text-[13px] ${i === COMPARE_COLS.length - 1
                          ? `bg-[var(--app-primary-soft)] font-bold text-primary ${ri === COMPARE.length - 1 ? "rounded-b-md" : ""}`
                          : "text-ink-2"
                          }`}
                      >
                        {cell === "✓" ? (
                          <>
                            <span aria-hidden="true">✓</span>
                            <span className="sr-only">Yes</span>
                          </>
                        ) : cell === "—" ? (
                          <>
                            <span aria-hidden="true">—</span>
                            <span className="sr-only">No</span>
                          </>
                        ) : (
                          cell
                        )}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="mt-3.5 font-mono text-[11px] tracking-[0.02em] text-ink-2">
            Capture uses on-device OCR — you edit or fix the word before
            it&apos;s saved.
          </p>
        </Container>
      </section>

      {/* The loop */}
      <section className="reveal border-t border-border py-20">
        <Container>
          <ChapterRail>§ 04 — The loop</ChapterRail>
          <h2 className="max-w-xl font-display text-3xl font-medium leading-[1.12] text-foreground sm:text-4xl">
            From screen to memory,<br /> in one shortcut.
          </h2>
          <p className="mt-4 max-w-[60ch] font-serif text-lg leading-relaxed text-ink-2">
            Four steps, one keystroke. Catch the word with the line it lived in,
            see what it means, and let it come back on a schedule until you
            actually know it. There&apos;s no deck to build — catching the word
            already made the card.
          </p>
        </Container>
        <LoopSteps />
      </section>

      {/* Why context */}
      <section className="reveal border-t border-border py-20">
        <Container>
          <ChapterRail>§ 05 — Why context</ChapterRail>
          <h2 className="max-w-xl font-display text-3xl font-medium leading-[1.12] text-foreground sm:text-4xl">
            The sentence is part of the meaning.
          </h2>
          <p className="mt-4 max-w-[60ch] font-serif text-lg leading-relaxed text-ink-2">
            A dictionary gives you a definition that fits every sentence and none
            of yours. Capecho keeps the exact line you met the word in — so when
            it comes back, you remember which meaning was live, and where.
          </p>
          <div className="mt-8 grid gap-[18px] md:grid-cols-2">
            <div className="rounded-xl border border-border p-6">
              <div className="font-mono text-[11px] uppercase tracking-[0.1em] text-ink-2">
                A dictionary
              </div>
              <div className="mt-3 font-display text-2xl text-foreground">
                ineffable
              </div>
              <p className="mt-2 font-serif text-[14.5px] leading-relaxed text-ink-2">
                adjective — too great or extreme to be expressed or described in
                words.
              </p>
            </div>
            <div className="rounded-xl border border-border bg-card p-6 shadow-[var(--shadow-edge-soft)]">
              <div className="font-mono text-[11px] uppercase tracking-[0.1em] text-primary">
                In Capecho — your own sentence
              </div>
              <p className="my-3.5 font-serif text-[17px] leading-relaxed text-foreground">
                a low,{" "}
                <span className="rounded-[3px] bg-chip px-1 text-chip-foreground">
                  ineffable
                </span>{" "}
                sense that the streets were holding their breath.
              </p>
              <p className="border-t border-border pt-3 font-serif text-sm leading-relaxed text-ink-2">
                <span className="font-display font-semibold text-foreground">
                  ineffable
                </span>{" "}
                · adjective — too great or subtle to be put into words. Capecho
                keeps that meaning tied to the sentence you met it in, which is
                how it sticks.
              </p>
            </div>
          </div>
        </Container>
      </section>

      {/* Features */}
      <section className="reveal border-t border-border py-20">
        <Container>
          <ChapterRail>§ 06 — What the loop gives you</ChapterRail>
          <h2 className="max-w-[22ch] font-display text-3xl font-medium leading-[1.12] text-foreground sm:text-4xl">
            Everything the loop needs. Nothing it doesn&apos;t.
          </h2>
          <dl className="mt-8 grid gap-x-[52px] sm:grid-cols-2">
            {FEATURES.map((f) => (
              <div key={f.dt} className="border-b border-border py-[19px]">
                <dt className="font-display text-[19px] font-medium tracking-[-0.01em] text-foreground">
                  {f.dt}
                </dt>
                <dd className="mt-1.5 font-serif text-[14.5px] leading-relaxed text-ink-2">
                  {f.dd}
                </dd>
              </div>
            ))}
          </dl>
        </Container>
      </section>

      {/* Privacy ledger */}
      <section className="reveal border-t border-border py-20">
        <Container>
          <ChapterRail>§ 07 — Privacy</ChapterRail>
          <h2 className="max-w-lg font-display text-3xl font-medium leading-[1.12] text-foreground sm:text-4xl">
            Powerful capture you can trust.
          </h2>
          <p className="mt-4 max-w-[60ch] font-serif text-lg leading-relaxed text-ink-2">
            Your Mac does the reading, not Capecho. At your keypress, it reads the
            text on screen and hands over only the words — the picture of your
            screen never leaves your machine. You see it, edit it, and decide
            what&apos;s saved.
          </p>
          <Ledger>
            <LedgerCol
              label="Your Mac does the reading"
              items={[
                "macOS's built-in text recognition does the reading — only at your keypress, never continuously.",
                "The system API returns only the recognized text — the screen image itself never reaches Capecho, so there's nothing to store and nothing to upload.",
                "You edit and confirm the word and its sentence in the preview before anything is saved.",
              ]}
            />
            <LedgerCol
              label="Kept, so you can review"
              accent
              items={[
                "The word you save and the context sentence.",
                "Its explanation and your review history.",
                "The small settings that ride along (learning / explanation language).",
              ]}
              note="Synced to your private account — that's what makes cross-device review work."
            />
          </Ledger>
          <div className="mt-9">
            <Button asChild size="lg" variant="outline">
              <Link href="/privacy">Read the privacy model</Link>
            </Button>
          </div>
        </Container>
      </section>

      {/* What's free */}
      <section className="reveal border-t border-border py-20">
        <Container>
          <ChapterRail>§ 08 — What&apos;s free</ChapterRail>
          <h2 className="max-w-lg font-display text-3xl font-medium leading-[1.12] text-foreground sm:text-4xl">
            The core loop is free.
          </h2>
          <p className="mt-4 max-w-[60ch] font-serif text-lg leading-relaxed text-ink-2">
            Catch, understand, review, export — the whole loop is free, with no
            subscription on the things you do every day. Pro ($6/mo or $48/yr)
            only lifts two ceilings: an unlimited library, and unlimited in-context
            explanations{" "}
            <span className="text-ink-2">(the word read inside your sentence)</span>.
            Hit a free limit and nothing you&apos;ve saved is touched.
          </p>
          <Ledger>
            <LedgerCol
              label="Free"
              accent
              items={[
                "Capture (OCR + clipboard)",
                "Unlimited saved words",
                "The full word explanation — meaning + POS, senses, pronunciation",
                "The system-Dictionary handoff",
                "Word Book, spaced-repetition review, cross-device sync",
                "Anki / CSV export",
              ]}
              note={`${siteConfig.contextDailyCap} in-context explanations a day.`}
            />
            <LedgerCol
              label="Pro — $6/mo or $48/yr"
              items={[
                "Unlimited in-context explanations",
              ]}
              note="Save 33% on annual. Pro lifts the one per-use limit; everything else is already free and unlimited."
            />
          </Ledger>
        </Container>
      </section>

      {/* FAQ teaser */}
      <section className="reveal border-t border-border py-20">
        <Container>
          <ChapterRail>§ 09 — Questions</ChapterRail>
          <h2 className="font-display text-3xl font-medium leading-[1.12] text-foreground sm:text-4xl">
            Before you ask.
          </h2>
          <div className="mt-7">
            {FAQS.map((f, i) => (
              <div
                key={f.q}
                className="flex items-baseline gap-[18px] border-b border-border py-[17px]"
              >
                <span className="shrink-0 font-mono text-[11px] text-ink-2">
                  {String(i + 1).padStart(2, "0")}
                </span>
                <p className="font-serif text-[16.5px] leading-snug text-foreground">
                  <span className="font-display font-medium">{f.q}</span> {f.a}
                </p>
              </div>
            ))}
          </div>
          <div className="mt-7">
            <Button asChild variant="outline">
              <Link href="/faq">See the FAQ</Link>
            </Button>
          </div>
        </Container>
      </section>

      <CtaSection />
    </>
  );
}
