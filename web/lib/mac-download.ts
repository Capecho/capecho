import { siteConfig } from "@/lib/site";

/**
 * The macOS download link, resolved from the live Sparkle appcast so the page always points at the
 * latest shipped DMG without a redeploy.
 *
 * Source: https://download.capecho.com/appcast.xml — the same feed the app's auto-updater reads. We pick
 * the item with the highest `sparkle:version` (the monotonic build number), then publish its DMG on the
 * public download host: `https://download.capecho.com/Capecho-<version>.dmg` (the appcast's own enclosure
 * points at the `updates.capecho.com` Sparkle CDN; the marketing link uses the `download.` host instead).
 *
 * Everything is best-effort: any fetch/parse failure falls back to [siteConfig.links.macDownload] so the
 * Download button is never dead.
 */
const APPCAST_URL = "https://download.capecho.com/appcast.xml";
const DOWNLOAD_HOST = "https://download.capecho.com";

export type MacDownload = { url: string; version: string | null };

/** Parse the appcast and return the latest item's DMG filename + short version, or null. */
function parseLatest(xml: string): { file: string; version: string | null } | null {
  const items = xml.match(/<item\b[\s\S]*?<\/item>/g);
  if (!items) return null;

  let best: { build: number; file: string; version: string | null } | null = null;
  for (const item of items) {
    const build = Number(item.match(/<sparkle:version>\s*(\d+)\s*<\/sparkle:version>/)?.[1]);
    if (!Number.isFinite(build)) continue;

    const version =
      item.match(/<sparkle:shortVersionString>\s*([^<]+?)\s*<\/sparkle:shortVersionString>/)?.[1] ??
      null;

    // The release DMG is the <enclosure> directly under <item>; drop the <sparkle:deltas> block first so
    // we never pick a `.delta` patch enclosure.
    const withoutDeltas = item.replace(/<sparkle:deltas>[\s\S]*?<\/sparkle:deltas>/g, "");
    const enclosureUrl = withoutDeltas.match(/<enclosure\b[^>]*\burl="([^"]+\.dmg)"/)?.[1];
    if (!enclosureUrl) continue;

    const file = enclosureUrl.split("/").pop();
    if (!file) continue;

    if (!best || build > best.build) best = { build, file, version };
  }

  return best ? { file: best.file, version: best.version } : null;
}

/** The static fallback used whenever the appcast can't be fetched or parsed. */
export const fallbackMacDownload: MacDownload = {
  url: siteConfig.links.macDownload,
  version: null,
};

/**
 * Resolve the latest macOS download from the appcast, with a static fallback. Called from the
 * `/api/mac-download` route handler (not at page render) so the `/download` page stays static and
 * never triggers Next's ISR revalidation queue. The upstream fetch is uncached; the route handler
 * sets an edge Cache-Control header so the appcast is fetched at most ~hourly per colo.
 */
export async function getMacDownload(): Promise<MacDownload> {
  try {
    const res = await fetch(APPCAST_URL, { cache: "no-store" });
    if (!res.ok) throw new Error(`appcast ${res.status}`);
    const latest = parseLatest(await res.text());
    if (!latest) throw new Error("appcast: no resolvable item");
    return { url: `${DOWNLOAD_HOST}/${latest.file}`, version: latest.version };
  } catch {
    return fallbackMacDownload;
  }
}
