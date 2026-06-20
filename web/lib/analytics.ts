/**
 * Thin GA4 event helper. gtag.js is loaded in app/layout.tsx (consent-gated); this just forwards an
 * event to it when present. No-ops on the server, before gtag loads, or when the visitor declined
 * analytics consent (gtag itself drops events while `analytics_storage` is denied), so callers can
 * fire freely without guarding.
 */
export function trackEvent(name: string, params?: Record<string, unknown>): void {
  if (typeof window === "undefined") return;
  const w = window as unknown as { gtag?: (...args: unknown[]) => void };
  if (typeof w.gtag === "function") {
    w.gtag("event", name, params);
  }
}
