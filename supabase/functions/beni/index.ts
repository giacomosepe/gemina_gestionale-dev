// beni (v3, 2026-11-11; migrations beni_master, bene_documents)
// v2: each good also carries zite_bene_id (the code the invoice import knows it by; null = placeholder).
// v3: each good also carries its documents (bene_documents: references to Drive files), its invoiced total and suppliers (from the supplier-invoice
//     lines assigned to it, view supplier_invoice_by_bene) and its Drive folder; new actions dettaglio, documento, togli_documento, cartella.
// The goods of the investment of a trattativa or a pratica: the main list lives here (EU project), no longer in a JSON text on Zite.
// Called by the Gestionale's server (Zite endpoint gestisciBeni), never by a browser. Same trust model and secret as allegati-firma:
// header "x-bridge-secret" = BRIDGE_SECRET_STAFF. Every action acts AS the colleague logged in to Zite (zite_user_id from context.user, never from
// the browser): role authenticated with that staff profile, so the RLS (staff only) and the triggers of the migration apply.
//
// Actions:
//   elenco { zite_user_id, pratica_id?, trattativa_id?, trattative?: [zite ids] }
//          On a pratica: the goods born on its trattative pass to it first (when the pratica is on Supabase), then its goods. A placeholder made by the
//          invoice import (no zite_bene_id) is listed only when invoices are assigned to it. On a trattativa: the goods born on it.
//          -> { beni: [{ id, name, supplier, order_date, ordered, position, pratica_id, trattativa_id, allocations, zite_bene_id, values: {dato_id: value} }], pratica_su_supabase }
//   salva  { zite_user_id, bene: { id?, pratica_id?, trattativa_id?, name?, supplier?, order_date?, ordered? } }
//          new (no id): on the pratica or the trattativa; it is «managed» (zite_bene_id = its id), so the import keeps it and puts the placeholder aside.
//          existing: the fields sent change; a placeholder that is edited becomes managed.  -> { bene }
//   togli  { zite_user_id, id }    put aside (removed_at); refused while invoices are assigned to it  -> { ok }
//   valore { zite_user_id, bene_id, dato_id, value | null }   one catalogue value of a good (null clears it)  -> { ok }
//   dettaglio { zite_user_id, id }   one good with everything above plus its invoice lines  -> { bene, righe: [{ invoice_id, supplier_name, number, issue_date,
//          doc_type, description, period_from, period_to, share_pct, amount }] }
//   documento { zite_user_id, bene_id, dato_id, name, drive_file_id? | link?, valid_until? }   a document of the good (the file is on Drive)  -> { ok, id }
//   togli_documento { zite_user_id, id }   put aside  -> { ok }
//   cartella { zite_user_id, bene_id, drive_folder }   the Drive folder of the good («Beni/<name>»)  -> { ok }

import postgres from "npm:postgres@3.4.5";

const SECRET_STAFF = Deno.env.get("BRIDGE_SECRET_STAFF") ?? "";
const DB_URL = Deno.env.get("SUPABASE_DB_URL")!;
const MAX_BODY = 200_000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ZITE_ID = /^[A-Za-z0-9_-]{1,100}$/;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const DRIVE_ID = /^[A-Za-z0-9_-]{10,200}$/;

const sql = postgres(DB_URL, { prepare: false, max: 2, idle_timeout: 20 });

class BeniError extends Error {
  constructor(public status: number, public code: string) { super(code); }
}

