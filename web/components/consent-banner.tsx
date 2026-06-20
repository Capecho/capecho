"use client";

import { useEffect, useState } from "react";
import Link from "next/link";

import { Button } from "@/components/ui/button";
import { siteConfig } from "@/lib/site";

/**
 * Lightweight cookie-consent banner paired with Google Consent Mode v2.
 *
 * GA's default consent state is set in app/layout.tsx BEFORE gtag.js loads:
 * GRANTED worldwide, DENIED only in the EEA / UK / CH (siteConfig
 * .consentRequiredRegions). This banner is therefore shown ONLY to visitors in
 * those consent-required regions (resolved via /api/geo) — everyone else reports
 * by default and never sees it. On Accept it flips analytics_storage to granted
 * and persists the choice; Decline keeps it denied.
 */
const STORAGE_KEY = "capecho-consent";
const GEO_KEY = "capecho-geo";
const CONSENT_REQUIRED = new Set<string>([
  ...(siteConfig.consentRequiredRegions ?? []),
]);

export function ConsentBanner() {
  const [show, setShow] = useState(false);

  useEffect(() => {
    let alreadyChose = false;
    try {
      alreadyChose = !!localStorage.getItem(STORAGE_KEY);
    } catch {
      // localStorage unavailable (private mode) — treat as undecided.
    }
    if (alreadyChose) return; // decided before → never show again

    let cancelled = false;
    (async () => {
      let country: string | null = null;
      try {
        country = sessionStorage.getItem(GEO_KEY);
      } catch {
        // ignore
      }
      if (country === null) {
        try {
          const res = await fetch("/api/geo");
          const data = (await res.json()) as { country?: string };
          country = (data.country || "").toUpperCase();
          try {
            sessionStorage.setItem(GEO_KEY, country);
          } catch {
            // ignore
          }
        } catch {
          // Can't resolve region → don't show. GA's region-scoped default still
          // denies the EEA/UK/CH, so this fails safe (compliant, just no opt-in).
          country = "";
        }
      }
      if (!cancelled && country && CONSENT_REQUIRED.has(country)) {
        setShow(true);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  function decide(granted: boolean) {
    try {
      localStorage.setItem(STORAGE_KEY, granted ? "granted" : "denied");
    } catch {
      // ignore persistence failure
    }
    const w = window as unknown as {
      gtag?: (...args: unknown[]) => void;
    };
    if (granted && typeof w.gtag === "function") {
      w.gtag("consent", "update", { analytics_storage: "granted" });
    }
    setShow(false);
  }

  if (!show) return null;

  return (
    <div
      role="dialog"
      aria-label="Cookie consent"
      className="fixed inset-x-3 bottom-3 z-50 mx-auto max-w-xl rounded-xl border border-border bg-card/95 p-4 shadow-[var(--shadow-edge-soft)] backdrop-blur sm:inset-x-auto sm:left-1/2 sm:-translate-x-1/2"
    >
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <p className="font-serif text-[13.5px] leading-relaxed text-ink-2">
          Capecho uses privacy-friendly analytics (Google Analytics 4) to
          understand aggregate traffic — no ads, no cross-site tracking.{" "}
          <Link
            href="/legal/cookies"
            className="text-primary underline-offset-2 hover:underline"
          >
            Details
          </Link>
          .
        </p>
        <div className="flex shrink-0 gap-2">
          <Button size="sm" variant="outline" onClick={() => decide(false)}>
            Decline
          </Button>
          <Button size="sm" onClick={() => decide(true)}>
            Accept
          </Button>
        </div>
      </div>
    </div>
  );
}
