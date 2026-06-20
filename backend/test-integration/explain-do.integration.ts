import { describe, expect, test } from "vitest";
import { call, signIn } from "./_util.ts";

// The in-process bun harness STUBS the Durable Objects, so the whole spend/generation half of
// /explain (SingleFlight coalescing → GlobalBudget reserve → provider → R2 write → GlobalBudget.mirror
// to D1) was never integration-covered. These run it for real through workerd.
describe("/explain through the real SingleFlight + GlobalBudget Durable Objects", () => {
  test("cache-miss generates via the DO chain, then serves an R2 HIT on repeat", async () => {
    const token = await signIn("u-explain");
    const first = await call("GET", "/explain?unit=serendipity&target=en", { token });
    expect(first.status).toBe(200);
    const f = (await first.json()) as { status: string; explanation: unknown };
    expect(f.status).toBe("generated"); // SingleFlight DO → budget reserve → mock provider → R2
    expect(f.explanation).toBeTruthy();

    const second = await call("GET", "/explain?unit=serendipity&target=en", { token });
    const s = (await second.json()) as { status: string; explanation: unknown };
    expect(s.status).toBe("hit"); // served from R2 at the edge — no DO hop
    expect(s.explanation).toEqual(f.explanation);
  });

  test("the global daily budget fails closed once exhausted (real DO atomic cap)", async () => {
    const token = await signIn("u-budget");
    // GLOBAL_DAILY_BUDGET_UNITS = 2 (vitest.config); two distinct units generate, the third is refused.
    // (The budget is keyed by UTC day; these 3 sub-second sequential calls would only mis-count if
    // they straddled exactly 00:00:00 UTC — a negligible ms-wide window — since the worker derives
    // `now` from Date.now() internally and can't be clock-pinned across the HTTP boundary.)
    expect((await call("GET", "/explain?unit=alpha&target=en", { token })).status).toBe(200);
    expect((await call("GET", "/explain?unit=bravo&target=en", { token })).status).toBe(200);
    const third = await call("GET", "/explain?unit=charlie&target=en", { token });
    expect(third.status).toBe(503);
    expect(((await third.json()) as { error: string }).error).toBe("budget_exhausted");
  });

  test("a cached unit still serves a HIT after the budget is exhausted (cache-first short-circuit)", async () => {
    const token = await signIn("u-hit");
    expect((await call("GET", "/explain?unit=alpha&target=en", { token })).status).toBe(200); // generate (1)
    expect((await call("GET", "/explain?unit=bravo&target=en", { token })).status).toBe(200); // generate (2 = cap)
    const hit = await call("GET", "/explain?unit=alpha&target=en", { token }); // already cached
    expect(hit.status).toBe(200);
    expect(((await hit.json()) as { status: string }).status).toBe("hit");
  });
});
