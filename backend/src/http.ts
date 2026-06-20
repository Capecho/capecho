export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

export function problem(error: string, status: number, detail?: string): Response {
  return json(detail ? { error, detail } : { error }, status);
}

/** A downloadable file response (e.g. the CSV export). `filename` is server-built from a
 *  date stamp — no user input flows in, so the Content-Disposition needs no sanitizing.
 *  `Cache-Control: private, no-store` because these downloads carry the user's OWN decrypted
 *  data (export = decrypted context text): a browser/CDN/proxy must never store or share it,
 *  especially as a GET response under header-trust auth (dev/staging). */
export function attachment(body: string, contentType: string, filename: string): Response {
  return new Response(body, {
    status: 200,
    headers: {
      "content-type": contentType,
      "content-disposition": `attachment; filename="${filename}"`,
      "cache-control": "private, no-store",
    },
  });
}

/**
 * Account id for the request. PLACEHOLDER until M3 auth.
 *
 * The `x-capecho-user-id` header is client-supplied and forgeable, so it is honored
 * ONLY when the deployment explicitly opts in via `DEV_TRUST_USER_HEADER="true"` (dev/
 * staging). In production the flag is unset, so this returns `null` for everyone:
 * /explain is anonymous HIT-only and account-gated routes 401. This keeps an
 * unauthenticated caller from setting the header to pose as a signed-in user and burn
 * generation capacity under only the global cap (Codex P1). Real verified auth is M3.
 */
export function userIdFrom(request: Request, trustHeader: boolean): string | null {
  if (!trustHeader) return null;
  const id = request.headers.get("x-capecho-user-id");
  return id && id.trim().length > 0 ? id.trim() : null;
}

/** Generous ceiling on a JSON request body. Legitimate payloads are small (a sync/claim batch is
 *  capped at 500 rows, a context at 2000 chars), so this never trips for real traffic — it exists
 *  only to reject a multi-megabyte body before it is read into the isolate and parsed. Oversize ⇒
 *  null, which every caller already treats as a bad request. (`POST /metrics` keeps its own tighter
 *  16 KiB guard.) */
export const MAX_JSON_BODY_BYTES = 1024 * 1024; // 1 MiB

export async function readJson<T>(
  request: Request,
  maxBytes: number = MAX_JSON_BODY_BYTES,
): Promise<T | null> {
  // Reject on the declared length before touching the body (Workers buffers it, so an oversized
  // Content-Length means an oversized allocation). The header can be absent or wrong, so the exact
  // UTF-8 byte check below is the real bound.
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) return null;
  try {
    const text = await request.text();
    if (new TextEncoder().encode(text).length > maxBytes) return null;
    return JSON.parse(text) as T;
  } catch {
    return null;
  }
}
