import type { Metadata } from "next";
import Link from "next/link";

import { Container } from "@/components/marketing/primitives";
import { siteConfig } from "@/lib/site";

export const metadata: Metadata = {
  title: "Privacy Policy",
  description:
    "What Capecho collects, why and on what legal basis, who we share it with, where it is stored, how long we keep it, your rights (GDPR / CCPA), and how to contact us.",
  alternates: { canonical: "/legal/privacy-policy" },
};

type Section = {
  h: string;
  p?: string[];
  list?: string[];
  links?: { label: string; href: string }[];
};

const sections: Section[] = [
  {
    h: "Who we are",
    p: [
      `Capecho is an independent project operated by ${siteConfig.operator} (“Capecho”, “we”, “us”), who is the data controller for the personal data described here. You can reach us at ${siteConfig.contactEmail}.`,
      "Our business address and, where legally required for users in the European Economic Area (EEA) and the United Kingdom, our representative under GDPR Article 27, are available on request.",
    ],
  },
  {
    h: "Scope of this policy",
    p: [
      "This policy covers the Capecho macOS app, the phone review companion (when released), and this website. It explains what we collect, why, the legal bases we rely on, who we share it with, where it is processed, how long we keep it, and the rights you have.",
    ],
  },
  {
    h: "What we collect",
    list: [
      "Account data — your email address and the identifier from your sign-in provider (Google or email).",
      "Your vocabulary content — the words you capture, the context sentences you keep, their explanations, and your review history.",
      "On-device cache — a local copy of your library, stored on your device so capture and review work offline.",
      "Website analytics — aggregate usage measured with Google Analytics 4 on this website only (see Cookies & Analytics).",
      "Technical data — limited logs such as IP address, timestamps, and error information needed to operate and secure the service.",
    ],
    p: [
      "What we do not collect: the captured screen image is processed on your device and discarded immediately after the text is read — it is never uploaded. We do not sell or mine your vocabulary.",
    ],
  },
  {
    h: "How we use your data, and our legal bases",
    p: ["Under the GDPR and similar laws, we rely on the following legal bases:"],
    list: [
      "To provide and sync the service (capture, save, explain, and review across your devices) — performance of our contract with you.",
      "To generate the optional in-context AI explanation you trigger — at your request, and where applicable your consent.",
      "For website analytics — your consent in the EEA, UK, and Switzerland; elsewhere, our legitimate interest in understanding aggregate traffic.",
      "To keep the service secure, prevent abuse, and fix problems — our legitimate interests.",
      "To meet legal and regulatory obligations — compliance with a legal obligation.",
    ],
  },
  {
    h: "On-device capture",
    p: [
      "Capture uses your device’s on-device text recognition, which runs only at the moment you press the shortcut — never continuously or in the background. The system returns only the recognized text; the screen image never reaches Capecho, so there is nothing for us to store or upload. Only the word you confirm and the context you choose are saved.",
    ],
  },
  {
    h: "Your private data vs. the shared explanation cache",
    p: [
      "Your private, synced data (the words, contexts, explanations, and review history you save) is separate from the shared, public word-explanation cache. That public cache is built from the word alone and never contains your sentence.",
    ],
  },
  {
    h: "AI provider",
    p: [
      "Your sentence is sent off your device only for the optional in-context explanation, which you trigger. That AI provider is the paid Google Gemini API, under terms where your input is not used to train Google’s models and is not reused for any other purpose; Google retains it only briefly for abuse-prevention and legal compliance.",
    ],
  },
  {
    h: "Who we share data with (subprocessors)",
    list: [
      "Cloudflare — hosting, database, object storage, and content delivery.",
      "Google — the Gemini API (for the in-context explanation you trigger), Google Analytics 4 (website), and Google Sign-In if you choose it.",
      "Payment processors — Stripe and/or Apple and Google — only if and when paid features launch.",
    ],
    p: [
      "We do not sell or share your personal data for advertising. A current list of subprocessors is available on request.",
    ],
    links: [
      { label: "Cloudflare", href: "https://www.cloudflare.com/privacypolicy/" },
      { label: "Google", href: "https://policies.google.com/privacy" },
      { label: "Stripe", href: "https://stripe.com/privacy" },
      { label: "Apple", href: "https://www.apple.com/legal/privacy/" },
    ],
  },
  {
    h: "Where your data is stored",
    p: [
      "The private data you sync — your account, the words you save, your context sentences and their explanations, and your review history — is stored on Cloudflare’s database infrastructure in the United States, and is not replicated to other regions. Separately, the shared public word-explanation cache — built from the word alone, never from your sentence — is held in Cloudflare object storage and served worldwide through a content-delivery network; it contains no personal data. The optional in-context explanation you trigger is additionally processed by Google’s Gemini API (see AI provider above).",
    ],
  },
  {
    h: "International data transfers",
    p: [
      "Your data is stored and processed on infrastructure operated by Cloudflare and Google, primarily in the United States, and the project is operated from outside the EEA. Where we transfer the personal data of users in the EEA, UK, or Switzerland abroad, we rely on appropriate safeguards such as the European Commission’s Standard Contractual Clauses (with the UK Addendum and Swiss equivalents where relevant).",
    ],
  },
  {
    h: "Storage and security",
    p: [
      "Your context sentences and their private in-context glosses are encrypted at rest (an AES-256-GCM envelope), and data is encrypted in transit. We limit access to personal data and keep a local cache on your device for offline use. No method of transmission or storage is completely secure, so we cannot guarantee absolute security.",
    ],
  },
  {
    h: "Data retention",
    list: [
      "Account and vocabulary data — kept while your account is active.",
      "Deleted items — soft-deleted items can be restored; deleting your account is a hard delete, and your encrypted context sentences and private glosses are removed within approximately 30 days.",
      "Website analytics — retained in aggregate according to our Google Analytics configuration.",
      "Logs and backups — kept for a limited period for security, troubleshooting, and recovery.",
    ],
  },
  {
    h: "Your rights",
    p: [
      "Depending on where you live, you may have the right to access, correct, delete, restrict, or object to the processing of your personal data; to data portability; and to withdraw consent at any time. In the EEA, UK, and Switzerland you also have the right to lodge a complaint with your data-protection supervisory authority.",
      `To exercise any of these, email ${siteConfig.contactEmail}. We respond within the time limits the law requires (generally one month under the GDPR). You can also export your vocabulary to Anki or CSV at any time from within the app.`,
    ],
  },
  {
    h: "California and other US state privacy rights",
    p: [
      "If you are a California resident, the categories of personal information we collect are listed above. We do not sell your personal information, and we do not “share” it for cross-context behavioral advertising — and have not in the preceding 12 months. You have the right to know, delete, and correct your information, to opt out, and not to be discriminated against for exercising these rights. Comparable rights apply under other US state privacy laws, for example in Virginia and Colorado.",
      `To make a request, email ${siteConfig.contactEmail}.`,
    ],
  },
  {
    h: "Children",
    p: [
      "Capecho is not directed to children. We do not knowingly collect personal data from children under 16 in the EEA, or under 13 in the United States. If you believe a child has provided us with personal data, contact us and we will delete it.",
    ],
  },
  {
    h: "Cookies and analytics",
    p: [
      "This website uses Google Analytics 4 behind Google Consent Mode: analytics are off by default for visitors in the EEA, UK, and Switzerland until they accept, and we set no advertising or cross-site-tracking signals. The Capecho app contains no third-party analytics in the capture path. Full details are on the Cookies & Analytics page.",
    ],
  },
  {
    h: "Automated decision-making",
    p: [
      "We do not make decisions that produce legal or similarly significant effects about you solely by automated means. AI-generated explanations are study aids about words, not decisions about you.",
    ],
  },
  {
    h: "Changes to this policy",
    p: [
      "We may update this policy as the product and the law evolve. We will post changes here and update the effective date; significant changes will be given prominent notice.",
    ],
  },
  {
    h: "Contact and complaints",
    p: [
      `Questions or requests: ${siteConfig.contactEmail}. Users in the EEA, UK, and Switzerland may also contact their local data-protection supervisory authority.`,
    ],
  },
];

