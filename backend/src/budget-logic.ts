// Global daily AI-spend cap — the logic the GlobalBudget Durable Object serializes.
// Modeled over an injected store so it's unit-testable; the DO guarantees the
// read-modify-write is atomic (single-threaded per id) and FAILS CLOSED — the
// orchestration treats any budget error/unavailability as "denied" (no generation).

export interface BudgetStore {
  get(key: string): Promise<number | undefined>;
  put(key: string, value: number): Promise<void>;
}

export interface BudgetDecision {
  ok: boolean;
  spent: number;
  cap: number;
}

// The budget surface the orchestration depends on. Implemented in-process by
// BudgetLedger (tests) and by a Durable-Object client (production) — same contract.
export interface Budget {
  reserve(key: string, cost: number, cap: number): Promise<BudgetDecision>;
  refund(key: string, cost: number): Promise<void>;
  spent(key: string): Promise<number>;
}

export class BudgetLedger implements Budget {
  constructor(private readonly store: BudgetStore) {}

  /** Reserve `cost` units against `key` (a day). Reserve-BEFORE-spend so the cap can't be raced past (ENG-6). */
  async reserve(key: string, cost: number, cap: number): Promise<BudgetDecision> {
    const spent = (await this.store.get(key)) ?? 0;
    if (spent + cost > cap) return { ok: false, spent, cap };
    const next = spent + cost;
    await this.store.put(key, next);
    return { ok: true, spent: next, cap };
  }

  /** Give back a reservation when generation never spent (transport error before the model call). */
  async refund(key: string, cost: number): Promise<void> {
    const spent = (await this.store.get(key)) ?? 0;
    await this.store.put(key, Math.max(0, spent - cost));
  }

  async spent(key: string): Promise<number> {
    return (await this.store.get(key)) ?? 0;
  }
}

/** In-memory store for tests. */
export class MemoryBudgetStore implements BudgetStore {
  private readonly m = new Map<string, number>();
  async get(key: string): Promise<number | undefined> {
    return this.m.get(key);
  }
  async put(key: string, value: number): Promise<void> {
    this.m.set(key, value);
  }
}
