// catalogo (PM-154): the service catalogue the team keeps: categories, milestones, data requests, the fields a category or service asks for.
// Reading is open to the staff; every write needs the permission `catalog.manage` (admin). Each write returns the refreshed list, so a screen
// needs one call per click. Rules are in rules.ts (pure, tested); the database also enforces organization and permission with row-level security.
import { defineFunction } from "../_shared/router.ts";
import { noInput, nonEmpty, uuid, z } from "../_shared/schemas.ts";
import { AppError } from "../_shared/errors.ts";
import { allRows, mustById } from "../_shared/data.ts";
import type { Context } from "../_shared/router.ts";
import type { Tx } from "../_shared/supabase.ts";
import {
  categoryArchiveError, categoryDeleteError, categoryError, DATA_TYPES, dataRequestError, daysError, fieldError, FIELD_TYPES, milestoneError,
  moveOrder, optionLines, VALIDITIES,
} from "./rules.ts";

type C = Context<Tx>;
const MANAGE = "catalog.manage";
const bad = (message: string) => new AppError("invalid_input", message);
const direction = z.enum(["up", "down"]);
const text = (max: number) => z.string().trim().max(max).nullable().optional();

async function applyOrder(c: C, table: "service_categories" | "milestones" | "service_fields", moves: { id: string; position: number }[]) {
  for (const m of moves) await c.tx.db.updateTable(table).set({ position: m.position, updated_at: new Date().toISOString() }).where("id", "=", m.id).execute();
}

// ---- categories
async function listCategories(c: C) {
  const [categories, services] = await Promise.all([
    allRows(c.tx.db, "service_categories", { orderBy: "position" }),
    allRows(c.tx.db, "services"),
  ]);
  return {
    categories: categories.map((cat) => {
      const own = services.filter((s) => s.category_id === cat.id);
      return {
        id: cat.id, name: cat.name, position: cat.position, active: cat.active, macro_category: cat.macro_category, standard_terms: cat.standard_terms,
        services: own.length, active_services: own.filter((s) => s.active).length,
      };
    }),
  };
}

// Postgres sends numeric columns as strings ("15"); the screens get numbers.
const num = (v: unknown): number | null => (v === null || v === undefined ? null : Number(v));

// ---- milestones
async function listMilestones(c: C) {
  const rows = await allRows(c.tx.db, "milestones", { orderBy: "position" });
  return { milestones: rows.map((m) => ({ ...m, days: num(m.days) })) };
}

// ---- data requests
async function listDataRequests(c: C) {
  const [requests, fields, categories, services] = await Promise.all([
    allRows(c.tx.db, "data_requests", { orderBy: "name" }),
    allRows(c.tx.db, "service_fields"),
    allRows(c.tx.db, "service_categories"),
    allRows(c.tx.db, "services"),
  ]);
  const categoryName = new Map(categories.map((x) => [x.id, x.name]));
  const serviceCategory = new Map(services.map((x) => [x.id, x.category_id]));
  return {
    data_requests: requests.map((r) => {
      const uses = fields.filter((f) => f.data_request_id === r.id);
      const usedIn = new Set<string>();
      for (const f of uses) {
        const cid = f.category_id ?? (f.service_id ? serviceCategory.get(f.service_id) : null);
        const n = cid ? categoryName.get(cid) : null;
        if (n) usedIn.add(n);
      }
      return { ...r, validity_months: num(r.validity_months), signatures_required: num(r.signatures_required), uses: uses.length, used_in: [...usedIn].sort((a, b) => a.localeCompare(b, "it")) };
    }),
  };
}

// ---- fields of a category or a service
const scope = z.object({ category_id: uuid.optional(), service_id: uuid.optional() })
  .refine((v) => !!v.category_id !== !!v.service_id, { message: "Indica la categoria oppure il servizio." });

