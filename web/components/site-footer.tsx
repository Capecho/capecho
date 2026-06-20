import Link from "next/link";

import { footerNav, siteConfig } from "@/lib/site";
import { Wordmark } from "@/components/brand/wordmark";
import { GetApp } from "@/components/marketing/get-app";

export function SiteFooter() {
  return (
    <footer className="reveal mt-24 border-t border-border bg-titlebar">
      <div className="mx-auto max-w-6xl px-5 py-14 sm:px-8">
        <div className="grid gap-10 md:grid-cols-3 lg:grid-cols-[1.6fr_1fr_1fr]">
          <div>
            <Wordmark />
            <p className="mt-4 max-w-xs font-serif text-[15px] leading-relaxed text-ink-2">
              {siteConfig.tagline}
            </p>
            <GetApp className="mt-7" />
          </div>

          {footerNav.map((col) => (
            <div key={col.title}>
              <h3 className="font-mono text-[11px] font-medium uppercase tracking-[0.08em] text-ink-2">
                {col.title}
              </h3>
              <ul className="mt-3.5 space-y-2.5">
                {col.items.map((item) => (
                  <li key={item.href}>
                    <Link
                      href={item.href}
                      className="font-sans text-[13px] text-ink-2 transition-colors hover:text-foreground"
                    >
                      {item.title}
                    </Link>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>

        <div className="mt-12 flex flex-col items-start justify-between gap-3 border-t border-border pt-6 text-xs text-ink-2 sm:flex-row sm:items-center">
          <p className="font-mono">
            © {new Date().getFullYear()} {siteConfig.legalEntity}
          </p>
          <div className="flex items-center gap-5 font-sans">
            <Link href="/legal/privacy-policy" className="hover:text-foreground">
              Privacy Policy
            </Link>
            <Link href="/legal/cookies" className="hover:text-foreground">
              Cookies
            </Link>
            <Link href="/legal/terms" className="hover:text-foreground">
              Terms
            </Link>
          </div>
        </div>
      </div>
    </footer>
  );
}
