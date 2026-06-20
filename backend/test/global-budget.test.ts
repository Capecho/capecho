import { test, expect } from "bun:test";
import { GlobalBudget, type Env } from "../src/index.ts";

// Minimal fakes: GlobalBudget only touches state.storage.{get,put} and env.DB.prepare().bind().run().
function fakeState(): { state: DurableObjectState; store: Map<string, number> } {
  const store = new Map<string, number>();
  const state = {
    storage: {
      get: async (k: string) => store.get(k),
      put: async (k: string, v: number) => {
        store.set(k, v);
      },
    },
  } as unknown as DurableObjectState;
  return { state, store };
}

function envWithMirror(run: () => Promise<unknown>): Env {
  const stmt = { bind: () => ({ run }) };
  return { DB: { prepare: () => stmt } } as unknown as Env;
}

const reserveReq = (key: string, cost: number, cap: number) =>
  new Request("https://global-budget.internal/", {
    method: "POST",
    body: JSON.stringify({ action: "reserve", key, cost, cap }),
  });

test("reserve consumes exactly one unit when the D1 mirror succeeds", async () => {
  const { state, store } = fakeState();
  const gb = new GlobalBudget(state, envWithMirror(async () => ({})));
  const res = await gb.fetch(reserveReq("2026-05-27", 1, 10));
  const body = (await res.json()) as { ok: boolean; spent: number };
  expect(body.ok).toBe(true);
  expect(body.spent).toBe(1);
  expect(store.get("2026-05-27")).toBe(1);
});

test("reserve ROLLS BACK the DO ledger when the D1 mirror fails — no ratcheting the cap with zero spend", async () => {
  const { state, store } = fakeState();
  const gb = new GlobalBudget(
    state,
    envWithMirror(async () => {
      throw new Error("D1 unavailable");
    }),
  );
  const res = await gb.fetch(reserveReq("2026-05-27", 1, 10));
  expect(res.ok).toBe(false); // fails closed (503) so the client doesn't generate
  expect(res.status).toBe(503);
  expect(store.get("2026-05-27") ?? 0).toBe(0); // the reserved unit was refunded — cap intact
});

test("repeated mirror failures never erode the cap (the leak class stays closed)", async () => {
  const { state, store } = fakeState();
  const gb = new GlobalBudget(
    state,
    envWithMirror(async () => {
      throw new Error("D1 down");
    }),
  );
  for (let i = 0; i < 5; i++) {
    const res = await gb.fetch(reserveReq("2026-05-27", 1, 10));
    expect(res.ok).toBe(false);
  }
  expect(store.get("2026-05-27") ?? 0).toBe(0); // five failed reserves, zero units consumed
});
