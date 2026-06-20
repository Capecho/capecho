import { NextResponse } from "next/server";

import { getMacDownload } from "@/lib/mac-download";

/**
 * The latest notarized macOS DMG, resolved from the live Sparkle appcast. The `/download` page is a
 * static page that calls this from the client (with a loading state), so the page never depends on
 * appcast freshness and never triggers Next's ISR revalidation queue. We cache the JSON at the edge
 * for ~an hour so the appcast is fetched at most hourly per colo, with a short stale window.
 */
export const dynamic = "force-dynamic";

export async function GET() {
  const mac = await getMacDownload();
  return NextResponse.json(mac, {
    headers: {
      "cache-control": "public, max-age=3600, stale-while-revalidate=86400",
    },
  });
}
