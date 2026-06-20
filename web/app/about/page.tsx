import type { Metadata } from "next";
import Link from "next/link";
import Image from "next/image";

import { Button } from "@/components/ui/button";
import { Container } from "@/components/marketing/primitives";
import { ChapterRail } from "@/components/marketing/sections";
import { CtaSection } from "@/components/marketing/cta";
import { siteConfig } from "@/lib/site";

export const metadata: Metadata = {
  title: "About Capecho — why it exists, and who's making it",
  description:
    "Capecho is an independent project by Shawn (Xichuan Liu) — a developer who kept forgetting the English words he read. The story behind the capture-to-review loop, and the person building it.",
  alternates: { canonical: "/about" },
};

export default function AboutPage() {
  return (
    <>
      {/* Page hero */}
      <section className="reveal mx-auto max-w-[920px] px-5 pt-14 text-center sm:px-8">
        <div className="mb-5 font-mono text-xs uppercase tracking-[0.2em] text-ink-2">
          About
        </div>
        <h1 className="mx-auto max-w-4xl font-display text-[clamp(2.25rem,4.8vw,3.6rem)] font-medium leading-[1.08] text-foreground">
          Built by someone who kept
          <br /> forgetting the words he read.
        </h1>
        <p className="mx-auto mt-[18px] max-w-[60ch] font-serif text-lg leading-relaxed text-ink-2">
          Capecho started as one person&apos;s fix for a daily annoyance: looking
          a word up while reading, then forgetting it by the next page. Here is
          why it exists — and who&apos;s making it.
        </p>
        <div className="mt-7 flex flex-wrap justify-center gap-3">
          <Button asChild size="lg">
            <Link href="/download">Download for Mac</Link>
          </Button>
          <Button asChild size="lg" variant="secondary">
            <Link href="/blog/why-i-built-capecho">Read the full story</Link>
          </Button>
        </div>
      </section>

      {/* Why Capecho exists */}
      <section className="reveal pt-16">
        <Container className="max-w-2xl">
          <ChapterRail>§ 01 — Why Capecho exists</ChapterRail>
          <div className="space-y-5 font-serif text-[17px] leading-relaxed text-ink-2">
            <p>
              I read a lot in English — articles, documentation, the occasional
              book. And every few paragraphs I&apos;d hit a word I half-knew.
              I&apos;d look it up, nod, keep reading… and meet the same word a
              week later, just as blank as before.
            </p>
            <p>
              The tools I tried each missed by a little. A dictionary answers
              once, then the word rots in a list. Anki remembers — but building
              the cards by hand was more work than the reading, so I never kept it
              up. Kindle captures words in context beautifully, then locks them
              inside Kindle. I even ran a dedicated ChatGPT project just to study
              words — the explanations were good, but with no spaced repetition,
              everything I &ldquo;learned&rdquo; there quietly sank.
            </p>
            <p>
              So I built the thing I actually wanted: grab the word{" "}
              <em>and its sentence</em> in one keystroke — no card-building —{" "}
              <Link
                href="/save-words-in-context"
                className="text-primary underline-offset-2 hover:underline"
              >
                understand it in context
              </Link>
              , and let spaced repetition echo it back just before I&apos;d
              forget. Capture + echo. Capecho.
            </p>
            <p className="text-ink-2">
              The longer version — and the research that showed me I wasn&apos;t
              the only one — is in{" "}
              <Link
                href="/blog/why-i-built-capecho"
                className="text-primary underline-offset-2 hover:underline"
              >
                Why I built Capecho
              </Link>
              .
            </p>
          </div>
        </Container>
      </section>

      {/* Who's making it */}
      <section className="reveal mt-16 border-t border-border py-16">
        <Container className="max-w-2xl">
          <ChapterRail>§ 02 — Who&apos;s making it</ChapterRail>
          <div className="flex items-center gap-4">
            <Image
              src="/photo.webp"
              alt="Shawn (Xichuan Liu)"
              width={72}
              height={72}
              className="size-[72px] rounded-full object-cover"
            />
            <div>
              <div className="font-display text-xl font-medium text-foreground">
                Shawn <span className="text-ink-2">(Xichuan Liu)</span>
              </div>
              <div className="mt-1 font-mono text-[11px] uppercase tracking-[0.1em] text-ink-2">
                Independent developer · founder of Capecho
              </div>
            </div>
          </div>
          <div className="mt-6 space-y-5 font-serif text-[17px] leading-relaxed text-ink-2">
            <p>
              I&apos;ve built software for about a decade — on engineering teams
              at <b className="font-semibold text-foreground">Ant Group</b> and{" "}
              <b className="font-semibold text-foreground">ByteDance</b>, and as
              an independent maker shipping small, focused products like Browser
              AI Kit, TinyImgs, and TapCounter. These days I&apos;m also
              co-founder of{" "}
              <a
                href="https://knotwise.games"
                target="_blank"
                rel="noreferrer"
                className="text-primary underline-offset-2 hover:underline"
              >
                Knotwise Games
              </a>
              , a daily logic-puzzle studio.
            </p>
            <p>
              I&apos;m also exactly the person Capecho is for: a native Chinese
              speaker who reads English every day. I built it for my own reading
              first, then for everyone who reads in a second language and keeps
              losing the words.
            </p>
          </div>
          <div className="mt-7 flex flex-wrap gap-3">
            <Button asChild variant="outline">
              <a
                href="https://www.linkedin.com/in/xichuan-liu-883401338/"
                target="_blank"
                rel="noreferrer"
              >
                LinkedIn
              </a>
            </Button>
          </div>
        </Container>
      </section>

      {/* How it's built */}
      <section className="reveal border-t border-border py-16">
        <Container className="max-w-2xl">
          <ChapterRail>§ 03 — How it&apos;s built</ChapterRail>
          <div className="space-y-6">
            {[
              {
                lab: "Independent and self-funded",
                p: (
                  <>
                    Capecho is a solo project — no investors, no growth team, and
                    no business model built on selling your data. It&apos;s
                    currently run by me as an individual; I&apos;ll form a company
                    once Capecho can support itself.
                  </>
                ),
              },
              {
                lab: "In the open, and honest about status",
                p: (
                  <>
                    The Mac app — the capture half — and the iPhone review
                    companion are both available now. I&apos;d rather tell you
                    plainly what is and isn&apos;t ready than imply more than
                    there is.
                  </>
                ),
              },
              {
                lab: "Private by default",
                p: (
                  <>
                    Text recognition runs only when you press the shortcut, the
                    screen image never leaves your Mac, and you confirm everything
                    before it&apos;s saved. The full model is on the{" "}
                    <Link
                      href="/privacy"
                      className="text-primary underline-offset-2 hover:underline"
                    >
                      privacy page
                    </Link>
                    .
                  </>
                ),
              },
            ].map((row) => (
              <div key={row.lab} className="border-t border-border pt-5">
                <div className="mb-2 font-mono text-[11px] uppercase tracking-[0.1em] text-primary">
                  {row.lab}
                </div>
                <p className="max-w-[60ch] font-serif text-[15.5px] leading-relaxed text-ink-2">
                  {row.p}
                </p>
              </div>
            ))}
          </div>
        </Container>
      </section>

      {/* Contact */}
      <section className="reveal border-t border-border py-16">
        <Container className="max-w-2xl">
          <ChapterRail>§ 04 — Get in touch</ChapterRail>
          <p className="max-w-[60ch] font-serif text-[17px] leading-relaxed text-ink-2">
            Questions, bugs, or feedback? Email{" "}
            <a
              href={`mailto:${siteConfig.contactEmail}`}
              className="text-primary underline-offset-2 hover:underline"
            >
              {siteConfig.contactEmail}
            </a>{" "}
            — or find me on{" "}
            <a
              href="https://www.linkedin.com/in/xichuan-liu-883401338/"
              target="_blank"
              rel="noreferrer"
              className="text-primary underline-offset-2 hover:underline"
            >
              LinkedIn
            </a>
            . I read everything.
          </p>
        </Container>
      </section>

      <CtaSection />
    </>
  );
}