async function scopeOf(c: C, s: { category_id?: string; service_id?: string }) {
  if (s.service_id) {
    const svc = await mustById(c.tx.db, "services", s.service_id);
    if (!svc.category_id) throw bad("Questo servizio non ha una categoria.");
    return { category_id: svc.category_id, service_id: svc.id };
  }
  await mustById(c.tx.db, "service_categories", s.category_id!);
  return { category_id: s.category_id!, service_id: null };
}

/** A service sees its category's fields (read only there) and the ones it adds. */
async function listFields(c: C, s: { category_id: string; service_id: string | null }) {
  const rows = await allRows(c.tx.db, "service_fields", { orderBy: "position" });
  const own = (r: { category_id: string | null; service_id: string | null }) => (s.service_id ? r.service_id === s.service_id : r.category_id === s.category_id && !r.service_id);
  const fromCategory = (r: { category_id: string | null; service_id: string | null }) => r.category_id === s.category_id && !r.service_id;
  const wanted = rows.filter((r) => own(r) || (s.service_id && fromCategory(r)));
  return { fields: wanted.map((r) => ({ ...r, inherited: !!s.service_id && fromCategory(r) })) };
}

export const catalogo = defineFunction<Tx>("catalogo", {
  // ---------- categories
  "categories.list": { input: noInput, handler: (c) => listCategories(c) },

  "categories.save": {
    permission: MANAGE,
    input: z.object({
      id: uuid.optional(), name: z.string().optional(), active: z.boolean().optional(), macro_category: z.string().trim().max(40).nullable().optional(),
      standard_terms: text(4000),
    }),
    handler: async (c, i) => {
      const all = await allRows(c.tx.db, "service_categories", { orderBy: "position" });
      if (!i.id) {
        const err = categoryError(i.name ?? "", all);
        if (err) throw bad(err);
        await c.tx.db.insertInto("service_categories").values({
          name: i.name!.trim(), position: Math.max(0, ...all.map((x) => x.position)) + 10, active: true,
          ...(i.macro_category ? { macro_category: i.macro_category } : {}), ...(i.standard_terms ? { standard_terms: i.standard_terms } : {}),
        }).execute();
      } else {
        const before = all.find((x) => x.id === i.id);
        if (!before) throw new AppError("not_found", "Categoria non trovata.");
        if (i.name !== undefined) { const err = categoryError(i.name, all, i.id); if (err) throw bad(err); }
        if (i.active === false && before.active) {
          const svc = await allRows(c.tx.db, "services", { where: { category_id: i.id, active: true } });
          const err = categoryArchiveError(svc.length);
          if (err) throw bad(err);
        }
        const set: Record<string, unknown> = { updated_at: new Date().toISOString() };
        if (i.name !== undefined) set.name = i.name.trim();
        if (i.active !== undefined) set.active = i.active;
        if (i.macro_category !== undefined) set.macro_category = i.macro_category || null;
        if (i.standard_terms !== undefined) set.standard_terms = i.standard_terms || null;
        await c.tx.db.updateTable("service_categories").set(set).where("id", "=", i.id).execute();
      }
      return await listCategories(c);
    },
  },

  "categories.move": {
    permission: MANAGE, input: z.object({ id: uuid, direction }),
    handler: async (c, i) => {
      await applyOrder(c, "service_categories", moveOrder(await allRows(c.tx.db, "service_categories", { orderBy: "position" }), i.id, i.direction));
      return await listCategories(c);
    },
  },

  "categories.delete": {
    permission: MANAGE, input: z.object({ id: uuid }),
    handler: async (c, i) => {
      await mustById(c.tx.db, "service_categories", i.id);
      const err = categoryDeleteError((await allRows(c.tx.db, "services", { where: { category_id: i.id } })).length);
      if (err) throw bad(err);
      await c.tx.db.deleteFrom("service_categories").where("id", "=", i.id).execute();
      return await listCategories(c);
    },
  },

  // ---------- milestones
  "milestones.list": { input: noInput, handler: (c) => listMilestones(c) },

  "milestones.save": {
    permission: MANAGE,
    input: z.object({ id: uuid.optional(), name: nonEmpty, days: z.number().nullable().optional() }),
    handler: async (c, i) => {
      const all = await allRows(c.tx.db, "milestones", { orderBy: "position" });
      const err = milestoneError(i.name, all, i.id) ?? daysError(i.days);
      if (err) throw bad(err);
      const days = i.days === undefined ? {} : { days: i.days };
      if (i.id) {
        if (!all.some((m) => m.id === i.id)) throw new AppError("not_found", "Milestone non trovata.");
        await c.tx.db.updateTable("milestones").set({ name: i.name.trim(), ...days, updated_at: new Date().toISOString() }).where("id", "=", i.id).execute();
      } else {
        await c.tx.db.insertInto("milestones").values({ name: i.name.trim(), position: Math.max(0, ...all.map((m) => m.position)) + 10, active: true, ...days }).execute();
      }
      return await listMilestones(c);
    },
  },

  "milestones.setActive": {
    permission: MANAGE, input: z.object({ id: uuid, active: z.boolean() }),
    handler: async (c, i) => {
      // The rule "a milestone with cases in it cannot be archived" arrives with the cases (M4).
      await mustById(c.tx.db, "milestones", i.id);
      await c.tx.db.updateTable("milestones").set({ active: i.active, updated_at: new Date().toISOString() }).where("id", "=", i.id).execute();
      return await listMilestones(c);
    },
  },

  "milestones.move": {
    permission: MANAGE, input: z.object({ id: uuid, direction }),
    handler: async (c, i) => {
      await applyOrder(c, "milestones", moveOrder(await allRows(c.tx.db, "milestones", { orderBy: "position" }), i.id, i.direction));
      return await listMilestones(c);
    },
  },

  // ---------- data requests
  "dataRequests.list": { input: noInput, handler: (c) => listDataRequests(c) },

  "dataRequests.save": {
    permission: MANAGE,
    input: z.object({
      id: uuid.optional(), name: z.string().max(120), data_type: z.enum(DATA_TYPES),
      save_on_company: z.boolean(), save_on_contact: z.boolean(), save_on_deal: z.boolean(), save_on_case: z.boolean(), save_on_asset: z.boolean().optional(),
      required_by_default: z.boolean(), options: text(2000), help: text(500),
      validity: z.enum(VALIDITIES).nullable().optional(), validity_months: z.number().int().min(1).max(240).nullable().optional(),
      section: text(80),
    }),
    handler: async (c, i) => {
      const all = await allRows(c.tx.db, "data_requests");
      const before = i.id ? all.find((x) => x.id === i.id) : undefined;
      if (i.id && !before) throw new AppError("not_found", "Dato non trovato.");
      const { id: _id, ...rest } = i;
      const shape = {
        name: i.name, data_type: i.data_type, save_on_company: i.save_on_company, save_on_contact: i.save_on_contact, save_on_deal: i.save_on_deal,
        save_on_case: i.save_on_case, save_on_asset: i.save_on_asset ?? before?.save_on_asset ?? false, options: i.options ?? null,
        validity: i.validity ?? before?.validity ?? null, validity_months: i.validity_months ?? null,
      };
      const err = dataRequestError(shape, all.filter((x) => !x.local_only), i.id);
      if (err) throw bad(err);
      if (before && before.data_type !== i.data_type) {
        const used = await allRows(c.tx.db, "service_fields", { where: { data_request_id: before.id } });
        if (used.length) throw bad("Il tipo non si cambia: il dato è già usato da campi dei servizi.");
      }
      const row = {
        ...rest, name: i.name.trim(), save_on_asset: shape.save_on_asset, options: i.options?.trim() || null, help: i.help?.trim() || null,
        lifetime: i.save_on_company || i.save_on_contact ? "permanent" : "temporary", section: i.section === undefined ? undefined : i.section || null,
      };
      const clean = Object.fromEntries(Object.entries(row).filter(([, v]) => v !== undefined));
      if (i.id) await c.tx.db.updateTable("data_requests").set({ ...clean, updated_at: new Date().toISOString() }).where("id", "=", i.id).execute();
      else await c.tx.db.insertInto("data_requests").values({ ...clean, name: row.name, archived: false } as never).execute();
      return await listDataRequests(c);
    },
  },

  "dataRequests.archive": {
    permission: MANAGE, input: z.object({ id: uuid, archived: z.boolean() }),
    handler: async (c, i) => {
      await mustById(c.tx.db, "data_requests", i.id);
      await c.tx.db.updateTable("data_requests").set({ archived: i.archived, updated_at: new Date().toISOString() }).where("id", "=", i.id).execute();
      return await listDataRequests(c);
    },
  },

  // ---------- fields of a category or service
  "fields.list": {
    input: scope,
    handler: async (c, i) => await listFields(c, await scopeOf(c, i)),
  },

  "fields.save": {
    permission: MANAGE,
    input: z.object({
      category_id: uuid.optional(), service_id: uuid.optional(), id: uuid.optional(), label: z.string(), field_type: z.enum(FIELD_TYPES),
      options: text(2000), required: z.boolean(), initial_value: text(500), help: text(500), feeds: z.string().nullable().optional(),
    }).refine((v) => !!v.category_id !== !!v.service_id, { message: "Indica la categoria oppure il servizio." }),
    handler: async (c, i) => {
      const s = await scopeOf(c, i);
      const { fields } = await listFields(c, s);
      const err = fieldError({ label: i.label, field_type: i.field_type, options: i.options ?? null, feeds: i.feeds }, fields, i.id);
      if (err) throw bad(err);
      const values = {
        label: i.label.trim(), field_type: i.field_type, options: optionLines(i.options).join("\n") || null, required: i.required,
        initial_value: i.initial_value?.trim() || null, help: i.help?.trim() || null, feeds: i.feeds || null,
      };
      if (i.id) {
        const f = fields.find((x) => x.id === i.id);
        if (!f) throw new AppError("not_found", "Campo non trovato.");
        if (f.inherited) throw bad("Questo campo viene dalla categoria: si modifica nella pagina della categoria.");
        await c.tx.db.updateTable("service_fields").set({ ...values, updated_at: new Date().toISOString() }).where("id", "=", i.id).execute();
      } else {
        const own = fields.filter((f) => !f.inherited);
        await c.tx.db.insertInto("service_fields").values({
          ...values, category_id: s.service_id ? null : s.category_id, service_id: s.service_id, active: true, position: Math.max(0, ...own.map((f) => f.position)) + 10,
        }).execute();
      }
      return await listFields(c, s);
    },
  },

  "fields.setActive": {
    permission: MANAGE, input: z.object({ id: uuid, active: z.boolean() }),
    handler: async (c, i) => {
      const f = await mustById(c.tx.db, "service_fields", i.id);
      await c.tx.db.updateTable("service_fields").set({ active: i.active, updated_at: new Date().toISOString() }).where("id", "=", i.id).execute();
      return await listFields(c, await scopeOf(c, f.service_id ? { service_id: f.service_id } : { category_id: f.category_id! }));
    },
  },

  "fields.move": {
    permission: MANAGE, input: z.object({ id: uuid, direction }),
    handler: async (c, i) => {
      const f = await mustById(c.tx.db, "service_fields", i.id);
      const s = await scopeOf(c, f.service_id ? { service_id: f.service_id } : { category_id: f.category_id! });
      const own = (await listFields(c, s)).fields.filter((x) => !x.inherited);
      await applyOrder(c, "service_fields", moveOrder(own, i.id, i.direction));
      return await listFields(c, s);
    },
  },

  // ---------- read only, for the screens
  "services.list": {
    input: z.object({ category_id: uuid.optional() }),
    handler: async (c, i) => ({ services: await allRows(c.tx.db, "services", { where: i.category_id ? { category_id: i.category_id } : {}, orderBy: "position" }) }),
  },

  "lookups.list": {
    input: z.object({ kind: z.string().optional() }),
    handler: async (c, i) => ({ options: await allRows(c.tx.db, "lookup_options", { where: i.kind ? { kind: i.kind } : {}, orderBy: "position" }) }),
  },
});

