import type { Metadata } from "next";
import Link from "next/link";

import { Button } from "@/components/ui/button";
import { Container } from "@/components/marketing/primitives";
import { ChapterRail } from "@/components/marketing/sections";
import { CtaSection } from "@/components/marketing/cta";
import { siteConfig } from "@/lib/site";

export const metadata: Metadata = {
  title: "Contact Capecho — support, feedback, and privacy requests",
  description:
    "Reach Capecho directly. Email hello@capecho.com for support, bug reports, feedback, or privacy and data requests — a real person reads every message.",
  alternates: { canonical: "/contact" },
};

const mailto = `mailto:${siteConfig.contactEmail}`;

export default function ContactPage() {
  return (
    <>
      {/* Page hero */}
      <section className="reveal mx-auto max-w-[920px] px-5 pt-14 text-center sm:px-8">
        <div className="mb-5 font-mono text-xs uppercase tracking-[0.2em] text-ink-2">
          Contact
        </div>
        <h1 className="mx-auto max-w-4xl font-display text-[clamp(2.25rem,4.8vw,3.6rem)] font-medium leading-[1.08] text-foreground">
          Get in touch.
        </h1>
        <p className="mx-auto mt-[18px] max-w-[58ch] font-serif text-lg leading-relaxed text-ink-2">
          Capecho is a small, independent project — so the person who builds it is
          the person who answers. Email is the best way to reach us, and a real
          human reads every message.
        </p>
        <div className="mt-7 flex flex-wrap justify-center gap-3">
          <Button asChild size="lg">
            <a href={mailto}>Email {siteConfig.contactEmail}</a>
          </Button>
          <Button asChild size="lg" variant="secondary">
            <Link href="/faq">Read the FAQ</Link>
          </Button>
        </div>
      </section>

      {/* Email */}
      <section className="reveal pt-16">
        <Container>
          <ChapterRail>§ 01 — Email</ChapterRail>
          <p className="max-w-[60ch] font-serif text-[17px] leading-relaxed text-ink-2">
            Write to{" "}
            <a
              href={mailto}
              className="text-primary underline-offset-2 hover:underline"
            >
              {siteConfig.contactEmail}
            </a>
            . It reaches {siteConfig.operator} directly. I read everything and
            usually reply within a couple of days — sometimes faster, occasionally
            slower while heads-down on a release.
          </p>
        </Container>
      </section>

      {/* What to write about */}
      <section className="reveal mt-16 border-t border-border py-14">
        <Container>
          <ChapterRail>§ 02 — What to write about</ChapterRail>
          <div className="mt-2 grid gap-[18px] md:grid-cols-3">
            {[
              {
                lab: "Support & bugs",
                p: (
                  <>
                    Something not working, or behaving oddly? Tell me what you did
                    and what happened — a screenshot helps. The{" "}
                    <Link
                      href="/faq"
                      className="text-primary underline-offset-2 hover:underline"
                    >
                      FAQ
                    </Link>{" "}
                    may already have the answer.
                  </>
                ),
              },
              {
                lab: "Feedback & ideas",
                p: (
                  <>
                    Capecho is early and shaped by the people using it. If
                    something feels off, or you wish it did one more thing, I want
                    to hear it.
                  </>
                ),
              },
              {
                lab: "Privacy & your data",
                p: (
                  <>
                    Requests to access or delete your data go to the same address —
                    I&apos;m the data controller. You can also delete your account
                    and everything tied to it from inside the app. The full model
                    is on the{" "}
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
              <div
                key={row.lab}
                className="rounded-xl border border-border p-6"
              >
                <div className="mb-2.5 font-mono text-[11px] uppercase tracking-[0.1em] text-primary">
                  {row.lab}
                </div>
                <p className="font-serif text-[15px] leading-relaxed text-ink-2">
                  {row.p}
                </p>
              </div>
            ))}
          </div>
        </Container>
      </section>

      {/* Elsewhere */}
      <section className="reveal border-t border-border py-14">
        <Container>
          <ChapterRail>§ 03 — Elsewhere</ChapterRail>
          <p className="max-w-[60ch] font-serif text-[17px] leading-relaxed text-ink-2">
            Prefer something other than email? Find me on{" "}
            <a
              href="https://www.linkedin.com/in/xichuan-liu-883401338/"
              target="_blank"
              rel="noreferrer"
              className="text-primary underline-offset-2 hover:underline"
            >
              LinkedIn
            </a>
            , or read more{" "}
            <Link
              href="/about"
              className="text-primary underline-offset-2 hover:underline"
            >
              about who&apos;s building Capecho
            </Link>
            .
          </p>
        </Container>
      </section>

      <CtaSection />
    </>
  );
}
