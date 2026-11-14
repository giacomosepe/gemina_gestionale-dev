// Integration test of the data layer against a real database (the staging project, in the staging workflow): `TEST_DB_URL` and PGPASSWORD must be set.
// Proves: queries run as the signed-in user (row-level security refuses what it must), and a multi-step write rolls back as a whole.
// It creates three temporary users (admin, associate, outsider) and removes them at the end; the data it writes is rolled back.
import { deepStrictEqual, ok, rejects } from "node:assert/strict";
import postgres from "npm:postgres@3.4.5";
import { allRows, byId, mustById } from "./data.ts";
import { AppError } from "./errors.ts";
import { runAsUserOn } from "./supabase.ts";

const URL = Deno.env.get("TEST_DB_URL");
const ROLLBACK = new Error("rollback on purpose");
const rolledBack = (e: unknown) => e === ROLLBACK;

Deno.test({ name: "data layer on a real database", ignore: !URL, sanitizeOps: false, sanitizeResources: false, async fn(t) {
  const sql = postgres(URL!, { prepare: false, max: 2 });
  const id = () => crypto.randomUUID();
  const admin = { id: id(), email: "dl-admin@example.test" }, assoc = { id: id(), email: "dl-assoc@example.test" }, outsider = { id: id(), email: "dl-out@example.test" };
  const [org] = await sql`select id from public.organizations order by created_at limit 1`;
  try {
    await sql.begin(async (s) => {
      for (const u of [admin, assoc, outsider]) await s`insert into auth.users (id, email, aud, role) values (${u.id}, ${u.email}, 'authenticated', 'authenticated')`;
      await s`select set_config('gemina.staff_role_change', 'on', true)`;
      await s`update public.profiles set role = 'staff', staff_role = 'admin', organization_id = ${org.id}, zite_user_id = 'dl-admin' where id = ${admin.id}`;
      await s`update public.profiles set role = 'staff', staff_role = 'associate', organization_id = ${org.id}, zite_user_id = 'dl-assoc' where id = ${assoc.id}`;
      await s`update public.profiles set role = 'client' where id = ${outsider.id}`;
      await s`select set_config('gemina.staff_role_change', 'off', true)`;
    });

    await t.step("admin: typed insert, allRows, byId and mustById see the row; a missing id is not_found", async () => {
      await runAsUserOn(sql, admin, async (tx) => {
        const row = await tx.db.insertInto("companies").values({ name: "DL Co", zite_azienda_id: "dl-co-1" }).returning(["id", "organization_id"]).executeTakeFirstOrThrow();
        deepStrictEqual(row.organization_id, org.id);                                         // the default organization is the user's
        ok((await allRows(tx.db, "companies", { where: { name: "DL Co" } })).length === 1);
        deepStrictEqual((await byId(tx.db, "companies", row.id))?.name, "DL Co");
        deepStrictEqual((await mustById(tx.db, "companies", row.id)).id, row.id);
        await rejects(mustById(tx.db, "companies", crypto.randomUUID()), (e) => e instanceof AppError && e.code === "not_found");
        throw ROLLBACK;
      }).catch((e) => { if (!rolledBack(e)) throw e; });
    });

    await t.step("associate: refused where the role has no right (same answer as the permission helper); cannot read or write the audit log", async () => {
      await runAsUserOn(sql, assoc, async (tx) => {
        const [{ ok: canManage }] = await tx.sql`select private.has_permission('companies.manage') as ok`;
        let refused = false;
        await tx.db.transaction().execute((t2) => t2.insertInto("companies").values({ name: "DL Assoc Co", zite_azienda_id: "dl-co-2" }).execute()).catch((e) => {
          refused = e?.code === "42501";
        });
        deepStrictEqual(refused, !canManage);
        deepStrictEqual((await tx.sql`select count(*)::int as n from public.audit_log`)[0].n, 0);
        await rejects(tx.sql`insert into public.audit_log (organization_id, table_name, action) values (${org.id}, 'x', 'insert')`, (e: { code?: string }) => e.code === "42501");
        throw ROLLBACK;
      }).catch((e) => { if (!rolledBack(e)) throw e; });
    });

    await t.step("outsider (client without a company): sees no company at all", async () => {
      await runAsUserOn(sql, outsider, async (tx) => {
        deepStrictEqual((await allRows(tx.db, "companies")).length, 0);
        throw ROLLBACK;
      }).catch((e) => { if (!rolledBack(e)) throw e; });
    });

    await t.step("a multi-step write rolls back as a whole when a later step fails; a failed savepoint rolls back only its part", async () => {
      // part 1: the whole request fails after the first insert: nothing is kept
      await rejects(runAsUserOn(sql, admin, async (tx) => {
        await tx.db.insertInto("companies").values({ name: "DL Rollback", zite_azienda_id: "dl-rb-1" }).execute();
        throw new Error("step 2 failed");
      }), /step 2 failed/);
      deepStrictEqual((await sql`select count(*)::int as n from public.companies where zite_azienda_id = 'dl-rb-1'`)[0].n, 0);

      // part 2: db.transaction() inside the request is a savepoint: its failure undoes only its own writes
      await runAsUserOn(sql, admin, async (tx) => {
        await tx.db.insertInto("companies").values({ name: "DL Outer", zite_azienda_id: "dl-sp-outer" }).execute();
        await tx.db.transaction().execute(async (t2) => {
          await t2.insertInto("companies").values({ name: "DL Inner", zite_azienda_id: "dl-sp-inner" }).execute();
          throw new Error("inner failed");
        }).catch(() => {});
        deepStrictEqual((await allRows(tx.db, "companies", { where: { zite_azienda_id: "dl-sp-outer" } })).length, 1);
        deepStrictEqual((await allRows(tx.db, "companies", { where: { zite_azienda_id: "dl-sp-inner" } })).length, 0);
        throw ROLLBACK;
      }).catch((e) => { if (!rolledBack(e)) throw e; });
    });
  } finally {
    const ids = [admin.id, assoc.id, outsider.id];
    await sql`delete from public.audit_log where row_id = any(${ids}::text[])`;
    await sql`delete from auth.users where id = any(${ids}::uuid[])`;
    await sql.end();
  }
} });
