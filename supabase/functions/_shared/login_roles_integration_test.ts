// Role test of the login chain against a real database (PM-145): the router with the real database half of its Deps, and a stand-in for the
// session check (the header `x-test-user` plays the signed-in user; without it the request is anonymous).
// Cases: admin, manager, associate, an uninvited user (signed in with Supabase but never made staff, no company) and anonymous.
// Needs TEST_DB_URL and PGPASSWORD; creates four temporary users and removes them at the end.
import { deepStrictEqual } from "node:assert/strict";
import postgres from "npm:postgres@3.4.5";
import { AppError } from "./errors.ts";
import { defineFunction, type Deps } from "./router.ts";
import { z } from "./schemas.ts";
import { databaseDeps, runAsUserOn, type Tx } from "./supabase.ts";

const URL = Deno.env.get("TEST_DB_URL");

Deno.test({ name: "login roles on a real database", ignore: !URL, sanitizeOps: false, sanitizeResources: false, async fn(t) {
  const sql = postgres(URL!, { prepare: false, max: 3 });
  const mk = (label: string) => ({ id: crypto.randomUUID() as string, email: `lr-${label}@example.test` });
  const users = { admin: mk("admin"), manager: mk("manager"), associate: mk("associate"), uninvited: mk("uninvited") };
  const [org] = await sql`select id from public.organizations order by created_at limit 1`;

  const fn = defineFunction<Tx>("roles", {
    whoami: { input: z.object({}), audience: "any", handler: (ctx) => Promise.resolve({ staffRole: ctx.staffRole, org: ctx.organizationId }) },
    staffOnly: { input: z.object({}), handler: () => Promise.resolve("ok") },
    manageCompanies: { input: z.object({}), permission: "companies.manage", handler: () => Promise.resolve("ok") },
  });
  const byToken = new Map(Object.values(users).map((u) => [u.id, u]));
  const deps: Deps<Tx> = {
    ...databaseDeps(sql),
    authenticate: (req) => {
      const u = byToken.get(req.headers.get("x-test-user") ?? "");
      return u ? Promise.resolve(u) : Promise.reject(new AppError("unauthorized"));
    },
    log: () => {}, allowedOrigins: [], newId: () => crypto.randomUUID(), now: () => Date.now(),
  };
  const call = async (action: string, user?: { id: string }) => {
    const res = await fn.handle(new Request("https://f.example/", {
      method: "POST", headers: { "content-type": "application/json", ...(user ? { "x-test-user": user.id } : {}) }, body: JSON.stringify({ action }),
    }), deps);
    return { status: res.status, body: await res.json() };
  };

  try {
    await sql.begin(async (s) => {
      for (const u of Object.values(users)) await s`insert into auth.users (id, email, aud, role) values (${u.id}, ${u.email}, 'authenticated', 'authenticated')`;
      await s`select set_config('gemina.staff_role_change', 'on', true)`;
      for (const [label, role] of [["admin", "admin"], ["manager", "manager"], ["associate", "associate"]] as const) {
        await s`update public.profiles set role = 'staff', staff_role = ${role}, organization_id = ${org.id}, zite_user_id = ${"lr-" + label} where id = ${users[label].id}`;
      }
      await s`update public.profiles set role = 'client' where id = ${users.uninvited.id}`;
      await s`select set_config('gemina.staff_role_change', 'off', true)`;
    });
    const canManage = async (u: { id: string; email: string }) => await runAsUserOn(sql, u, async (tx) => (await tx.sql`select private.has_permission('companies.manage') as ok`)[0].ok as boolean);

    for (const label of ["admin", "manager", "associate"] as const) {
      await t.step(`${label}: signed in as staff; the permission answer follows the role matrix`, async () => {
        const who = await call("whoami", users[label]);
        deepStrictEqual([who.status, who.body.data], [200, { staffRole: label, org: org.id }]);
        deepStrictEqual((await call("staffOnly", users[label])).status, 200);
        deepStrictEqual((await call("manageCompanies", users[label])).status, (await canManage(users[label])) ? 200 : 403);
      });
    }
    await t.step("admin holds the permission to manage companies", async () => {
      deepStrictEqual((await call("manageCompanies", users.admin)).status, 200);
    });
    await t.step("uninvited user: signed in but nothing else, refused everywhere", async () => {
      for (const action of ["whoami", "staffOnly", "manageCompanies"]) {
        const r = await call(action, users.uninvited);
        deepStrictEqual([action, r.status, r.body.error.code], [action, 403, "forbidden"]);
      }
    });
    await t.step("anonymous: 401 everywhere", async () => {
      for (const action of ["whoami", "staffOnly", "manageCompanies"]) deepStrictEqual([action, (await call(action)).status], [action, 401]);
    });
  } finally {
    const ids = Object.values(users).map((u) => u.id);
    await sql`delete from public.audit_log where row_id = any(${ids}::text[])`;
    await sql`delete from auth.users where id = any(${ids}::uuid[])`;
    await sql.end();
  }
} });
