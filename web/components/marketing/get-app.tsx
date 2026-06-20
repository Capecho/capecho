import Link from "next/link";

import { cn } from "@/lib/utils";
import { siteConfig } from "@/lib/site";

/**
 * Footer "Get the app" block — the recognizable official-style store badges (the
 * black "Download on the App Store" / "Get it on Google Play" lockups) under the
 * footer wordmark.
 *
 * iOS and macOS are separate badges (same Apple mark, distinct "App Store" vs
 * "Mac App Store" wording, the way Apple distinguishes them) — both are live and
 * link into the App Store. Google Play and Microsoft Store are shown **disabled /
 * greyed** with a "Soon" tag because the MVP has no Android / Windows build yet.
 * Links live in siteConfig.appLinks (a "#" placeholder greys a badge until live).
 *
 * The marks are trademarks, used to link to each store (standard nominative use);
 * follow Apple's / Google's / Microsoft's badge guidelines if the layout changes
 * materially.
 */

function AppleMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 384 512" className={className} fill="currentColor" aria-hidden="true">
      <path d="M318.7 268.7c-.2-36.7 16.4-64.4 50-84.8-18.8-26.9-47.2-41.7-84.7-44.6-35.5-2.8-74.3 20.7-88.5 20.7-15 0-49.4-19.7-76.4-19.7C63.3 141.2 4 184.8 4 273.5q0 39.3 14.4 81.2c12.8 36.7 59 126.7 107.2 125.2 25.2-.6 43-17.9 75.8-17.9 31.8 0 48.3 17.9 76.4 17.9 48.6-.7 90.4-82.5 102.6-119.3-65.2-30.7-61.7-90-61.7-91.9zm-56.6-164.2c27.3-32.4 24.8-61.9 24-72.5-24.1 1.4-52 16.4-67.9 34.9-17.5 19.8-27.8 44.3-25.6 71.9 26.1 2 49.9-11.4 69.5-34.3z" />
    </svg>
  );
}

function PlayMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 256 283" className={className} aria-hidden="true">
      <path d="M119.553141,134.916362 L1.0599006,259.060547 C3.75619448,268.616998 10.7182836,276.3906 19.9208658,280.119977 C29.1234481,283.849353 39.5331235,283.115716 48.121672,278.132484 L181.448642,202.197919 L119.553141,134.916362 Z" fill="#EA4335" />
      <path d="M239.370822,113.813616 L181.71353,80.7909097 L116.815965,137.741834 L181.978418,202.021326 L239.19423,169.351804 C249.525723,163.942452 256,153.24465 256,141.58271 C256,129.92077 249.525723,119.222968 239.19423,113.813616 L239.370822,113.813616 Z" fill="#FBBC04" />
      <path d="M1.0599006,23.4868015 C0.343633396,26.134699 -0.0127538816,28.8670014 0,31.6100341 L0,250.937314 C0.00751268399,253.679042 0.363556675,256.408712 1.0599006,259.060547 L123.614758,138.095018 L1.0599006,23.4868015 Z" fill="#4285F4" />
      <path d="M120.436101,141.273674 L181.71353,80.7909097 L48.5631521,4.50316009 C43.5539929,1.56944036 37.8568091,0.0156629668 32.0517989,0 C17.6444261,-0.0284873284 4.97836875,9.53420553 1.0599006,23.3985055 L120.436101,141.273674 Z" fill="#34A853" />
    </svg>
  );
}

function WindowsMark({ className }: { className?: string }) {
  // Single fill (currentColor) so the disabled badge reads as cleanly greyed.
  return (
    <svg viewBox="0 0 256 256" className={className} fill="currentColor" aria-hidden="true">
      <polygon points="121.666095 121.666095 0 121.666095 0 0 121.666095 0" />
      <polygon points="256 121.666095 134.335356 121.666095 134.335356 0 256 0" />
      <polygon points="121.663194 256.002188 0 256.002188 0 134.336095 121.663194 134.336095" />
      <polygon points="256 256.002188 134.335356 256.002188 134.335356 134.336095 256 134.336095" />
    </svg>
  );
}

/** A black official-style store lockup: brand mark + "kicker" line + store name. */
function StoreBadge({
  mark,
  kicker,
  name,
  href,
  disabled = false,
  note,
}: {
  mark: React.ReactNode;
  kicker: string;
  name: string;
  href?: string;
  disabled?: boolean;
  note?: string;
}) {
  const body = (
    <span className="flex h-[52px] items-center gap-2.5 rounded-[10px] border border-white/15 bg-black px-3.5 text-white">
      <span className="flex w-8 shrink-0 items-center justify-center">{mark}</span>
      <span className="flex flex-col text-left leading-none">
        <span className="font-sans text-[11px] uppercase tracking-[0.04em] text-white/70">
          {kicker}
        </span>
        <span className="mt-1 font-sans text-[15px] font-semibold leading-tight">
          {name}
        </span>
      </span>
    </span>
  );

  if (disabled) {
    return (
      <span
        className="relative inline-block cursor-not-allowed"
        aria-disabled="true"
        title={note ? `${name} — ${note}` : `${name} — not available yet`}
      >
        {/* Fade only the pill, so the note tag below stays crisp (CSS group
            opacity would otherwise drag a nested tag down with it). */}
        <span className="block opacity-40 grayscale">{body}</span>
        {note && (
          <span className="absolute -right-1.5 -top-2 rounded-full border border-border bg-card px-1.5 py-0.5 font-mono text-[11px] font-medium uppercase tracking-[0.06em] text-ink-2 shadow-sm">
            {note}
          </span>
        )}
      </span>
    );
  }

  return (
    <Link
      href={href ?? "#"}
      className="inline-block rounded-xl transition-transform hover:-translate-y-px hover:brightness-110"
    >
      {body}
    </Link>
  );
}

export function GetApp({ className }: { className?: string }) {
  const { appLinks } = siteConfig;
  return (
    <div className={cn(className)}>
      <h3 className="font-mono text-[11px] font-medium uppercase tracking-[0.08em] text-ink-2">
        Get the app
      </h3>
      <div className="mt-3.5 grid max-w-[420px] grid-cols-2 gap-2.5">
        <StoreBadge
          mark={<AppleMark className="size-[32px]" />}
          kicker="Download on the"
          name="App Store"
          href={appLinks.iosAppStore}
        />
        <StoreBadge
          mark={<AppleMark className="size-[32px]" />}
          kicker="Download on the"
          name="Mac App Store"
          href={appLinks.macAppStore}
        />
        <StoreBadge
          mark={<PlayMark className="size-7" />}
          kicker="Get it on"
          name="Google Play"
          href={appLinks.googlePlay}
          disabled
          note="Soon"
        />
        <StoreBadge
          mark={<WindowsMark className="size-[24px]" />}
          kicker="Get it from"
          name="Microsoft Store"
          disabled
          note="Soon"
        />
      </div>
    </div>
  );
}
