import type { Metadata } from "next";
import Link from "next/link";

import { Container } from "@/components/marketing/primitives";
import { siteConfig } from "@/lib/site";

export const metadata: Metadata = {
  title: "Terms of Use",
  description:
    "The terms that govern your use of Capecho during the beta: the service, your account and content, acceptable use, disclaimers, limitation of liability, governing law, and contact.",
  alternates: { canonical: "/legal/terms" },
};

type Section = { h: string; p?: string[]; list?: string[] };

const sections: Section[] = [
  {
    h: "Acceptance of these terms",
    p: [
      "By downloading or using Capecho, you agree to these Terms of Use. If you do not agree, please do not use Capecho. You must be at least 13 years old, or the minimum age of digital consent in your country (16 in parts of the EEA), to use the service.",
    ],
  },
  {
    h: "Who we are",
    p: [
      `Capecho is an independent project operated by ${siteConfig.operator} (“Capecho”, “we”, “us”). You can reach us at ${siteConfig.contactEmail}.`,
    ],
  },
  {
    h: "The service and the beta",
    p: [
      "Capecho helps you capture, understand, and review the vocabulary you meet while reading. It is in active development and provided on an early-access basis: features described on this site may change, and some are not yet available. The Mac app is available on the Mac App Store and as a directly notarized download that may auto-update; an iPhone app is available on the App Store. Your feedback shapes what ships next.",
    ],
  },
  {
    h: "Your account",
    p: [
      "Some features require an account so your vocabulary can sync and you can review across devices. Keep your sign-in secure; you are responsible for activity under your account. You can delete your account at any time.",
    ],
  },
  {
    h: "Acceptable use",
    p: ["You agree not to:"],
    list: [
      "use Capecho to break the law or infringe anyone’s rights;",
      "capture or store content in violation of the terms of the source you took it from;",
      "attack, disrupt, overload, probe, or reverse-engineer the service;",
      "resell or sublicense the service, or attempt to bypass its limits.",
    ],
  },
  {
    h: "Your content",
    p: [
      "The words, context sentences, and notes you save are yours. You grant us a limited, worldwide license to host, process, and sync that content solely to operate Capecho for you — including sending a context sentence to our AI provider when you trigger an in-context explanation. You are responsible for the content you capture and for having the right to use it. You can export your content to Anki or CSV, and delete it, at any time.",
    ],
  },
  {
    h: "Our intellectual property",
    p: [
      "Capecho — including its name, software, and content (excluding your content and third-party material) — belongs to us or our licensors. We grant you a personal, non-transferable, revocable license to use the app as intended; no other rights are granted.",
    ],
  },
  {
    h: "AI-assisted explanations",
    p: [
      "Explanations are AI-generated and may be incomplete or wrong. Treat them as study aids, not authoritative references.",
    ],
  },
  {
    h: "Third-party services",
    p: [
      "Capecho relies on third parties including Apple, Google (sign-in, the Gemini API, and Analytics), and Cloudflare. Your use of those services is also subject to their own terms.",
    ],
  },
  {
    h: "Payments",
    p: [
      "The core loop is free, with unlimited saved words. Pro is an optional paid subscription that unlocks unlimited in-context explanations; on the free tier that one feature has a daily amount. Billing runs through the processor for your distribution channel — Stripe for the directly notarized download, Apple In-App Purchase on the App Store, and Google Play Billing on Android — and the applicable terms and prices are shown before you buy.",
    ],
  },
  {
    h: "Disclaimers",
    p: [
      "Capecho is provided “as is” and “as available”, without warranties of any kind, whether express or implied, including any implied warranties of merchantability, fitness for a particular purpose, and non-infringement. We do not warrant that the service will be uninterrupted, secure, or error-free.",
    ],
  },
  {
    h: "Limitation of liability",
    p: [
      "To the maximum extent permitted by law, Capecho and its operator will not be liable for any indirect, incidental, special, consequential, or punitive damages, or for any loss of data, profits, or goodwill. Our total liability for any claim relating to the service is limited to the greater of the amount you paid us in the 12 months before the claim, or US$100. Some jurisdictions do not allow certain limitations, so some of these may not apply to you.",
    ],
  },
  {
    h: "Indemnification",
    p: [
      "You agree to indemnify and hold harmless the operator from claims, damages, and expenses arising out of your misuse of the service, your content, or your breach of these Terms.",
    ],
  },
  {
    h: "Termination",
    p: [
      "You may stop using Capecho and delete your account at any time. We may suspend or end the service, or your access to it — for example for abuse, or to discontinue the product — with notice where practical.",
    ],
  },
  {
    h: "Changes to these terms",
    p: [
      "We may update these Terms, or change or discontinue the service, as the product evolves. Material changes will be reflected here before they take effect, and your continued use means you accept them.",
    ],
  },
  {
    h: "Governing law and disputes",
    p: [
      "These Terms are governed by the laws of the State of Delaware and applicable U.S. federal law, without regard to conflict-of-laws rules. The exclusive venue for disputes is the state and federal courts located in Delaware, and you and Capecho consent to their personal jurisdiction. None of this limits the mandatory consumer-protection rights you have where you live (for example, statutory rights in the EEA and UK).",
    ],
  },
  {
    h: "Miscellaneous",
    list: [
      "Severability — if any provision is unenforceable, the rest stays in effect.",
      "Entire agreement — these Terms and the Privacy Policy are the whole agreement between you and us about Capecho.",
      "Assignment — you may not assign these Terms; we may assign them in connection with operating or transferring the service.",
      "No waiver — our not enforcing a right is not a waiver of it.",
      "Force majeure — we are not responsible for delays or failures caused by events beyond our reasonable control.",
    ],
  },
  {
    h: "Contact",
    p: [`Questions about these Terms: ${siteConfig.contactEmail}.`],
  },
];

