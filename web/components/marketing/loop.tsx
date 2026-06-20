import { Container } from "@/components/marketing/primitives";
import { EchoMark } from "@/components/brand/echo-mark";
import { siteConfig } from "@/lib/site";

/**
 * The loop — the signature section (web/DESIGN.md §5): a growing-echo timeline,
 * NOT a grid of feature cards. The echo mark enlarges 01 → 03 along a connecting
 * line, "echoing back a little louder" each step.
 */
const STEPS = [
  {
    n: "01 — Capture",
    title: "Press ⌥E",
    body: "macOS's on-device text recognition reads the word and its sentence from whatever you're reading — articles, PDFs, subtitles, images, non-selectable text — or copy first, then press. You edit the word before saving.",
    tag: "On-device OCR or clipboard",
    size: "size-[30px]",
  },
  {
    n: "02 — Understand",
    title: "Meaning, in context",
    body: "A concise core meaning and part of speech, shown when it's ready — your save never waits on it. Senses and pronunciation sit behind a calm expand.",
    tag: `In-context gloss · optional, ${siteConfig.contextDailyCap}/day free`,
    size: "size-[46px]",
  },
  {
    n: "03 — Review",
    title: "Before they fade",
    body: "Saved words come back as spaced-repetition cards fronted by your own sentence. Rate Forget / Hard / Good / Easy and each returns just before you'd forget it.",
    tag: "Review on Mac + iPhone",
    size: "size-[66px]",
  },
];

export function LoopSteps() {
  return (
    <Container>
      <div className="relative mt-12 grid gap-8 md:grid-cols-3">
        {/* connecting line behind the echo nodes (desktop) */}
        <div className="pointer-events-none absolute left-[15%] right-[15%] top-[31px] hidden h-px bg-border md:block" />
        {STEPS.map((s) => (
          <div key={s.n} className="relative text-center">
            <div className="mb-3.5 flex h-[62px] items-center justify-center">
              <span className="inline-flex bg-background px-3 text-primary">
                <EchoMark className={s.size} />
              </span>
            </div>
            <div className="font-mono text-[11px] uppercase tracking-[0.1em] text-primary">
              {s.n}
            </div>
            <h3 className="mt-2 font-display text-[22px] font-medium tracking-[-0.01em] text-foreground">
              {s.title}
            </h3>
            <p className="mx-auto mt-2 max-w-[31ch] font-serif text-[14.5px] leading-relaxed text-ink-2">
              {s.body}
            </p>
            <span className="mt-3.5 block font-mono text-[11px] uppercase tracking-[0.05em] text-ink-2">
              {s.tag}
            </span>
          </div>
        ))}
      </div>
    </Container>
  );
}
