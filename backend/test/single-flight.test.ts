import { test, expect } from "bun:test";
import { Coalescer } from "../src/single-flight.ts";

function deferred<T>() {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
}

test("N concurrent calls for the same key collapse to ONE invocation", async () => {
  const c = new Coalescer();
  let calls = 0;
  const gate = deferred<string>();
  const fn = async () => {
    calls += 1;
    return gate.promise;
  };

  const all = Promise.all([c.run("k", fn), c.run("k", fn), c.run("k", fn)]);
  gate.resolve("done");
  const results = await all;

  expect(calls).toBe(1); // single-flight
  expect(results).toEqual(["done", "done", "done"]); // followers got the leader's result
});

test("different keys run independently", async () => {
  const c = new Coalescer();
  let calls = 0;
  await Promise.all([
    c.run("a", async () => void calls++),
    c.run("b", async () => void calls++),
  ]);
  expect(calls).toBe(2);
});

test("single-flight, not a cache: a later call re-leads after the first settles", async () => {
  const c = new Coalescer();
  let calls = 0;
  await c.run("k", async () => void calls++);
  await c.run("k", async () => void calls++);
  expect(calls).toBe(2);
});

test("a rejection propagates to all followers and clears the slot", async () => {
  const c = new Coalescer();
  let calls = 0;
  const boom = async () => {
    calls += 1;
    throw new Error("boom");
  };
  // allSettled attaches handlers in the same tick (no spurious unhandled-rejection)
  const [a, b] = await Promise.allSettled([c.run("k", boom), c.run("k", boom)]);
  expect(a.status).toBe("rejected");
  expect(b.status).toBe("rejected");
  if (a.status === "rejected") expect((a.reason as Error).message).toBe("boom");
  expect(calls).toBe(1); // leader ran once; follower shared the rejection
  // slot cleared — next call re-leads
  await c.run("k", async () => void calls++);
  expect(calls).toBe(2);
});