export default function PrivacyPolicyPage() {
  return (
    <section className="pb-16 pt-14 sm:pt-20">
      <Container className="max-w-2xl">
        <div className="mb-4 font-mono text-xs uppercase tracking-[0.18em] text-ink-2">
          Legal
        </div>
        <h1 className="font-display text-4xl font-medium tracking-[-0.02em] text-foreground sm:text-5xl">
          Privacy Policy
        </h1>

        <p className="mt-5 font-mono text-xs uppercase tracking-[0.14em] text-ink-2">
          Effective June 16, 2026
        </p>
        <p className="mt-4 font-serif text-[16px] leading-relaxed text-ink-2">
          A plain-language summary is on the{" "}
          <Link
            href="/privacy"
            className="text-primary underline-offset-2 hover:underline"
          >
            privacy page
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
              {s.links ? (
                <p className="mt-4 font-serif text-[16px] leading-relaxed text-ink-2">
                  Each provider’s own privacy policy:{" "}
                  {s.links.map((l, i) => (
                    <span key={l.href}>
                      {i > 0 ? " · " : null}
                      <a
                        href={l.href}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="text-primary underline-offset-2 hover:underline"
                      >
                        {l.label}
                      </a>
                    </span>
                  ))}
                </p>
              ) : null}
            </div>
          ))}
        </div>
      </Container>
    </section>
  );
}
