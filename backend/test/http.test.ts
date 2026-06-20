import { test, expect } from "bun:test";
import { userIdFrom, attachment } from "../src/http.ts";

const req = (headers: Record<string, string> = {}): Request => new Request("https://capecho.test/", { headers });

test("attachment() marks downloads private + no-store (export carries decrypted user data) [review-fix: Codex P2]", () => {
  const res = attachment("a,b\r\n", "text/csv; charset=utf-8", "capecho-export-2026-05-27.csv");
  expect(res.headers.get("cache-control")).toBe("private, no-store"); // never cached/shared by browser, CDN, or proxy
  expect(res.headers.get("content-type")).toBe("text/csv; charset=utf-8");
  expect(res.headers.get("content-disposition")).toBe('attachment; filename="capecho-export-2026-05-27.csv"');
});

test("ignores the forgeable user header when not trusted (production default)", () => {
  // The whole point: an unauthenticated caller can't pose as a signed-in user.
  expect(userIdFrom(req({ "x-capecho-user-id": "attacker" }), false)).toBeNull();
});

test("honors the user header only when explicitly trusted (dev/staging)", () => {
  expect(userIdFrom(req({ "x-capecho-user-id": "u1" }), true)).toBe("u1");
  expect(userIdFrom(req({}), true)).toBeNull();
  expect(userIdFrom(req({ "x-capecho-user-id": "   " }), true)).toBeNull();
});
