import type {
  ContextExplanationProvider,
  ContextGenerateRequest,
  ContextGenerateResult,
} from "../context-provider.ts";

export type MockContextBehavior = (
  req: ContextGenerateRequest,
) => ContextGenerateResult | Promise<ContextGenerateResult>;

/**
 * Deterministic stand-in for the (not-yet-keyed) zero-retention context vendor.
 * Doubles as the dev binding and the test double. Pass a `behavior` to simulate
 * failure modes (throw = transport error; return a refusal/malformed raw = validation
 * rejection) and to count invocations for quota/budget tests.
 */
export class MockContextProvider implements ContextExplanationProvider {
  public calls = 0;
  /** The last request this provider saw — lets tests assert what the ORCHESTRATION passed
   *  (e.g. that contextLanguage arrives null rather than defaulted to the target). */
  public lastRequest: ContextGenerateRequest | null = null;

  constructor(private readonly behavior?: MockContextBehavior) {}

  async generate(req: ContextGenerateRequest): Promise<ContextGenerateResult> {
    this.calls += 1;
    this.lastRequest = req;
    if (this.behavior) return this.behavior(req);
    // contextLanguage is null in the NORMAL case (unknown unless script-certain) — phrase
    // around it rather than interpolating a "null".
    const ctx = req.contextLanguage == null ? "this" : `this ${req.contextLanguage}`;
    return {
      raw: {
        meaning: `In ${ctx} sentence "${req.unit}" is used in its fitting sense; the text means, in ${req.explanationLanguage}: ${req.contextText}`,
      },
    };
  }
}
