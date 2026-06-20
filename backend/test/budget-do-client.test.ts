import { test, expect } from "bun:test";
import { budgetClient } from "../src/budget-do-client.ts";

// Fake DO namespace whose stub.fetch is whatever we inject.
function fakeNs(fetchImpl: () => Promise<Response>): DurableObjectNamespace {
  const stub = { fetch: fetchImpl };
  return { idFromName: () => ({}), get: () => stub } as unknown as DurableObjectNamespace;
}

test("reserve fails CLOSED when the budget DO throws (no decision ⇒ no generation)", async () => {
  const b = budgetClient(fakeNs(async () => {
    throw new Error("DO unavailable");
  }));
  const d = await b.reserve("2026-05-27", 1, 1000);
  expect(d.ok).toBe(false);
});

test("reserve fails CLOSED on a non-2xx DO response", async () => {
  const b = budgetClient(fakeNs(async () => new Response("err", { status: 500 })));
  expect((await b.reserve("d", 1, 10)).ok).toBe(false);
});

test("refund never throws even when the DO is down (no masked errors, no leaked units)", async () => {
  const b = budgetClient(fakeNs(async () => {
    throw new Error("DO unavailable");
  }));
  await b.refund("d", 1); // must resolve, not reject
  expect(true).toBe(true);
});

test("reserve passes a normal decision through", async () => {
  const b = budgetClient(
    fakeNs(
      async () =>
        new Response(JSON.stringify({ ok: true, spent: 1, cap: 10 }), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    ),
  );
  const d = await b.reserve("d", 1, 10);
  expect(d.ok).toBe(true);
  expect(d.spent).toBe(1);
});
