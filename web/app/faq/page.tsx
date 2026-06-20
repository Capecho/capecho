import type { Metadata } from "next";
import Link from "next/link";

import { Button } from "@/components/ui/button";
import { Container } from "@/components/marketing/primitives";
import { ChapterRail } from "@/components/marketing/sections";
import { CtaSection } from "@/components/marketing/cta";
import { siteConfig } from "@/lib/site";

export const metadata: Metadata = {
  title: "Capecho FAQ — availability, privacy, price",
  description:
    "Straight answers about availability, privacy, what's free, and Anki export. Is Capecho free, is it private, Capecho vs Anki, when is Capecho on mobile.",
  alternates: { canonical: "/faq" },
};

type QA = { q: string; a: string };
const GROUPS: { title: string; items: QA[] }[] = [
  {
    title: "Availability & platforms",
    items: [
      {
        q: "Is Capecho available now?",
        a: "Yes — Capecho is on the Mac App Store and the iPhone App Store, and the Mac app is also a direct download from capecho.com. You capture on your Mac and review on your Mac or iPhone.",
      },
      {
        q: "Why Mac first?",
        a: "Capture happens while you read on the desktop, and the Mac capture path (hotkey + on-device OCR) is built first. The iPhone review companion is now on the App Store too.",
      },
      {
        q: "Is there a mobile app?",
        a: "Yes — the iPhone review companion is on the App Store, so you can review your captured words on the go. An Android version is coming. Mobile capture is a later add.",
      },
      {
        q: "Is Capecho in the Mac App Store?",
        a: "Yes — Capecho is on the Mac App Store and the iPhone App Store. The Mac app is also available as a directly signed, notarized download from capecho.com.",
      },
      {
        q: "Windows or a browser extension?",
        a: "Later, as capture-surface expansion. Not in this release.",
      },
    ],
  },
  {
    title: "Privacy & permissions",
    items: [
      {
        q: "Does Capecho upload my screen?",
        a: "No. Your Mac's text recognition runs on-device, only at your keypress, and returns only the text — the screen image never reaches Capecho, and nothing is uploaded.",
      },
      {
        q: "What permission does it need, and can I skip it?",
        a: "Capture uses macOS's on-device OCR (the text recognition behind Live Text), and macOS gates that behind the permission it labels Screen Recording — Capecho never records or streams; the system runs one OCR pass at your keypress and returns only the text, so the screen image never reaches Capecho. Decline it and copy/paste mode still works: it reads your copied selection only after you press the shortcut, never clipboard monitoring.",
      },
      {
        q: "Does my sentence go to an AI?",
        a: `Three layers: it syncs to your private Capecho account when you save (so you can review across devices); it's never added to the shared, public word-explanation cache (built from the word alone); and it's sent to a third-party AI (Gemini) only when you tap the optional in-context explanation (${siteConfig.contextDailyCap}/day free), under a strict no-training policy (your input is never used to train AI models or reused for anything else).`,
      },
      {
        q: "Can I delete or export my data?",
        a: "Yes. Export anytime to Anki/CSV. Delete your account and your encrypted context sentences and private glosses are hard-deleted within ~30 days.",
      },
      {
        q: "Does it work offline?",
        a: "Yes — capture (on-device OCR) and review work without a connection; only the explanation enrichment waits for reconnect.",
      },
    ],
  },
  {
    title: "Price",
    items: [
      {
        q: "Is Capecho free or paid?",
        a: `The core loop is free, with unlimited saved words: capture, the full word explanation (core meaning + POS, senses, pronunciation), Word Book, FSRS review, cross-device sync, and Anki/CSV export. The only metered extra is ${siteConfig.contextDailyCap} in-context explanations a day; Pro ($6/mo or $48/yr) makes those unlimited.`,
      },
      {
        q: "What are the free limits?",
        a: `Just one: ${siteConfig.contextDailyCap} in-context explanations (the word as used in your sentence) a day. Saving words is free and unlimited, and the cache-shared word explanation itself is free and unlimited too.`,
      },
      {
        q: "What happens when I hit the free limit?",
        a: "Only the in-context explanation pauses — capture, unlimited saving, the word explanation, your Word Book, review, and export all keep working. The daily in-context limit resets at your account's local midnight.",
      },
      {
        q: "What's in Pro, and what does it cost?",
        a: "Unlimited in-context explanations — the one feature that costs us per use — for $6 a month or $48 a year (save 33%). Everything else, including unlimited saved words, is already free; you upgrade inside the app and can cancel anytime.",
      },
    ],
  },
  {
    title: "Product & comparison",
    items: [
      {
        q: "Do I have to build flashcards?",
        a: "No. Capture is one keystroke and the card assembles itself (your sentence + the word + its explanation).",
      },
      {
        q: "Do I need an account, and how do I sign in?",
        a: "Yes, to sync and review across devices: Google or email (one provider per account).",
      },
      {
        q: "Can I export to Anki?",
        a: "Yes — Anki and CSV (both included, free), with a target-language column so multi-language decks don't collide.",
      },
      {
        q: "Is this an Anki replacement?",
        a: "No, a complement: the same spaced-repetition engine (FSRS) without the manual card-building, and you can export to Anki anytime.",
      },
      {
        q: "Is Capecho a translator?",
        a: "No. It explains a word and keeps your sentence; it doesn't translate your screen.",
      },
      {
        q: "What languages does it support?",
        a: "Built first for English. Other target languages can still be captured, saved, and reviewed; generated explanations expand to more languages only after their quality is validated.",
      },
    ],
  },
];

export default function FaqPage() {
  const jsonLd = {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: GROUPS.flatMap((g) =>
      g.items.map((it) => ({
        "@type": "Question",
        name: it.q,
        acceptedAnswer: { "@type": "Answer", text: it.a },
      }))
    ),
  };

  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />

      <section className="reveal mx-auto max-w-[760px] px-5 pt-14 text-center sm:px-8">
        <div className="mb-5 font-mono text-xs uppercase tracking-[0.2em] text-ink-2">
          FAQ
        </div>
        <h1 className="font-display text-[clamp(2.25rem,4.8vw,3.5rem)] font-medium leading-[1.08] text-foreground">
          Straight answers.
        </h1>
        <p className="mx-auto mt-[18px] max-w-[52ch] font-serif text-lg leading-relaxed text-ink-2">
          What Capecho is, what&apos;s available now, what it costs, and what
          happens to your screen.
        </p>
      </section>

      <section className="reveal pt-14">
        <Container className="max-w-3xl">
          {GROUPS.map((group, gi) => (
            <div key={group.title} className={gi === 0 ? "" : "mt-12"}>
              <ChapterRail>{group.title}</ChapterRail>
              <div className="divide-y divide-border border-y border-border">
                {group.items.map((it) => (
                  <details key={it.q} className="group">
                    <summary className="flex cursor-pointer list-none items-center justify-between gap-4 py-4 font-display text-[18px] font-medium text-foreground marker:hidden">
                      {it.q}
                      <span
                        aria-hidden="true"
                        className="shrink-0 font-mono text-lg text-ink-2 transition-transform group-open:rotate-45"
                      >
                        +
                      </span>
                    </summary>
                    <p className="pb-4 font-serif text-[15.5px] leading-relaxed text-ink-2">
                      {it.a}
                    </p>
                  </details>
                ))}
              </div>
              {gi === 0 && (
                <div className="mt-6">
                  <Button asChild>
                    <Link href="/download">Download for Mac</Link>
                  </Button>
                </div>
              )}
            </div>
          ))}
        </Container>
      </section>

      <CtaSection />
    </>
  );
}
