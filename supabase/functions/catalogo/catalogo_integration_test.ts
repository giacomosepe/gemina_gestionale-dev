// The catalogo function against a real database: the router with the real database half of its Deps and a stand-in for the session check.
// Needs TEST_DB_URL; creates two temporary users (admin, manager) and the catalogue rows it needs with a unique prefix, and removes all of it at the end.
// It never moves rows (that would renumber the real catalogue); ordering is covered by the unit tests.
import { deepStrictEqual } from "node:assert/strict";
import postgres from "npm:postgres@3.4.5";
import { AppError } from "../_shared/errors.ts";
import type { Deps } from "../_shared/router.ts";
import { databaseDeps, type Tx } from "../_shared/supabase.ts";
import { catalogo } from "./actions.ts";

const URL = Deno.env.get("TEST_DB_URL");

Deno.test({ name: "catalogo on a real database", ignore: !URL, sanitizeOps: false, sanitizeResources: false, async fn(t) {
  const sql = postgres(URL!, { prepare: false, max: 3 });
  const tag = `ZZ-test-${crypto.randomUUID().slice(0, 8)}`;
  const mk = (label: string) => ({ id: crypto.randomUUID() as string, email: `cat-${label}@example.test` });
  const users = { admin: mk("admin"), manager: mk("manager") };
  const [org] = await sql`select id from public.organizations order by created_at limit 1`;
  const byToken = new Map(Object.values(users).map((u) => [u.id, u]));
  const deps: Deps<Tx> = {
    ...databaseDeps(sql),
    authenticate: (req) => {
      const u = byToken.get(req.headers.get("x-test-user") ?? "");
      return u ? Promise.resolve(u) : Promise.reject(new AppError("unauthorized"));
    },
    log: () => {}, allowedOrigins: [], newId: () => crypto.randomUUID(), now: () => Date.now(),
  };
  // deno-lint-ignore no-explicit-any
  const call = async (user: { id: string } | undefined, action: string, input: unknown = {}): Promise<{ status: number; body: any }> => {
    const res = await catalogo.handle(new Request("https://f.example/", {
      method: "POST", headers: { "content-type": "application/json", ...(user ? { "x-test-user": user.id } : {}) }, body: JSON.stringify({ action, input }),
    }), deps);
    return { status: res.status, body: await res.json() };
  };

  try {
    await sql.begin(async (s) => {
      for (const u of Object.values(users)) await s`insert into auth.users (id, email, aud, role) values (${u.id}, ${u.email}, 'authenticated', 'authenticated')`;
      await s`select set_config('gemina.staff_role_change', 'on', true)`;
      for (const label of ["admin", "manager"] as const) {
        await s`update public.profiles set role = 'staff', staff_role = ${label}, organization_id = ${org.id}, zite_user_id = ${"cat-" + label} where id = ${users[label].id}`;
      }
      await s`select set_config('gemina.staff_role_change', 'off', true)`;
    });

    let categoryId = "";
    await t.step("admin creates a category; duplicates and empty names are refused", async () => {
      const r = await call(users.admin, "categories.save", { name: tag });
      deepStrictEqual(r.status, 200);
      const made = r.body.data.categories.find((c: { name: string }) => c.name === tag);
      deepStrictEqual([made.active, made.services, made.active_services], [true, 0, 0]);
      categoryId = made.id;
      const dup = await call(users.admin, "categories.save", { name: tag.toLowerCase() });
      deepStrictEqual([dup.status, dup.body.error.code], [400, "invalid_input"]);
      deepStrictEqual((await call(users.admin, "categories.save", { name: "  " })).status, 400);
    });

    await t.step("manager reads but cannot write", async () => {
      const read = await call(users.manager, "categories.list");
      deepStrictEqual(read.status, 200);
      deepStrictEqual(read.body.data.categories.some((c: { id: string }) => c.id === categoryId), true);
      const write = await call(users.manager, "categories.save", { name: `${tag}-m` });
      deepStrictEqual([write.status, write.body.error.code], [403, "forbidden"]);
      deepStrictEqual((await call(undefined, "categories.list")).status, 401);
    });

    await t.step("fields of a category: add, duplicate refused, archive, edit", async () => {
      const add = await call(users.admin, "fields.save", { category_id: categoryId, label: "Importo", field_type: "money", required: true });
      deepStrictEqual(add.status, 200);
      const f = add.body.data.fields;
      deepStrictEqual([f.length, f[0].label, f[0].position, f[0].inherited], [1, "Importo", 10, false]);
      deepStrictEqual((await call(users.admin, "fields.save", { category_id: categoryId, label: "importo", field_type: "text", required: false })).status, 400);
      deepStrictEqual((await call(users.admin, "fields.save", { category_id: categoryId, label: "Scelta", field_type: "choice", required: false })).status, 400);
      const off = await call(users.admin, "fields.setActive", { id: f[0].id, active: false });
      deepStrictEqual(off.body.data.fields[0].active, false);
      const edit = await call(users.admin, "fields.save", { category_id: categoryId, id: f[0].id, label: "Importo totale", field_type: "money", required: false });
      deepStrictEqual(edit.body.data.fields[0].label, "Importo totale");
      deepStrictEqual((await call(users.admin, "fields.list", {})).status, 400);
    });

    await t.step("milestones: add, rename, days checked, archive", async () => {
      const add = await call(users.admin, "milestones.save", { name: `${tag}-m`, days: 15 });
      deepStrictEqual(add.status, 200);
      const m = add.body.data.milestones.find((x: { name: string }) => x.name === `${tag}-m`);
      deepStrictEqual([m.days, m.active], [15, true]);
      deepStrictEqual((await call(users.admin, "milestones.save", { id: m.id, name: `${tag}-m2`, days: -3 })).status, 400);
      const ren = await call(users.admin, "milestones.save", { id: m.id, name: `${tag}-m2` });
      deepStrictEqual(ren.body.data.milestones.find((x: { id: string }) => x.id === m.id).name, `${tag}-m2`);
      const off = await call(users.admin, "milestones.setActive", { id: m.id, active: false });
      deepStrictEqual(off.body.data.milestones.find((x: { id: string }) => x.id === m.id).active, false);
    });

    await t.step("data requests: rules on where it is saved, create, archive", async () => {
      const base = { name: `${tag}-d`, data_type: "text", save_on_company: false, save_on_contact: false, save_on_deal: false, save_on_case: true, required_by_default: false };
      deepStrictEqual((await call(users.admin, "dataRequests.save", { ...base, save_on_case: false })).status, 400);
      const ok = await call(users.admin, "dataRequests.save", base);
      deepStrictEqual(ok.status, 200);
      const d = ok.body.data.data_requests.find((x: { name: string }) => x.name === `${tag}-d`);
      deepStrictEqual([d.lifetime, d.archived, d.uses], ["temporary", false, 0]);
      const off = await call(users.admin, "dataRequests.archive", { id: d.id, archived: true });
      deepStrictEqual(off.body.data.data_requests.find((x: { id: string }) => x.id === d.id).archived, true);
    });

    await t.step("a category with services cannot be deleted or archived; an empty one can be deleted", async () => {
      await sql`insert into public.services (category_id, name, active) values (${categoryId}, ${tag + "-s"}, true)`;
      deepStrictEqual((await call(users.admin, "categories.delete", { id: categoryId })).status, 400);
      deepStrictEqual((await call(users.admin, "categories.save", { id: categoryId, active: false })).status, 400);
      const list = await call(users.admin, "services.list", { category_id: categoryId });
      deepStrictEqual(list.body.data.services.length, 1);
      await sql`delete from public.services where category_id = ${categoryId}`;
      await sql`delete from public.service_fields where category_id = ${categoryId}`;
      const gone = await call(users.admin, "categories.delete", { id: categoryId });
      deepStrictEqual([gone.status, gone.body.data.categories.some((c: { id: string }) => c.id === categoryId)], [200, false]);
    });
  } finally {
    await sql`delete from public.service_fields where category_id in (select id from public.service_categories where name like ${tag + "%"})`;
    await sql`delete from public.service_categories where name like ${tag + "%"}`;
    await sql`delete from public.milestones where name like ${tag + "%"}`;
    await sql`delete from public.data_requests where name like ${tag + "%"}`;
    await sql`delete from public.audit_log where actor_id = any(${Object.values(users).map((u) => u.id)}::uuid[])`;
    for (const u of Object.values(users)) await sql`delete from auth.users where id = ${u.id}`;
    await sql.end();
  }
} });