function reply(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function safeEqual(a: string, b: string) {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  if (ea.length !== eb.length || ea.length === 0) return false;
  let diff = 0;
  for (let i = 0; i < ea.length; i++) diff |= ea[i] ^ eb[i];
  return diff === 0;
}

const oneUuid = (v: unknown, name: string): string => {
  if (typeof v !== "string" || !UUID.test(v)) throw new BeniError(400, `invalid_${name}`);
  return v;
};
const optUuid = (v: unknown, name: string): string | null => (v == null ? null : oneUuid(v, name));
const ziteId = (v: unknown, name: string): string => {
  if (typeof v !== "string" || !ZITE_ID.test(v)) throw new BeniError(400, `invalid_${name}`);
  return v;
};
const optZiteId = (v: unknown, name: string): string | null => (v == null ? null : ziteId(v, name));
/** undefined = not sent (unchanged); null or blank = cleared. */
const optText = (v: unknown, name: string, max: number): string | null | undefined => {
  if (v === undefined) return undefined;
  if (v === null) return null;
  if (typeof v !== "string" || v.length > max) throw new BeniError(400, `invalid_${name}`);
  return v.trim() || null;
};

async function comeCollega<T>(p: Record<string, unknown>, fn: (tx: postgres.TransactionSql) => Promise<T>): Promise<T> {
  if (typeof p.zite_user_id !== "string" || !p.zite_user_id || p.zite_user_id.length > 100) throw new BeniError(400, "invalid_zite_user_id");
  const [me] = await sql`select id from public.profiles where zite_user_id = ${p.zite_user_id} and role = 'staff'`;
  if (!me) throw new BeniError(403, "staff_unknown");
  return await sql.begin(async (tx) => {
    await tx`select set_config('request.jwt.claims', ${JSON.stringify({ sub: me.id, role: "authenticated" })}, true)`;
    await tx.unsafe("set local role authenticated");
    return await fn(tx);
  }) as T;
}

type Riga = Record<string, unknown> & { id: string };

async function conValori(tx: postgres.TransactionSql, righe: Riga[]) {
  const ids = righe.map((r) => r.id);
  const [valori, documenti, fatture] = ids.length
    ? await Promise.all([
      tx`select bene_id, dato_id, value from public.bene_values where bene_id = any(${ids}::uuid[])`,
      tx`select id, bene_id, dato_id, name, drive_file_id, link, to_char(valid_until, 'YYYY-MM-DD') as valid_until
           from public.bene_documents where bene_id = any(${ids}::uuid[]) and removed_at is null order by created_at`,
      tx`select bene_id, coalesce(sum(amount), 0)::text as invoiced, array_remove(array_agg(distinct supplier_name), null) as suppliers
           from public.supplier_invoice_by_bene where bene_id = any(${ids}::uuid[]) group by bene_id`,
    ])
    : [[], [], []];
  return righe.map((r) => ({
    id: r.id, name: r.name, supplier: r.supplier_hint, order_date: r.order_date, ordered: r.ordered, position: r.position,
    pratica_id: r.pratica_id, trattativa_id: r.trattativa_zite_id, allocations: Number(r.allocations ?? 0), zite_bene_id: r.zite_bene_id ?? null,
    drive_folder: r.drive_folder ?? null,
    values: Object.fromEntries(valori.filter((v) => v.bene_id === r.id).map((v) => [v.dato_id, v.value])),
    documents: documenti.filter((d) => d.bene_id === r.id).map(({ bene_id: _b, ...d }) => d),
    invoiced: fatture.find((f) => f.bene_id === r.id)?.invoiced ?? "0",
    suppliers: fatture.find((f) => f.bene_id === r.id)?.suppliers ?? [],
  }));
}

const COLONNE = (tx: postgres.TransactionSql) => tx`b.id, b.name, b.supplier_hint, to_char(b.order_date, 'YYYY-MM-DD') as order_date, b.ordered, b.position,
  b.pratica_id, b.trattativa_zite_id, (select count(*) from public.supplier_invoice_allocations a where a.bene_id = b.id) as allocations, b.zite_bene_id, b.drive_folder`;

async function elenco(p: Record<string, unknown>) {
  const pratica = optUuid(p.pratica_id, "pratica_id");
  const trattativa = optZiteId(p.trattativa_id, "trattativa_id");
  if (!pratica && !trattativa) throw new BeniError(400, "pratica_or_trattativa");
  const trattative = Array.isArray(p.trattative) ? p.trattative.slice(0, 20).map((t) => ziteId(t, "trattative")) : [];
  return await comeCollega(p, async (tx) => {
    if (pratica) {
      const [su] = await tx`select id from public.pratiche where id = ${pratica}`;
      if (su && trattative.length) {
        await tx`update public.beni set pratica_id = ${pratica}
                  where pratica_id is null and removed_at is null and trattativa_zite_id = any(${trattative}::text[])`;
      }
      const righe = su
        ? await tx`select ${COLONNE(tx)} from public.beni b where b.pratica_id = ${pratica} and b.removed_at is null order by b.position, b.created_at`
        : trattative.length
          ? await tx`select ${COLONNE(tx)} from public.beni b where b.pratica_id is null and b.removed_at is null and b.trattativa_zite_id = any(${trattative}::text[]) order by b.position, b.created_at`
          : [];
      const visibili = (righe as unknown as Riga[]).filter((r) => r.zite_bene_id != null || Number(r.allocations) > 0);
      return { beni: await conValori(tx, visibili), pratica_su_supabase: !!su };
    }
    const righe = await tx`select ${COLONNE(tx)} from public.beni b where b.trattativa_zite_id = ${trattativa} and b.removed_at is null order by b.position, b.created_at`;
    return { beni: await conValori(tx, righe as unknown as Riga[]), pratica_su_supabase: false };
  });
}

async function salva(p: Record<string, unknown>) {
  const b = (p.bene ?? {}) as Record<string, unknown>;
  const id = optUuid(b.id, "id");
  const name = optText(b.name, "name", 200);
  const supplier = optText(b.supplier, "supplier", 200);
  const orderDate = optText(b.order_date, "order_date", 10);
  if (orderDate && !DAY.test(orderDate)) throw new BeniError(400, "invalid_order_date");
  if (b.ordered !== undefined && typeof b.ordered !== "boolean") throw new BeniError(400, "invalid_ordered");
  return await comeCollega(p, async (tx) => {
    let riga: Riga | undefined;
    if (!id) {
      const pratica = optUuid(b.pratica_id, "pratica_id");
      const trattativa = optZiteId(b.trattativa_id, "trattativa_id");
      if (!pratica && !trattativa) throw new BeniError(400, "pratica_or_trattativa");
      if (pratica) {
        const [su] = await tx`select id from public.pratiche where id = ${pratica}`;
        if (!su) throw new BeniError(409, "pratica_non_su_supabase");
      }
      const [{ pos }] = pratica
        ? await tx`select coalesce(max(position), 0) + 1 as pos from public.beni where pratica_id = ${pratica}`
        : await tx`select coalesce(max(position), 0) + 1 as pos from public.beni where trattativa_zite_id = ${trattativa}`;
      [riga] = await tx`insert into public.beni (pratica_id, trattativa_zite_id, name, supplier_hint, order_date, ordered, position)
                         values (${pratica}, ${trattativa}, ${name ?? "Nuovo bene"}, ${supplier ?? null}, ${orderDate ?? null}, ${b.ordered === true}, ${pos})
                         returning id` as unknown as Riga[];
      await tx`update public.beni set zite_bene_id = id::text where id = ${riga!.id}`;
      if (pratica) {
        // the same rule as the invoice import: a placeholder with no invoices is put aside once a managed good exists
        await tx`update public.beni be set removed_at = now()
                  where be.pratica_id = ${pratica} and be.zite_bene_id is null and be.removed_at is null
                    and not exists (select 1 from public.supplier_invoice_allocations a where a.bene_id = be.id)`;
      }
    } else {
      [riga] = await tx`update public.beni set
                           name = coalesce(${name === undefined ? null : name ?? ""}, name),
                           supplier_hint = case when ${supplier === undefined} then supplier_hint else ${supplier ?? null} end,
                           order_date = case when ${orderDate === undefined} then order_date else ${orderDate ?? null}::date end,
                           ordered = coalesce(${b.ordered === undefined ? null : b.ordered === true}, ordered),
                           zite_bene_id = coalesce(zite_bene_id, id::text)
                         where id = ${id} and removed_at is null returning id` as unknown as Riga[];
      if (!riga) throw new BeniError(404, "bene_not_found");
    }
    const [r] = await tx`select ${COLONNE(tx)} from public.beni b where b.id = ${riga!.id}`;
    return { bene: (await conValori(tx, [r as unknown as Riga]))[0] };
  });
}

async function togli(p: Record<string, unknown>) {
  const id = oneUuid(p.id, "id");
  return await comeCollega(p, async (tx) => {
    const [{ n }] = await tx`select count(*)::int as n from public.supplier_invoice_allocations where bene_id = ${id}`;
    if (n > 0) throw new BeniError(409, "bene_con_fatture");
    const r = await tx`update public.beni set removed_at = now() where id = ${id} and removed_at is null returning id`;
    if (!r.length) throw new BeniError(404, "bene_not_found");
    return { ok: true };
  });
}

async function valore(p: Record<string, unknown>) {
  const bene = oneUuid(p.bene_id, "bene_id");
  const dato = ziteId(p.dato_id, "dato_id");
  const value = optText(p.value, "value", 20000) ?? null;
  return await comeCollega(p, async (tx) => {
    const [b] = await tx`select id from public.beni where id = ${bene} and removed_at is null`;
    if (!b) throw new BeniError(404, "bene_not_found");
    if (value === null) await tx`delete from public.bene_values where bene_id = ${bene} and dato_id = ${dato}`;
    else await tx`insert into public.bene_values (bene_id, dato_id, value) values (${bene}, ${dato}, ${value})
                  on conflict (bene_id, dato_id) do update set value = excluded.value`;
    return { ok: true };
  });
}

async function dettaglio(p: Record<string, unknown>) {
  const id = oneUuid(p.id, "id");
  return await comeCollega(p, async (tx) => {
    const [r] = await tx`select ${COLONNE(tx)} from public.beni b where b.id = ${id} and b.removed_at is null`;
    if (!r) throw new BeniError(404, "bene_not_found");
    const righe = await tx`select invoice_id, supplier_name, number, to_char(issue_date, 'YYYY-MM-DD') as issue_date, doc_type, description,
                                  to_char(period_from, 'YYYY-MM-DD') as period_from, to_char(period_to, 'YYYY-MM-DD') as period_to, share_pct::text, amount::text
                             from public.supplier_invoice_by_bene where bene_id = ${id} order by issue_date, number, position`;
    return { bene: (await conValori(tx, [r as unknown as Riga]))[0], righe };
  });
}

async function documento(p: Record<string, unknown>) {
  const bene = oneUuid(p.bene_id, "bene_id");
  const dato = ziteId(p.dato_id, "dato_id");
  const name = optText(p.name, "name", 255);
  if (!name) throw new BeniError(400, "invalid_name");
  const driveFile = p.drive_file_id == null ? null : (typeof p.drive_file_id === "string" && DRIVE_ID.test(p.drive_file_id) ? p.drive_file_id : null);
  if (p.drive_file_id != null && !driveFile) throw new BeniError(400, "invalid_drive_file_id");
  const link = optText(p.link, "link", 1000) ?? null;
  if (link && !/^https:\/\//.test(link)) throw new BeniError(400, "invalid_link");
  if (!driveFile && !link) throw new BeniError(400, "file_or_link");
  const validUntil = optText(p.valid_until, "valid_until", 10) ?? null;
  if (validUntil && !DAY.test(validUntil)) throw new BeniError(400, "invalid_valid_until");
  return await comeCollega(p, async (tx) => {
    const [b] = await tx`select id from public.beni where id = ${bene} and removed_at is null`;
    if (!b) throw new BeniError(404, "bene_not_found");
    const [d] = await tx`insert into public.bene_documents (bene_id, dato_id, name, drive_file_id, link, valid_until)
                          values (${bene}, ${dato}, ${name}, ${driveFile}, ${link}, ${validUntil}) returning id`;
    return { ok: true, id: d.id };
  });
}

async function togliDocumento(p: Record<string, unknown>) {
  const id = oneUuid(p.id, "id");
  return await comeCollega(p, async (tx) => {
    const r = await tx`update public.bene_documents set removed_at = now() where id = ${id} and removed_at is null returning id`;
    if (!r.length) throw new BeniError(404, "document_not_found");
    return { ok: true };
  });
}

async function cartella(p: Record<string, unknown>) {
  const bene = oneUuid(p.bene_id, "bene_id");
  if (typeof p.drive_folder !== "string" || !DRIVE_ID.test(p.drive_folder)) throw new BeniError(400, "invalid_drive_folder");
  return await comeCollega(p, async (tx) => {
    const r = await tx`update public.beni set drive_folder = ${p.drive_folder as string} where id = ${bene} and removed_at is null returning id`;
    if (!r.length) throw new BeniError(404, "bene_not_found");
    return { ok: true };
  });
}

const AZIONI: Record<string, (p: Record<string, unknown>) => Promise<unknown>> = {
  elenco, salva, togli, valore, dettaglio, documento, togli_documento: togliDocumento, cartella,
};

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { ok: false, error: "method_not_allowed" });
  if (!SECRET_STAFF) return reply(500, { ok: false, error: "not_configured" });
  if (!safeEqual(req.headers.get("x-bridge-secret") ?? "", SECRET_STAFF)) return reply(401, { ok: false, error: "unauthorized" });
  let payload: Record<string, unknown>;
  try {
    const raw = await req.text();
    if (raw.length > MAX_BODY) return reply(413, { ok: false, error: "too_large" });
    payload = JSON.parse(raw);
    if (typeof payload !== "object" || payload === null || Array.isArray(payload)) throw new Error("not an object");
  } catch {
    return reply(400, { ok: false, error: "invalid_json" });
  }
  try {
    const action = typeof payload.action === "string" ? payload.action : "";
    if (!Object.hasOwn(AZIONI, action)) throw new BeniError(400, "unknown_action");
    return reply(200, { ok: true, data: await AZIONI[action](payload) });
  } catch (e) {
    if (e instanceof BeniError) return reply(e.status, { ok: false, error: e.code });
    const code = (e as { code?: string })?.code ?? "";
    console.error("beni error", code, (e as { message?: string })?.message ?? "");
    if (code === "42501") return reply(403, { ok: false, error: "not_allowed" });
    if (code === "P0001") return reply(400, { ok: false, error: (e as { message?: string })?.message ?? "invalid", message: true });
    if (code === "23514" || code === "22P02" || code === "22007" || code === "22008") return reply(400, { ok: false, error: "invalid_input" });
    return reply(500, { ok: false, error: "internal_error" });
  }
});
