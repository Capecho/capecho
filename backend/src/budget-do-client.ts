/// <reference types="@cloudflare/workers-types" />
import type { Budget, BudgetDecision } from "./budget-logic.ts";

// Client over the GlobalBudget Durable Object. One global id ("global") so the daily
// cap is a single serialized counter across all isolates — the hard, fail-closed
// cost ceiling. Satisfies the same `Budget` contract as the in-process ledger.

export interface BudgetWire {
  action: "reserve" | "refund" | "spent";
  key: string;
  cost?: number;
  cap?: number;
}

export function budgetClient(ns: DurableObjectNamespace): Budget {
  const stub = ns.get(ns.idFromName("global"));
  // Returns null on any transport/parse failure so callers can FAIL CLOSED. The DO is
  // the cost ceiling; if it's briefly unavailable we must deny generation, never throw
  // (an uncaught throw here would mask the result as a 500 and — on the refund path —
  // permanently leak a reserved budget unit, ratcheting the cap down with no spend).
  const call = async (body: BudgetWire): Promise<Record<string, unknown> | null> => {
    try {
      const res = await stub.fetch("https://global-budget.internal/", {
        method: "POST",
        body: JSON.stringify(body),
      });
      if (!res.ok) return null;
      return (await res.json()) as Record<string, unknown>;
    } catch {
      return null;
    }
  };
  return {
    async reserve(key, cost, cap): Promise<BudgetDecision> {
      const r = await call({ action: "reserve", key, cost, cap });
      if (r && typeof r.ok === "boolean") return r as unknown as BudgetDecision;
      return { ok: false, spent: 0, cap }; // fail closed: no decision ⇒ no generation
    },
    async refund(key, cost): Promise<void> {
      await call({ action: "refund", key, cost }); // best-effort; never throws
    },
    async spent(key): Promise<number> {
      const r = await call({ action: "spent", key });
      return Number(r?.spent ?? 0);
    },
  };
}
