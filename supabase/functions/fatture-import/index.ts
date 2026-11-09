// fatture-import (v5, 2026-11-05)
// Supplier invoices read by the Gestionale from a pratica's Google Drive folder -> Supabase.
// Called by the Gestionale's server (a Zite endpoint), never by a browser. Same trust model and secret as aziende-sync:
// header "x-bridge-secret" = BRIDGE_SECRET_STAFF. Kept apart from portal-bridge so it cannot affect the rest.
//
// Actions:
//   gia_importati { drive_ids: string[] }  -> { ids }   which Drive files are already imported (max 5000)
//   importa { pratica_id, beni: [{id, nome, fornitore}], fatture: [ invoice as read by the Gestionale + xml_base64 ] }  (max 25 per call)
//     1. a copy of each original XML (or .p7m) goes to the private bucket "supplier-invoices" at <organization_id>/<sha256>.<ext>
//     2. private.import_pratica_invoices writes invoices, lines, the goods of the pratica and the proposed goods
// The XML is never parsed here: the Gestionale parses it (safely) and sends the result; here only the copy is stored.
//
// v2 (2026-11-04): the «Fatture fornitori» screen. These actions act AS the colleague logged in to Zite (zite_user_id, taken by the
// Gestionale's server from context.user): they run as role authenticated with that staff profile, so RLS applies and the database records
// who assigned. A Zite user without a current staff profile is refused with "staff_unknown" (the Gestionale creates it through the bridge).
//   pagina   { zite_user_id, pratica_id, offset?, limit? }          -> public.supplier_invoices_page
//   righe    { zite_user_id, invoice_ids }                           -> public.supplier_invoice_lines_json (max 200 invoices)
//   assegna  { zite_user_id, pratica_id, invoice_ids, line_ids, shares } -> public.set_supplier_allocation
//   elimina  { zite_user_id, pratica_id, invoice_ids }               -> public.delete_supplier_invoices
//   categoria { zite_user_id, supplier_ids, category_id }            -> public.set_supplier_category
//   riepilogo { zite_user_id, pratica_id, filtri? }                  -> public.supplier_invoices_summary (v4: per bene, fornitore, categoria)
//   nota_credito { zite_user_id, pratica_id, invoice_ids, inclusa }  -> public.set_credit_notes_included (v5: una nota di credito conta nei totali solo se inclusa)

import postgres from "npm:postgres@3.4.5";
import { createClient } from "npm:@supabase/supabase-js@2.50.0";

const SECRET_STAFF = Deno.env.get("BRIDGE_SECRET_STAFF") ?? "";
const DB_URL = Deno.env.get("SUPABASE_DB_URL")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SECRET_KEY = (() => {
  try { return JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}")["default"]; } catch { return undefined; }
})() ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const BUCKET = "supplier-invoices";
const MAX_FATTURE = 25;
const MAX_BODY = 12_000_000;
const MAX_XML = 5_000_000;

