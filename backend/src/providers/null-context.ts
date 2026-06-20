import type { ContextExplanationProvider, ContextGenerateResult } from "../context-provider.ts";

/**
 * Fail-closed context provider for when no real zero-retention vendor is configured
 * AND the dev mock is not explicitly enabled. Throwing means the orchestration treats
 * it as a transport error → refunds the reservation AND the global budget → stores
 * nothing. Prevents a placeholder gloss from being persisted against a user's context.
 */
export class UnconfiguredContextProvider implements ContextExplanationProvider {
  async generate(): Promise<ContextGenerateResult> {
    throw new Error("context explanation provider not configured — failing closed (no generation)");
  }
}
