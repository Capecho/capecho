import type { ExplanationProvider, GenerateResult } from "../provider.ts";

/**
 * Fail-closed provider for when no real (zero-retention, T8) explanation vendor is
 * configured AND the dev mock is not explicitly enabled. Generation MUST fail closed
 * here rather than fall through to a stand-in: a structurally-valid placeholder would
 * pass cache-write validation and POISON the shared public R2 cache with fake
 * definitions that stick until manually purged. Throwing means the orchestration
 * treats it as a transport error → refunds the reserved budget → writes nothing.
 */
export class UnconfiguredProvider implements ExplanationProvider {
  async generate(): Promise<GenerateResult> {
    throw new Error("explanation provider not configured — failing closed (no generation, no cache write)");
  }
}
