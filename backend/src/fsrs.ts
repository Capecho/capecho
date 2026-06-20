import { fsrs, createEmptyCard, generatorParameters, Rating, State, type Card, type FSRS } from "ts-fsrs";

// Server-authoritative FSRS (US-1.2, §11). The library (ts-fsrs, the canonical FSRS-6
// TS implementation) is wrapped here so the rest of the backend is library-agnostic and
// a version bump is caught by the conformance test. FSRS runs ONLY on the server; the
// card state is a PURE FOLD over the ordered event log (ENG-5) — recomputed from events
// on every change, never mutated in place, so a late out-of-order event is trivially
// correct on re-fold.

export type RatingValue = 1 | 2 | 3 | 4; // Again | Hard | Good | Easy
export type CardStateName = "new" | "learning" | "review" | "relearning";

export interface ProjectedCard {
  stability: number;
  difficulty: number;
  dueAt: number; // epoch ms — server-authoritative; clients render, never compute
  lastReviewAt: number; // epoch ms
  reps: number;
  lapses: number;
  state: CardStateName;
}

export interface FoldEvent {
  rating: RatingValue;
  /** clamped elapsed since the previous applied review, in ms (>= 0) */
  elapsedMs: number;
}

// FSRS-6 parameters, tuned for capture-and-ECHO vocabulary review. learning_steps + maximum_interval
// depart from the ts-fsrs defaults; relearning_steps + request_retention are pinned explicitly — they
// equal today's defaults, but stating them stops a future library default-drift from moving our schedule:
//
//  • FUZZ off — fuzz randomizes intervals; the pure-fold model (ENG-5) recomputes the card from its
//    events on every change, so a non-deterministic engine would give a different due date on each
//    re-fold. Fuzz must stay off for the projection to be reproducible (the conformance test pins it).
//
//  • LEARNING + RELEARNING steps = a SINGLE "10m" — the FSRS tutorial's own recommendation (one short,
//    same-day step; never multiple). It's a re-drill safety net for the ratings you got WRONG:
//      – Forget (Again), new OR lapsed → 10m: you missed it, so it echoes back this session/today
//        (the forgetting curve is steepest right after a failure — a 1-day wait is too coarse).
//      – Hard on a new card → ~15m.
//    Good/Easy GRADUATE straight past the step into stability-based scheduling — no 10-minute bounce
//    (the original "I rated Good but it kept coming back" bug). The ts-fsrs default ["1m","10m"] caused
//    that bounce; removing steps entirely made a just-forgotten word wait a full day. One 10m step is
//    the middle path.
//
//  • request_retention 0.9 — FSRS default + recommended 90%-recall target. First Good ≈ 2d, Easy ≈ 8d,
//    and the interval GROWS on every recall (Good-chain ≈ 2d → 11d → 46d → 163d → 1.4y …). That growth
//    IS "mastery": a well-known word spaces itself out toward years, never a fixed 8-day loop.
//
//  • maximum_interval 365 — cap the growth so even a "mastered" word echoes back within ~1 year (Easy
//    tops out at 367d: ts-fsrs adds +1/+2 days re-ordering Hard<Good<Easy AFTER the clamp). The library
//    default is 36500 days (100y); capping also stops an over-eager streak of Easy from hiding a word
//    for years. A lapse resets stability and the card re-enters the 10m relearn loop.
//
// Pinning the engine + params here is what the conformance test guards against.
const engine: FSRS = fsrs(
  generatorParameters({
    enable_fuzz: false,
    learning_steps: ["10m"],
    relearning_steps: ["10m"],
    request_retention: 0.9,
    maximum_interval: 365,
  }),
);

type Grade = Parameters<FSRS["next"]>[2];
const GRADE: Record<RatingValue, Grade> = {
  1: Rating.Again,
  2: Rating.Hard,
  3: Rating.Good,
  4: Rating.Easy,
} as Record<RatingValue, Grade>;

const STATE_NAME: Record<number, CardStateName> = {
  [State.New]: "new",
  [State.Learning]: "learning",
  [State.Review]: "review",
  [State.Relearning]: "relearning",
};

/**
 * Recompute a card from its ordered events. ORDER is the caller's responsibility (pass
 * events in server_seq order); ELAPSED comes from each event's clamped elapsed, applied
 * to a synthetic monotonic clock — so a skewed or out-of-order client clock can never
 * feed FSRS a negative/inflated interval. Returns null for a never-reviewed card.
 */
export function projectCard(createdAtMs: number, events: FoldEvent[]): ProjectedCard | null {
  if (events.length === 0) return null;
  let card: Card = createEmptyCard(new Date(createdAtMs));
  let clock = createdAtMs;
  for (const e of events) {
    clock += Math.max(0, e.elapsedMs); // monotonic — never moves backwards
    card = engine.next(card, new Date(clock), GRADE[e.rating]).card;
  }
  return {
    stability: card.stability,
    difficulty: card.difficulty,
    dueAt: card.due.getTime(),
    lastReviewAt: (card.last_review ?? new Date(clock)).getTime(),
    reps: card.reps,
    lapses: card.lapses,
    state: STATE_NAME[card.state] ?? "review",
  };
}
