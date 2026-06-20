/// <reference types="@cloudflare/workers-types" />
import type { WordExplanation } from "./provider.ts";

// The shared explanation cache (R2 + CDN). Only validated word-level explanations
// are ever written here (CEO-8). Context glosses are private/encrypted and NEVER
// land in this shared cache.

export interface ExplanationCache {
  get(key: string): Promise<WordExplanation | null>;
  put(key: string, value: WordExplanation): Promise<void>;
}

export function fromR2(bucket: R2Bucket): ExplanationCache {
  return {
    async get(key: string): Promise<WordExplanation | null> {
      const obj = await bucket.get(key);
      if (!obj) return null;
      try {
        return JSON.parse(await obj.text()) as WordExplanation;
      } catch {
        return null; // a corrupt blob reads as a miss — regenerate + overwrite
      }
    },
    async put(key: string, value: WordExplanation): Promise<void> {
      await bucket.put(key, JSON.stringify(value), {
        httpMetadata: { contentType: "application/json; charset=utf-8" },
      });
    },
  };
}

/** In-memory cache for tests. */
export class MemoryCache implements ExplanationCache {
  private readonly m = new Map<string, string>();
  async get(key: string): Promise<WordExplanation | null> {
    const v = this.m.get(key);
    return v ? (JSON.parse(v) as WordExplanation) : null;
  }
  async put(key: string, value: WordExplanation): Promise<void> {
    this.m.set(key, JSON.stringify(value));
  }
  get size(): number {
    return this.m.size;
  }
}