const sql = postgres(DB_URL, { prepare: false, max: 2, idle_timeout: 20 });
const admin = createClient(SUPABASE_URL, SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

class ImportError extends Error {
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

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SHA = /^[0-9a-f]{64}$/;

function base64ToBytes(b64: string): Uint8Array<ArrayBuffer> {
  const bin = atob(b64);
  const out = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function sha256Hex(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(d)].map((x) => x.toString(16).padStart(2, "0")).join("");
}

/** Stores the original file; the name is its own sha256, checked here, so a copy can never overwrite another invoice. */
async function salvaCopia(org: string, f: Record<string, unknown>): Promise<string | null> {
  if (typeof f.xml_base64 !== "string" || !f.xml_base64) return null;
  const bytes = base64ToBytes(f.xml_base64);
  if (bytes.length > MAX_XML) throw new ImportError(413, "file_too_large");
  const sha = await sha256Hex(bytes);
  if (sha !== f.sha256) throw new ImportError(400, "sha_mismatch");
  const firmato = f.was_signed === true;
  const path = `${org}/${sha}.${firmato ? "xml.p7m" : "xml"}`;
  const { error } = await admin.storage.from(BUCKET).upload(path, bytes, {
    contentType: firmato ? "application/pkcs7-mime" : "application/xml",
    upsert: false,
  });
  // Already there (same file imported before): the copy is the same bytes, keep it.
  if (error && !/exist|duplicate/i.test(error.message)) {
    console.error("fatture-import storage", error.message);
    return null;
  }
  return path;
}

async function importa(p: Record<string, unknown>) {
  if (typeof p.pratica_id !== "string" || !UUID.test(p.pratica_id)) throw new ImportError(400, "invalid_pratica_id");
  if (!Array.isArray(p.beni) || p.beni.length > 100) throw new ImportError(400, "invalid_beni");
  if (!Array.isArray(p.fatture) || p.fatture.length === 0 || p.fatture.length > MAX_FATTURE) throw new ImportError(400, "invalid_fatture");
  const [prat] = await sql`select organization_id from public.pratiche where id = ${p.pratica_id} and removed_at is null`;
  if (!prat) throw new ImportError(404, "pratica_not_found");

  const fatture: Record<string, unknown>[] = [];
  for (const raw of p.fatture) {
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) throw new ImportError(400, "invalid_fattura");
    const f = raw as Record<string, unknown>;
    if (typeof f.sha256 !== "string" || !SHA.test(f.sha256)) throw new ImportError(400, "invalid_sha256");
    const xml_path = await salvaCopia(prat.organization_id, f);
    const { xml_base64: _drop, ...resto } = f;
    fatture.push({ ...resto, xml_path });
  }
  const batch = { source: typeof p.source === "string" ? p.source.slice(0, 200) : "drive", invoices: fatture };
  const [r] = await sql`select private.import_pratica_invoices(${p.pratica_id}::uuid, ${JSON.stringify(p.beni)}::text::jsonb,
                                                             ${JSON.stringify(batch)}::text::jsonb) as result`;
  return r.result;
}

async function giaImportati(p: Record<string, unknown>) {
  if (!Array.isArray(p.drive_ids) || p.drive_ids.length > 5000 || p.drive_ids.some((x) => typeof x !== "string" || x.length > 200)) {
    throw new ImportError(400, "invalid_drive_ids");
  }
  if (!p.drive_ids.length) return { ids: [] };
  const [r] = await sql`select private.supplier_invoices_from_drive(${p.drive_ids as string[]}::text[]) as ids`;
  return { ids: r.ids ?? [] };
}

// ---- v2: actions as the colleague
const uuids = (v: unknown, name: string, max: number): string[] => {
  if (v == null) return [];
  if (!Array.isArray(v) || v.length > max || v.some((x) => typeof x !== "string" || !UUID.test(x))) throw new ImportError(400, `invalid_${name}`);
  return v as string[];
};
const oneUuid = (v: unknown, name: string): string => {
  if (typeof v !== "string" || !UUID.test(v)) throw new ImportError(400, `invalid_${name}`);
  return v;
};

async function comeCollega<T>(p: Record<string, unknown>, fn: (tx: postgres.TransactionSql) => Promise<T>): Promise<T> {
  if (typeof p.zite_user_id !== "string" || !p.zite_user_id || p.zite_user_id.length > 100) throw new ImportError(400, "invalid_zite_user_id");
  const [me] = await sql`select id from public.profiles where zite_user_id = ${p.zite_user_id} and role = 'staff'`;
  if (!me) throw new ImportError(403, "staff_unknown");
  return await sql.begin(async (tx) => {
    await tx`select set_config('request.jwt.claims', ${JSON.stringify({ sub: me.id, role: "authenticated" })}, true)`;
    await tx.unsafe("set local role authenticated");
    return await fn(tx);
  }) as T;
}

async function pagina(p: Record<string, unknown>) {
  const pratica = oneUuid(p.pratica_id, "pratica_id");
  const offset = Number.isSafeInteger(p.offset) ? Number(p.offset) : 0;
  const limit = Number.isSafeInteger(p.limit) ? Number(p.limit) : 50;
  const filtri = soloFiltri(p.filtri);
  return await comeCollega(p, async (tx) => {
    const [r] = await tx`select public.supplier_invoices_page(${pratica}::uuid, ${offset}::int, ${limit}::int, 30, ${JSON.stringify(filtri)}::jsonb) as data`;
    return r.data;
  });
}

// Only the known facets, each a short list of short strings: whatever else arrives is dropped.
const FACCETTE = ["stato", "bene", "fornitore", "categoria", "anno", "tipo", "avvisi"];
function soloFiltri(v: unknown): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  if (!v || typeof v !== "object") return out;
  for (const k of FACCETTE) {
    const a = (v as Record<string, unknown>)[k];
    if (Array.isArray(a)) {
      const l = a.filter((x): x is string => typeof x === "string" && x.length > 0 && x.length <= 80).slice(0, 100);
      if (l.length) out[k] = l;
    }
  }
  return out;
}

