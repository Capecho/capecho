import { test, expect, beforeEach } from "bun:test";
import { freshDb, ids } from "./helpers/db.ts";
import { getOrCreateAccount } from "../src/auth.ts";
import { getAccount, updateAccountPrefs, markAccountDeleted, parseAccountPatch } from "../src/accounts.ts";
import type { Sql } from "../src/sql.ts";

let sql: Sql;
let newId: () => string;

beforeEach(() => {
  ({ sql } = freshDb());
  newId = ids("acc");
});

function account(): Promise<string> {
  return getOrCreateAccount(
    sql,
    { provider: "apple", subject: "s", timezone: "UTC", learningLanguage: "en" },
    1000,
    newId,
  );
}

test("a fresh account has reminders off + no time (migration 0005 defaults)", async () => {
  const a = await getAccount(sql, await account());
  expect(a?.reminder_enabled).toBe(0);
  expect(a?.reminder_time).toBeNull();
});

test("a fresh account defaults to explanation-follows-learning = 1 (immersion default, §9)", async () => {
  // getOrCreateAccount writes the literal 1 (auth.ts) and getAccount reads the column back — a typo
  // in either column name would otherwise pass every test (the rest only exercise parseAccountPatch).
  const a = await getAccount(sql, await account());
  expect(a?.explanation_follows_learning).toBe(1);
});

test("updateAccountPrefs round-trips the explanation-follows-learning flag", async () => {
  const id = await account();
  expect(await updateAccountPrefs(sql, id, { explanationFollowsLearning: false })).toBe(true);
  expect((await getAccount(sql, id))?.explanation_follows_learning).toBe(0);
  expect(await updateAccountPrefs(sql, id, { explanationFollowsLearning: true })).toBe(true);
  expect((await getAccount(sql, id))?.explanation_follows_learning).toBe(1);
});

test("updateAccountPrefs writes each provided field; absent fields are untouched", async () => {
  const id = await account();

  expect(await updateAccountPrefs(sql, id, { explanationLanguage: "zh-Hans" })).toBe(true);
  let a = await getAccount(sql, id);
  expect(a?.explanation_language).toBe("zh-Hans");
  expect(a?.learning_language).toBe("en"); // untouched

  expect(await updateAccountPrefs(sql, id, { reminderEnabled: true, reminderTime: "20:30" })).toBe(true);
  a = await getAccount(sql, id);
  expect(a?.reminder_enabled).toBe(1);
  expect(a?.reminder_time).toBe("20:30");
  expect(a?.explanation_language).toBe("zh-Hans"); // still untouched from the prior update
});

test("updateAccountPrefs can clear learning_language + the reminder time to null", async () => {
  const id = await account();
  expect(await updateAccountPrefs(sql, id, { learningLanguage: null, reminderTime: null })).toBe(true);
  const a = await getAccount(sql, id);
  expect(a?.learning_language).toBeNull();
  expect(a?.reminder_time).toBeNull();
});

test("an empty patch is a no-op (returns false, no write)", async () => {
  expect(await updateAccountPrefs(sql, await account(), {})).toBe(false);
});

test("updateAccountPrefs never touches a soft-deleted account", async () => {
  const id = await account();
  await markAccountDeleted(sql, id, 5000);
  expect(await updateAccountPrefs(sql, id, { explanationLanguage: "es" })).toBe(false);
  expect((await getAccount(sql, id))?.explanation_language).toBe("en"); // unchanged default
});

test("reminderEnabled false coerces to 0", async () => {
  const id = await account();
  await updateAccountPrefs(sql, id, { reminderEnabled: false });
  expect((await getAccount(sql, id))?.reminder_enabled).toBe(0);
});

// --- identity capture (GET /auth/me: provider + email) ------------------------

test("getOrCreateAccount captures provider + email on first create; getAccount exposes both", async () => {
  const id = await getOrCreateAccount(
    sql,
    { provider: "google", subject: "g-1", timezone: "UTC", email: "a@b.c" },
    1000,
    newId,
  );
  const a = await getAccount(sql, id);
  expect(a?.auth_provider).toBe("google");
  expect(a?.email).toBe("a@b.c");
});

test("email is FILL-IF-NULL: a later sign-in supplies it only when it was missing (Apple relay)", async () => {
  // first create with NO email claim
  const id = await getOrCreateAccount(sql, { provider: "apple", subject: "ap-1", timezone: "UTC" }, 1000, newId);
  expect((await getAccount(sql, id))?.email).toBeNull();
  // a later sign-in now carries the email → it fills
  const again = await getOrCreateAccount(
    sql,
    { provider: "apple", subject: "ap-1", timezone: "UTC", email: "late@b.c" },
    2000,
    newId,
  );
  expect(again).toBe(id); // same account
  expect((await getAccount(sql, id))?.email).toBe("late@b.c");
});

