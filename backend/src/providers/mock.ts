import type {
  ExplanationProvider,
  GenerateRequest,
  GenerateResult,
} from "../provider.ts";

export type MockBehavior = (
  req: GenerateRequest,
) => GenerateResult | Promise<GenerateResult>;

/**
 * Deterministic stand-in for the (not-yet-keyed) zero-retention explanation vendor.
 * Doubles as the dev binding and the test double. Pass a `behavior` to simulate
 * failure modes (throw = transport error; return malformed raw = cache-write
 * rejection) and to count invocations for single-flight / budget tests.
 */
export class MockExplanationProvider implements ExplanationProvider {
  public calls = 0;

  constructor(private readonly behavior?: MockBehavior) {}

  async generate(req: GenerateRequest): Promise<GenerateResult> {
    this.calls += 1;
    if (this.behavior) return this.behavior(req);
    return {
      raw: {
        unit: req.unit,
        // Exercise the reading-centric senses metadata in dev/tests: one reading, both pronunciation
        // slots, one POS group carrying the must-pass primary sense. Fabricated values are fine for the
        // mock — the real accuracy gate is the eval.
        readings: [
          {
            pronunciationPrimary: "mɑk",
            pronunciationSecondary: "mɒk",
            pos: [
              {
                partOfSpeech: "noun",
                senses: [`a mock meaning of "${req.normalizedUnit}"`],
              },
            ],
          },
        ],
      },
    };
  }
}
