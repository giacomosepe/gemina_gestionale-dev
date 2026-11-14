// Unit tests of the router and the error format (no network, no database): `deno test supabase/functions/_shared`
import { deepStrictEqual } from "node:assert/strict";
import { AppError, MESSAGE_IT } from "./errors.ts";
import { defineFunction, type Deps, type Identity } from "./router.ts";
import { z } from "./schemas.ts";

const assertEquals = (a: unknown, b: unknown) => deepStrictEqual(a, b);
const assertObjectMatch = (a: Record<string, unknown>, b: Record<string, unknown>) => { for (const k of Object.keys(b)) deepStrictEqual(a[k], b[k]); };

type FakeTx = { name: string };

function makeDeps(over: Partial<Deps<FakeTx>> & { identity?: Identity; permissions?: string[] } = {}) {
  const lines: Record<string, unknown>[] = [];
  let t = 1000;
  const deps: Deps<FakeTx> = {
    allowedOrigins: ["https://app.example"],
    newId: () => "req-1",
    now: () => (t += 5),
    log: (l) => lines.push(l),
    authenticate: () => Promise.resolve({ id: "user-1", email: "a@example.test" }),
    runAsUser: (_u, fn) => fn({ name: "tx" }),
    loadIdentity: () => Promise.resolve(over.identity ?? { organizationId: "org-1", staffRole: "admin" }),
    hasPermission: (_tx, p) => Promise.resolve((over.permissions ?? []).includes(p)),
    ...over,
  };
  return { deps, lines };
}

const fn = defineFunction<FakeTx>("sample", {
  echo: { input: z.object({ n: z.number().int() }), handler: (ctx, i) => Promise.resolve({ n: i.n, org: ctx.organizationId, tx: ctx.tx.name }) },
  guarded: { input: z.object({}), permission: "cases.manage", handler: () => Promise.resolve("done") },
  anyone: { input: z.object({}), audience: "any", handler: (ctx) => Promise.resolve(ctx.staffRole) },
  missing: { input: z.object({}), handler: () => { throw new AppError("not_found"); } },
  boom: { input: z.object({}), handler: () => { throw new Error("secret detail: password=hunter2"); } },
  rls: { input: z.object({}), handler: () => { throw Object.assign(new Error("new row violates row-level security policy"), { code: "42501" }); } },
  dup: { input: z.object({}), handler: () => { throw Object.assign(new Error("duplicate key"), { code: "23505" }); } },
});

const post = (body: unknown, headers: Record<string, string> = {}) =>
  new Request("https://f.example/sample", { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });

Deno.test("success: typed answer, transaction and organization reach the handler, one log line", async () => {
  const { deps, lines } = makeDeps();
  const res = await fn.handle(post({ action: "echo", input: { n: 3 } }), deps);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { ok: true, data: { n: 3, org: "org-1", tx: "tx" } });
  assertEquals(res.headers.get("x-request-id"), "req-1");
  assertEquals(lines.length, 1);
  assertObjectMatch(lines[0], { fn: "sample", action: "echo", user: "user-1", organization: "org-1", status: 200, outcome: "ok" });
  assertEquals(typeof lines[0].ms, "number");
});

Deno.test("method, JSON and action are checked before anything else", async () => {
  const { deps } = makeDeps();
  assertEquals((await fn.handle(new Request("https://f.example/", { method: "GET" }), deps)).status, 405);
  const bad = await fn.handle(new Request("https://f.example/", { method: "POST", body: "not json" }), deps);
  assertEquals(bad.status, 400);
  assertEquals((await fn.handle(post({ input: {} }), deps)).status, 400);
  const unknown = await fn.handle(post({ action: "nope" }), deps);
  assertEquals(unknown.status, 404);
  assertEquals((await unknown.json()).error.code, "unknown_action");
  assertEquals((await fn.handle(post({ action: "constructor" }), deps)).status, 404);   // not an inherited property
});

