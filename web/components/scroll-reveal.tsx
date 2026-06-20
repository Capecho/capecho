"use client";

import { useEffect } from "react";
import { usePathname } from "next/navigation";

/**
 * Scroll-reveal (web/DESIGN.md §7). Content is visible by default; an inline
 * head script adds `.js-reveal` to <html> before paint so `.reveal` elements
 * start hidden, and this observer fades each one in as it enters the viewport.
 *
 * Robustness (the part that matters): anything already in — or scrolled past —
 * the viewport is revealed on the next frame, so a hero, a deep link, a refresh
 * mid-page, or a fast scroll never strands content in the hidden state waiting
 * on an observer callback that may lag. The observer (threshold 0) then handles
 * genuinely below-the-fold elements as they scroll in. No-JS / reduced-motion /
 * no-IntersectionObserver all fall back to fully shown. Re-runs on route change.
 */
export function ScrollReveal() {
  const pathname = usePathname();

  useEffect(() => {
    const els = Array.from(document.querySelectorAll<HTMLElement>(".reveal"));
    if (els.length === 0) return;

    const reduce =
      typeof window.matchMedia === "function" &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    if (reduce || !("IntersectionObserver" in window)) {
      els.forEach((e) => e.classList.add("in"));
      return;
    }

    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("in");
            io.unobserve(entry.target);
          }
        });
      },
      // threshold 0 + a small bottom margin: reveal the moment a sliver enters,
      // so a fast scroll can't skip past an element the way a higher threshold can.
      { threshold: 0, rootMargin: "0px 0px -6% 0px" }
    );
    els.forEach((e) => io.observe(e));

    // Reveal everything at or above the fold on the next frame — after the hidden
    // state has painted, so the fade still plays. This covers the hero, deep
    // links, and refresh-mid-page: content that can't afford to wait for a scroll
    // that may never come.
    const raf = window.requestAnimationFrame(() => {
      const h = window.innerHeight || document.documentElement.clientHeight;
      els.forEach((e) => {
        if (e.classList.contains("in")) return;
        if (e.getBoundingClientRect().top < h * 0.94) {
          e.classList.add("in");
          io.unobserve(e);
        }
      });
    });

    // Last-resort safety: never leave anything stuck hidden.
    const safety = window.setTimeout(
      () => els.forEach((e) => e.classList.add("in")),
      1400
    );

    return () => {
      io.disconnect();
      window.cancelAnimationFrame(raf);
      window.clearTimeout(safety);
    };
  }, [pathname]);

  return null;
}
