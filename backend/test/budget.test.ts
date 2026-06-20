import { test, expect } from "bun:test";
import { BudgetLedger, MemoryBudgetStore } from "../src/budget-logic.ts";

const ledger = () => new BudgetLedger(new MemoryBudgetStore());

test("reserves up to the cap, then fails closed", async () => {
  const b = ledger();
  for (let i = 0; i < 5; i++) expect((await b.reserve("d", 1, 5)).ok).toBe(true);
  const over = await b.reserve("d", 1, 5);
  expect(over.ok).toBe(false);
  expect(over.spent).toBe(5);
});

test("a single oversized reservation is rejected without partial spend", async () => {
  const b = ledger();
  const d = await b.reserve("d", 10, 5);
  expect(d.ok).toBe(false);
  expect(await b.spent("d")).toBe(0);
});

test("refund returns capacity (transport error before spend)", async () => {
  const b = ledger();
  await b.reserve("d", 3, 5);
  await b.refund("d", 3);
  expect(await b.spent("d")).toBe(0);
  expect((await b.reserve("d", 5, 5)).ok).toBe(true);
});

test("days are independent", async () => {
  const b = ledger();
  await b.reserve("2026-05-27", 5, 5);
  expect((await b.reserve("2026-05-27", 1, 5)).ok).toBe(false);
  expect((await b.reserve("2026-05-28", 1, 5)).ok).toBe(true);
});

test("refund never goes negative", async () => {
  const b = ledger();
  await b.refund("d", 3);
  expect(await b.spent("d")).toBe(0);
});