test("a stored email is NEVER clobbered by a later sign-in (missing OR different email)", async () => {
  const id = await getOrCreateAccount(
    sql,
    { provider: "google", subject: "g-2", timezone: "UTC", email: "first@b.c" },
    1000,
    newId,
  );
  await getOrCreateAccount(sql, { provider: "google", subject: "g-2", timezone: "UTC" }, 2000, newId); // no email
  expect((await getAccount(sql, id))?.email).toBe("first@b.c");
  await getOrCreateAccount(
    sql,
    { provider: "google", subject: "g-2", timezone: "UTC", email: "changed@b.c" },
    3000,
    newId,
  ); // different email — fill-if-null keeps the original
  expect((await getAccount(sql, id))?.email).toBe("first@b.c");
});

// --- parseAccountPatch (the route's pure body validator) ----------------------

function ok(body: unknown) {
  const r = parseAccountPatch(body);
  if (!r.ok) throw new Error(`expected ok, got: ${r.detail}`);
  return r.patch;
}
function err(body: unknown): string {
  const r = parseAccountPatch(body);
  if (r.ok) throw new Error("expected an error");
  return r.detail;
}

test("parseAccountPatch accepts a valid patch + ignores unknown keys", () => {
  const patch = ok({ explanation_language: "zh-Hans", reminder_enabled: true, reminder_time: "07:05", extra: 1 });
  // An explicit explanation_language pick also turns OFF "follow my learning language".
  expect(patch).toEqual({
    explanationLanguage: "zh-Hans",
    explanationFollowsLearning: false,
    reminderEnabled: true,
    reminderTime: "07:05",
  });
});

test("parseAccountPatch handles the explanation-follows-learning flag", () => {
  // "Same as learning language" → just the flag on, no explicit language.
  expect(ok({ explanation_follows_learning: true })).toEqual({ explanationFollowsLearning: true });
  // An explicit language turns follow off (implicit).
  expect(ok({ explanation_language: "de" })).toEqual({
    explanationLanguage: "de",
    explanationFollowsLearning: false,
  });
  // An explicit flag in the SAME body wins over the implicit-off from a language pick (order-independent intent).
  expect(ok({ explanation_language: "de", explanation_follows_learning: true })).toEqual({
    explanationLanguage: "de",
    explanationFollowsLearning: true,
  });
  expect(err({ explanation_follows_learning: "yes" })).toContain("boolean");
});

test("parseAccountPatch: an empty object is a valid no-op patch", () => {
  expect(ok({})).toEqual({});
});

test("parseAccountPatch rejects a non-object body", () => {
  expect(err(42)).toContain("object");
  expect(err(null)).toContain("object");
  expect(err([1])).toContain("object");
});

test("parseAccountPatch rejects an unsupported explanation_language", () => {
  // ru / ar are outside the (expanded) explanation-language set; the message enumerates the set.
  expect(err({ explanation_language: "ru" })).toContain("zh-Hans");
  expect(err({ explanation_language: "ar" })).toContain("ja");
  expect(err({ explanation_language: 5 })).toContain("string");
});

test("parseAccountPatch accepts the expanded explanation-language set", () => {
  for (const lang of ["en", "es", "de", "it", "fr", "pt", "zh-Hans", "ja", "ko"]) {
    expect(ok({ explanation_language: lang }).explanationLanguage).toBe(lang);
  }
  // region/locale tags resolve via likely-subtags; Traditional Chinese is still unsupported.
  expect(ok({ explanation_language: "pt-BR" }).explanationLanguage).toBe("pt");
  expect(err({ explanation_language: "zh-TW" })).toContain("zh-Hans");
});

test("parseAccountPatch REJECTS an invalid learning_language tag (never silently clears)", () => {
  expect(err({ learning_language: "!!!" })).toContain("BCP-47");
  // an explicit null is the only way to clear it
  expect(ok({ learning_language: null })).toEqual({ learningLanguage: null });
  // a valid tag canonicalizes through
  expect(ok({ learning_language: "en" }).learningLanguage).toBe("en");
});

test("parseAccountPatch validates reminder fields", () => {
  expect(err({ reminder_enabled: "yes" })).toContain("boolean");
  expect(err({ reminder_time: "25:00" })).toContain("HH:MM");
  expect(err({ reminder_time: "7:5" })).toContain("HH:MM");
  expect(ok({ reminder_time: null })).toEqual({ reminderTime: null });
  expect(ok({ reminder_time: "23:59" })).toEqual({ reminderTime: "23:59" });
});
