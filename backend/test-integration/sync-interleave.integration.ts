import { env } from "cloudflare:test";
import { describe, expect, test } from "vitest";
import { call, saveWord, signIn } from "./_util.ts";

// ENG-5 asked for "two simulated clients against a real Worker + D1 (Miniflare)" — the existing
// cross-device coverage runs the fold logic in-process. These drive it through the real HTTP
// router, session auth, and D1, asserting card state by querying the same real D1 via `env.DB`.
describe("ENG-5: multi-device review interleave through real Worker + D1", () => {
  test("a late, out-of-order offline rating is folded correctly (re-fold, not corrupt)", async () => {
    const token = await signIn("u-sync");
    const wordId = await saveWord(token, "interleave");

    // Client B (online) rates it now.
    expect((await call("POST", "/review", {
      token,
      body: { word_id: wordId, event_id: "B", rating: 3, client_review_ts: 2000 },
    })).status).toBe(200);

    // Client A (offline) flushes an EARLIER rating late, with clock skew, via /sync.
    const a = await call("POST", "/sync", {
      token,
      body: { events: [{ word_id: wordId, event_id: "A", rating: 3, client_review_ts: 1000 }] },
    });
    expect(a.status).toBe(200);
    expect(((await a.json()) as { results: { status: string }[] }).results[0]!.status).toBe("applied");

    // Both events folded in server-seq (flush) order → reps = 2, epoch unchanged. Assert real D1.
    const card = await env.DB.prepare(`SELECT reps, card_epoch FROM fsrs_cards WHERE word_id = ?`)
      .bind(wordId)
      .first<{ reps: number; card_epoch: number }>();
    expect(card?.reps).toBe(2);
    expect(card?.card_epoch).toBe(0);

    // Re-flushing the same event is idempotent — no double-count.
    await call("POST", "/sync", {
      token,
      body: { events: [{ word_id: wordId, event_id: "A", rating: 3, client_review_ts: 1000 }] },
    });
    const after = await env.DB.prepare(`SELECT reps FROM fsrs_cards WHERE word_id = ?`)
      .bind(wordId)
      .first<{ reps: number }>();
    expect(after?.reps).toBe(2);
  });

  test("delete-wins: a queued rating for a tombstoned unit is rejected on /sync", async () => {
    const token = await signIn("u-delwins");
    const wordId = await saveWord(token, "tombstoned");
    expect((await call("DELETE", `/words/${wordId}`, { token })).status).toBe(200);
    const res = await call("POST", "/sync", {
      token,
      body: { events: [{ word_id: wordId, event_id: "x", rating: 3, client_review_ts: 1000 }] },
    });
    expect(((await res.json()) as { results: { status: string }[] }).results[0]!.status).toBe("unit_deleted");
  });

  test("pre-login claim onto a tombstone resurrects with new-card FSRS (epoch++)", async () => {
    const token = await signIn("u-claim");
    const wordId = await saveWord(token, "resurrect");
    await call("POST", "/review", { token, body: { word_id: wordId, event_id: "r1", rating: 3, client_review_ts: 1000 } });
    expect((await call("DELETE", `/words/${wordId}`, { token })).status).toBe(200);

    // Claim the same (surface_unit, target) from a local install → resurrected onto the SAME row.
    const claim = await call("POST", "/words/claim", {
      token,
      body: { install_id: "inst-1", rows: [{ client_row_id: "row-1", surface_unit: "resurrect", target_language: "en" }] },
    });
    expect(claim.status).toBe(200);
    const r = ((await claim.json()) as { results: { status: string; wordId: string }[] }).results[0]!;
    expect(r.status).toBe("resurrected");
    expect(r.wordId).toBe(wordId);

    const word = await env.DB.prepare(`SELECT deleted_at, fsrs_epoch FROM words WHERE id = ?`)
      .bind(wordId)
      .first<{ deleted_at: number | null; fsrs_epoch: number }>();
    expect(word?.deleted_at).toBeNull(); // un-tombstoned
    expect(word?.fsrs_epoch).toBe(1); // epoch bumped → pre-delete reviews ignored (new-card)
  });
});
