import { env } from "cloudflare:test";
import { describe, expect, test } from "vitest";
import { call, saveWord, signIn } from "./_util.ts";

// The bun harness could only exercise the bun:sqlite BLOB branch (Uint8Array); real D1 returns
// ArrayBuffer (contexts.ts toBytes). These run the encrypted-context write/read/export through real
// D1, AND prove the auth session unlocks the API end-to-end through workerd.
describe("auth + encrypted context through real D1 (the ArrayBuffer BLOB path)", () => {
  test("sign in → save word → store + read back an encrypted context → export decrypts it", async () => {
    const token = await signIn("u-ctx");
    const wordId = await saveWord(token, "ephemeral");

    const create = await call("POST", "/contexts", {
      token,
      body: { word_id: wordId, context_text: "an ephemeral, fleeting moment", span_start: 3, span_end: 12 },
    });
    expect(create.status).toBe(201);

    // GET decrypts the BLOB read back from REAL D1 (ArrayBuffer, not Uint8Array).
    const list = await call("GET", `/contexts?word_id=${wordId}`, { token });
    expect(list.status).toBe(200);
    const ctx = ((await list.json()) as { contexts: { contextText: string }[] }).contexts;
    expect(ctx).toHaveLength(1);
    expect(ctx[0]!.contextText).toBe("an ephemeral, fleeting moment");

    // At rest in REAL D1 it's a binary BLOB and the ciphertext is NOT the plaintext (T8 envelope).
    // The round-trip above already proves the worker's read path (contexts.ts toBytes) handles the
    // BLOB type this runtime hands back — the coverage the bun:sqlite harness couldn't give.
    const row = await env.DB.prepare(`SELECT context_ciphertext FROM word_contexts WHERE word_id = ?`)
      .bind(wordId)
      .first<{ context_ciphertext: ArrayBuffer | Uint8Array }>();
    const blob = row!.context_ciphertext;
    const bytes = blob instanceof Uint8Array ? blob : new Uint8Array(blob);
    const plaintext = new TextEncoder().encode("an ephemeral, fleeting moment");
    expect(bytes.byteLength).toBeGreaterThan(plaintext.byteLength); // AES-GCM adds a 16-byte tag
    expect(new TextDecoder().decode(bytes)).not.toContain("ephemeral"); // not plaintext at rest
    expect([...bytes]).not.toEqual([...plaintext]); // and not a mere byte-reorder of the plaintext

    // Export decrypts the user's own context through the same real-D1 path.
    const exp = await call("GET", "/export?format=csv", { token });
    expect(exp.status).toBe(200);
    expect(await exp.text()).toContain("ephemeral");
  });

  test("authed routes require a valid bearer (no token / bad token → 401)", async () => {
    expect((await call("GET", "/words")).status).toBe(401);
    expect((await call("GET", "/words", { token: "garbage" })).status).toBe(401);
  });

  test("a signed-out session can no longer reach an authed route", async () => {
    const token = await signIn("u-signout");
    expect((await call("GET", "/words", { token })).status).toBe(200);
    expect((await call("POST", "/auth/signout", { token })).status).toBe(200);
    expect((await call("GET", "/words", { token })).status).toBe(401); // revoked in real D1
  });

  test("contexts are private — another account cannot read them", async () => {
    const owner = await signIn("owner");
    const wordId = await saveWord(owner, "clandestine");
    await call("POST", "/contexts", { token: owner, body: { word_id: wordId, context_text: "a clandestine meeting" } });

    const intruder = await signIn("intruder");
    const list = await call("GET", `/contexts?word_id=${wordId}`, { token: intruder });
    expect(((await list.json()) as { contexts: unknown[] }).contexts).toHaveLength(0); // same-owner scoping
  });
});
