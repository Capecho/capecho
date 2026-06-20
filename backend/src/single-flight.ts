// Single-flight coalescing: concurrent cache-miss generations for the SAME key
// collapse to one underlying call; the rest await the leader's result and never
// reserve spend (ENG-6). In production the SingleFlight Durable Object routes by
// cache key (one isolate per key) and runs this in-isolate coalescer.

export interface SingleFlight {
  run<T>(key: string, fn: () => Promise<T>): Promise<T>;
}

export class Coalescer implements SingleFlight {
  private readonly inflight = new Map<string, Promise<unknown>>();

  async run<T>(key: string, fn: () => Promise<T>): Promise<T> {
    const existing = this.inflight.get(key) as Promise<T> | undefined;
    if (existing) return existing; // follower — joins the leader's in-flight call

    const p = Promise.resolve().then(fn); // leader — guards against a sync throw in fn
    this.inflight.set(key, p);
    try {
      return await p;
    } finally {
      this.inflight.delete(key); // single-flight, not a cache: the next miss re-leads
    }
  }
}