export default function TermsPage() {
  return (
    <section className="pb-16 pt-14 sm:pt-20">
      <Container className="max-w-2xl">
        <div className="mb-4 font-mono text-xs uppercase tracking-[0.18em] text-ink-2">
          Legal
        </div>
        <h1 className="font-display text-4xl font-medium tracking-[-0.02em] text-foreground sm:text-5xl">
          Terms of Use
        </h1>

        <p className="mt-5 font-mono text-xs uppercase tracking-[0.14em] text-ink-2">
          Effective June 16, 2026
        </p>
        <p className="mt-4 font-serif text-[16px] leading-relaxed text-ink-2">
          See also our{" "}
          <Link
            href="/legal/privacy-policy"
            className="text-primary underline-offset-2 hover:underline"
          >
            Privacy Policy
          </Link>
          .
        </p>

        <div className="mt-10 space-y-10">
          {sections.map((s) => (
            <div key={s.h}>
              <h2 className="font-display text-2xl font-medium text-foreground">
                {s.h}
              </h2>
              {s.p?.map((para, i) => (
                <p
                  key={i}
                  className="mt-4 font-serif text-[17px] leading-relaxed text-ink-2"
                >
                  {para}
                </p>
              ))}
              {s.list ? (
                <ul className="mt-4 space-y-2">
                  {s.list.map((li, i) => {
                    const dash = li.indexOf(" — ");
                    const lead = dash > -1 ? li.slice(0, dash) : null;
                    const rest = dash > -1 ? li.slice(dash) : li;
                    return (
                      <li
                        key={i}
                        className="relative pl-5 font-serif text-[16px] leading-relaxed text-ink-2"
                      >
                        <span className="absolute left-0 text-primary">·</span>
                        {lead ? (
                          <b className="font-semibold text-foreground">{lead}</b>
                        ) : null}
                        {rest}
                      </li>
                    );
                  })}
                </ul>
              ) : null}
            </div>
          ))}
        </div>
      </Container>
    </section>
  );
}