async function righe(p: Record<string, unknown>) {
  const ids = uuids(p.invoice_ids, "invoice_ids", 200);
  return await comeCollega(p, async (tx) => {
    const [r] = await tx`select public.supplier_invoice_lines_json(${ids}::uuid[]) as data`;
    return { lines: r.data };
  });
}

async function assegna(p: Record<string, unknown>) {
  const pratica = oneUuid(p.pratica_id, "pratica_id");
  const inv = uuids(p.invoice_ids, "invoice_ids", 2000);
  const lines = uuids(p.line_ids, "line_ids", 5000);
  if (!Array.isArray(p.shares) || p.shares.length > 50) throw new ImportError(400, "invalid_shares");
  const shares = p.shares.map((x) => {
    const s = x as Record<string, unknown>;
    if (typeof s?.pct !== "number" || !(s.pct > 0) || s.pct > 100) throw new ImportError(400, "invalid_shares");
    if (s.not_applicable === true) return { not_applicable: true, pct: s.pct };
    return { bene_id: oneUuid(s.bene_id, "bene_id"), pct: s.pct };
  });
  return await comeCollega(p, async (tx) => {
    const [r] = await tx`select public.set_supplier_allocation(${pratica}::uuid, ${inv}::uuid[], ${lines}::uuid[], ${JSON.stringify(shares)}::text::jsonb) as n`;
    return { lines: r.n };
  });
}

async function elimina(p: Record<string, unknown>) {
  const pratica = oneUuid(p.pratica_id, "pratica_id");
  const inv = uuids(p.invoice_ids, "invoice_ids", 2000);
  return await comeCollega(p, async (tx) => {
    const [r] = await tx`select public.delete_supplier_invoices(${pratica}::uuid, ${inv}::uuid[]) as n`;
    return { deleted: r.n };
  });
}

async function categoria(p: Record<string, unknown>) {
  const suppliers = uuids(p.supplier_ids, "supplier_ids", 2000);
  const cat = p.category_id == null ? null : oneUuid(p.category_id, "category_id");
  return await comeCollega(p, async (tx) => {
    const [r] = await tx`select public.set_supplier_category(${suppliers}::uuid[], ${cat}::uuid) as n`;
    return { suppliers: r.n };
  });
}

// v4: the summaries per bene / fornitore / categoria, on the invoices that pass the same filters as the list.
async function riepilogo(p: Record<string, unknown>) {
  const pratica = oneUuid(p.pratica_id, "pratica_id");
  const filtri = soloFiltri(p.filtri);
  return await comeCollega(p, async (tx) => {
    const [r] = await tx`select public.supplier_invoices_summary(${pratica}::uuid, ${JSON.stringify(filtri)}::jsonb) as data`;
    return r.data;
  });
}

// v5: a credit note stays out of the totals until someone includes it (clients rarely mean to send them).
async function notaCredito(p: Record<string, unknown>) {
  const pratica = oneUuid(p.pratica_id, "pratica_id");
  const inv = uuids(p.invoice_ids, "invoice_ids", 2000);
  if (typeof p.inclusa !== "boolean") throw new ImportError(400, "invalid_inclusa");
  return await comeCollega(p, async (tx) => {
    const [r] = await tx`select public.set_credit_notes_included(${pratica}::uuid, ${inv}::uuid[], ${p.inclusa as boolean}) as n`;
    return { invoices: r.n };
  });
}

const AZIONI: Record<string, (p: Record<string, unknown>) => Promise<unknown>> = { pagina, righe, assegna, elimina, categoria, riepilogo, nota_credito: notaCredito };

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
    if (payload.action === "gia_importati") return reply(200, { ok: true, data: await giaImportati(payload) });
    if (payload.action === "importa") return reply(200, { ok: true, data: await importa(payload) });
    if (typeof payload.action === "string" && Object.hasOwn(AZIONI, payload.action)) {
      return reply(200, { ok: true, data: await AZIONI[payload.action](payload) });
    }
    throw new ImportError(400, "unknown_action");
  } catch (e) {
    if (e instanceof ImportError) return reply(e.status, { ok: false, error: e.code });
    const code = (e as { code?: string })?.code ?? "";
    console.error("fatture-import error", code, (e as { message?: string })?.message ?? "");
    if (code === "22023" || code === "P0001") return reply(400, { ok: false, error: (e as { message?: string })?.message ?? "invalid", message: true });
    if (code === "42501") return reply(403, { ok: false, error: "not_allowed" });
    return reply(500, { ok: false, error: "internal_error" });
  }
});
