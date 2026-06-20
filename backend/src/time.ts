// Day-boundary helpers. The per-user quota day uses the ACCOUNT'S IANA timezone so
// the daily cap resets at the user's local midnight (DST/travel correct, T10). The
// global budget day is UTC (one hot row, machine-global).

/** 'YYYY-MM-DD' for the given instant in the account's IANA timezone. */
export function accountDayKey(nowMs: number, ianaTimezone: string): string {
  // en-CA renders ISO-shaped YYYY-MM-DD; timeZone applies the local day boundary.
  const fmt = new Intl.DateTimeFormat("en-CA", {
    timeZone: ianaTimezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  return fmt.format(new Date(nowMs));
}

/** 'YYYY-MM-DD' in UTC — the global_budget day key. */
export function utcDayKey(nowMs: number): string {
  return new Date(nowMs).toISOString().slice(0, 10);
}

/**
 * Epoch-ms of the START (local midnight) of the day containing `nowMs`, in the account's
 * IANA timezone. The companion to accountDayKey for daily accounting that compares stored
 * instants (e.g. new-card introductions) rather than day-key strings: for any instant t,
 *   accountDayKey(t, tz) === accountDayKey(nowMs, tz)
 *     ⟺  accountDayStartMs(nowMs, tz) <= t < accountDayStartMs(<next day>, tz).
 * DST/travel correct — resolves the wall-clock midnight to its true UTC instant.
 */
export function accountDayStartMs(nowMs: number, ianaTimezone: string): number {
  const key = accountDayKey(nowMs, ianaTimezone); // 'YYYY-MM-DD' local
  const y = Number(key.slice(0, 4));
  const m = Number(key.slice(5, 7));
  const d = Number(key.slice(8, 10));
  // The wall-clock midnight (00:00 local) read as if it were a UTC instant.
  const wallMidnightAsUtc = Date.UTC(y, m - 1, d, 0, 0, 0);
  // Local midnight = wallMidnightAsUtc - offset(at that instant). The offset can shift
  // across a DST boundary, so seed with the offset at `nowMs` then refine once at the
  // guessed instant — a fixed point. DST transitions never land on midnight in practice,
  // so the offset is stable within an hour of the target and one refinement converges.
  let instant = wallMidnightAsUtc - tzOffsetMs(nowMs, ianaTimezone);
  instant = wallMidnightAsUtc - tzOffsetMs(instant, ianaTimezone);
  return instant;
}

/** Signed ms by which local wall-clock in `tz` is ahead of UTC at instant `t`. */
function tzOffsetMs(t: number, ianaTimezone: string): number {
  const fmt = new Intl.DateTimeFormat("en-US", {
    timeZone: ianaTimezone,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
  const parts = fmt.formatToParts(new Date(t));
  const val = (type: string) => Number(parts.find((p) => p.type === type)!.value);
  const asUtc = Date.UTC(val("year"), val("month") - 1, val("day"), val("hour"), val("minute"), val("second"));
  // Subtract the SECOND-floored t: the formatter truncates sub-second, so comparing
  // against raw `t` would leak its millisecond fraction into the offset (and thence into
  // accountDayStartMs, returning "local midnight + now's ms"). The offset is whole-second.
  return asUtc - Math.floor(t / 1000) * 1000;
}
