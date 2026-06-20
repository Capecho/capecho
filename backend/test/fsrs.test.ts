import { test, expect } from "bun:test";
import { projectCard } from "../src/fsrs.ts";

const DAY = 86_400_000;

// Conformance pin: a fixed event sequence must yield these exact ts-fsrs outputs. If a
// library upgrade or a default-parameter change alters the algorithm, this fails —
// turning a silent schedule shift into a visible, reviewable diff (US-1.2: "conformance
// tests against the reference implementation").
test("conformance: a fixed Good/Good/Again sequence yields pinned FSRS outputs", () => {
  const p = projectCard(0, [
    { rating: 3, elapsedMs: 0 }, // Good (first review)
    { rating: 3, elapsedMs: 3 * DAY }, // Good, 3 days later
    { rating: 1, elapsedMs: 7 * DAY }, // Again, 7 days later
  ]);
  // The closing Again is a LAPSE → `relearning` with the single 10-minute relearn step (see fsrs.ts):
  // a just-forgotten word echoes back the same session, not a day+ later.
  expect(p).toEqual({
    stability: 1.61459793,
    difficulty: 7.39223814,
    dueAt: 864600000, // lastReview (10d) + 10m relearn step
    lastReviewAt: 864000000, // 10 days of clamped elapsed
    reps: 3,
    lapses: 1,
    state: "relearning",
  });
});

test("conformance: a new card's first Good graduates to review days out (past the single 10m step)", () => {
  // The fix for "I rated Good but it kept coming back in 10 min": Good graduates PAST the single 10m
  // learning step straight into stability-based scheduling — due in 2 DAYS in `review`, not 10 minutes
  // in `learning`. (The 10m step only catches Again/Hard — the ratings you got wrong.)
  expect(projectCard(0, [{ rating: 3, elapsedMs: 0 }])).toEqual({
    stability: 2.3065,
    difficulty: 2.11810397,
    dueAt: 172800000, // 2 days
    lastReviewAt: 0,
    reps: 1,
    lapses: 0,
    state: "review",
  });
});

test("a never-reviewed card projects null (it has no folded state yet)", () => {
  expect(projectCard(0, [])).toBeNull();
});

test("the fold clock is monotonic: a negative elapsed is floored to 0 (skew can't rewind FSRS)", () => {
  const withNegative = projectCard(0, [
    { rating: 3, elapsedMs: 0 },
    { rating: 3, elapsedMs: -5 * DAY },
  ]);
  const withZero = projectCard(0, [
    { rating: 3, elapsedMs: 0 },
    { rating: 3, elapsedMs: 0 },
  ]);
  expect(withNegative).toEqual(withZero!);
});

test("repeated Good grows stability (the schedule lengthens)", () => {
  const once = projectCard(0, [{ rating: 3, elapsedMs: 0 }])!;
  const thrice = projectCard(0, [
    { rating: 3, elapsedMs: 0 },
    { rating: 3, elapsedMs: 10 * DAY },
    { rating: 3, elapsedMs: 30 * DAY },
  ])!;
  expect(thrice.stability).toBeGreaterThan(once.stability);
  expect(thrice.state).toBe("review");
});

test("the schedule is capped at maximum_interval (~365d) — a mastered word still echoes back within a year", () => {
  // Easy-spam drives stability arbitrarily high; the interval must stay clamped near the 365-day cap
  // (Easy lands at 367d — ts-fsrs adds +1/+2 days re-ordering Hard<Good<Easy after the clamp). Without
  // the cap, ts-fsrs's default maximum_interval is 36500 days (100y) — so this guards the "at least
  // yearly" promise against a dropped or changed param.
  const p = projectCard(0, Array.from({ length: 8 }, () => ({ rating: 4 as const, elapsedMs: 400 * DAY })))!;
  const intervalDays = (p.dueAt - p.lastReviewAt) / DAY;
  expect(intervalDays).toBeGreaterThan(360);
  expect(intervalDays).toBeLessThanOrEqual(367);
});

test("a lapsed card relearns in 10m, then a Good graduates it back to review (forgot → same-day → recover)", () => {
  // The founder's core ask: a forgotten LEARNED word re-surfaces the same day, then recovers cleanly.
  const lapsed = projectCard(0, [
    { rating: 3, elapsedMs: 0 }, // Good
    { rating: 3, elapsedMs: 3 * DAY }, // Good
    { rating: 1, elapsedMs: 7 * DAY }, // Again → LAPSE
  ])!;
  expect(lapsed.state).toBe("relearning");
  expect(lapsed.dueAt - lapsed.lastReviewAt).toBe(10 * 60_000); // exactly the 10-minute relearn step

  const recovered = projectCard(0, [
    { rating: 3, elapsedMs: 0 },
    { rating: 3, elapsedMs: 3 * DAY },
    { rating: 1, elapsedMs: 7 * DAY },
    { rating: 3, elapsedMs: 10 * 60_000 }, // Good on the 10m relearn step
  ])!;
  expect(recovered.state).toBe("review"); // graduated back out of relearning
  expect(recovered.lapses).toBe(1);
  expect(recovered.dueAt - recovered.lastReviewAt).toBeGreaterThanOrEqual(DAY); // day-scale, not another 10m
});
