"use client";

import { useEffect, useState } from "react";

import { EchoMark } from "@/components/brand/echo-mark";
import { Button } from "@/components/ui/button";
import { trackEvent } from "@/lib/analytics";
import { fallbackMacDownload, type MacDownload } from "@/lib/mac-download";

/**
 * The "Download for Mac" button. Resolves the latest notarized DMG + version from the live appcast
 * via `/api/mac-download` on the client, so the `/download` page itself stays static. Until the
 * appcast responds the button shows the brand loading state (the animated echo mark — DESIGN.md's
 * "working" motion) and is disabled; once resolved it becomes the live download link and the version
 * line fills in.
 */
export function MacDownloadButton() {
  const [mac, setMac] = useState<MacDownload | null>(null);

  useEffect(() => {
    let cancelled = false;
    fetch("/api/mac-download")
      .then((res) => (res.ok ? (res.json() as Promise<MacDownload>) : null))
      .then((data) => {
        if (!cancelled) setMac(data?.url ? data : fallbackMacDownload);
      })
      .catch(() => {
        if (!cancelled) setMac(fallbackMacDownload);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const loading = mac === null;

  return (
    <div className="mt-8 flex flex-col items-center gap-2.5">
      {loading ? (
        <Button size="lg" disabled aria-busy="true">
          <EchoMark animate />
          Download for Mac
        </Button>
      ) : (
        <Button asChild size="lg">
          <a
            href={mac.url}
            onClick={() =>
              trackEvent("mac_download", {
                version: mac.version ?? "unknown",
                url: mac.url,
              })
            }
          >
            Download for Mac
          </a>
        </Button>
      )}
      <p className="font-mono text-[11px] tracking-[0.02em] text-ink-2">
        {loading ? (
          <span className="opacity-60">Checking for the latest version…</span>
        ) : (
          <>
            {mac.version ? `Version ${mac.version} · ` : ""}Free · macOS 14+ · notarized &amp; signed
          </>
        )}
      </p>
    </div>
  );
}
