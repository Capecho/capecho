import { NextResponse } from "next/server";

/**
 * Visitor country for consent gating. Read from the hosting platform's geo header
 * — Cloudflare sets `cf-ipcountry`, Vercel sets `x-vercel-ip-country`. Returns an
 * empty string when the platform doesn't provide one (e.g. local dev), in which
 * case the consent banner stays hidden and GA's region-scoped default applies.
 * Never cached.
 */
export const dynamic = "force-dynamic";

export function GET(request: Request) {
  const country =
    request.headers.get("cf-ipcountry") ||
    request.headers.get("x-vercel-ip-country") ||
    "";
  return NextResponse.json(
    { country: country.toUpperCase() },
    { headers: { "cache-control": "no-store" } }
  );
}