Deno.test("no session: 401 with the Italian message, and the handler never runs", async () => {
  const { deps, lines } = makeDeps({ authenticate: () => Promise.reject(new AppError("unauthorized")) });
  const res = await fn.handle(post({ action: "echo", input: { n: 1 } }), deps);
  assertEquals(res.status, 401);
  assertEquals(await res.json(), { ok: false, error: { code: "unauthorized", message: MESSAGE_IT.unauthorized } });
  assertObjectMatch(lines[0], { outcome: "unauthorized", user: null });
});

Deno.test("audience: staff by default, any when the action says so; no organization is refused", async () => {
  const outsider = makeDeps({ identity: { organizationId: "org-1", staffRole: null } });
  assertEquals((await fn.handle(post({ action: "echo", input: { n: 1 } }), outsider.deps)).status, 403);
  const ok = await fn.handle(post({ action: "anyone" }), outsider.deps);
  assertEquals(ok.status, 200);
  const nobody = makeDeps({ identity: { organizationId: null, staffRole: null } });
  assertEquals((await fn.handle(post({ action: "anyone" }), nobody.deps)).status, 403);
});

Deno.test("permission: refused without the key, allowed with it", async () => {
  assertEquals((await fn.handle(post({ action: "guarded" }), makeDeps().deps)).status, 403);
  assertEquals((await fn.handle(post({ action: "guarded" }), makeDeps({ permissions: ["cases.manage"] }).deps)).status, 200);
});

Deno.test("input is validated: 400 with the field paths, never the values", async () => {
  const { deps } = makeDeps();
  const res = await fn.handle(post({ action: "echo", input: { n: "secret-value" } }), deps);
  assertEquals(res.status, 400);
  const body = await res.json();
  assertEquals(body.error.code, "invalid_input");
  assertEquals(body.error.details[0].path, ["n"]);
  assertEquals(JSON.stringify(body).includes("secret-value"), false);
});

Deno.test("errors: app errors keep their code, database errors are mapped, unexpected errors do not leak", async () => {
  const { deps, lines } = makeDeps();
  assertEquals((await fn.handle(post({ action: "missing" }), deps)).status, 404);
  assertEquals((await fn.handle(post({ action: "rls" }), deps)).status, 403);
  assertEquals((await fn.handle(post({ action: "dup" }), deps)).status, 409);
  const res = await fn.handle(post({ action: "boom" }), deps);
  assertEquals(res.status, 500);
  const text = JSON.stringify(await res.json());
  assertEquals(text.includes("hunter2"), false);
  assertEquals(text.includes(MESSAGE_IT.internal), true);
  assertEquals(String(lines.at(-1)?.error).includes("hunter2"), true);                 // the real cause is in the log only
});

Deno.test("CORS: preflight and headers only for allowed origins", async () => {
  const { deps } = makeDeps();
  const pre = await fn.handle(new Request("https://f.example/", { method: "OPTIONS", headers: { origin: "https://app.example" } }), deps);
  assertEquals(pre.status, 204);
  assertEquals(pre.headers.get("access-control-allow-origin"), "https://app.example");
  const other = await fn.handle(post({ action: "echo", input: { n: 1 } }, { origin: "https://evil.example" }), deps);
  assertEquals(other.headers.get("access-control-allow-origin"), null);
  const mine = await fn.handle(post({ action: "echo", input: { n: 1 } }, { origin: "https://app.example" }), deps);
  assertEquals(mine.headers.get("access-control-allow-origin"), "https://app.example");
});

Deno.test("a failing transaction fails the request (the rollback is the database's; see test 041 for the real one)", async () => {
  const { deps } = makeDeps({ runAsUser: () => Promise.reject(Object.assign(new Error("deadlock"), { code: "40P01" })) });
  assertEquals((await fn.handle(post({ action: "echo", input: { n: 1 } }), deps)).status, 409);
});
