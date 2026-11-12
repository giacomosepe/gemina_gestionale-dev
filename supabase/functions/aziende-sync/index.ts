// aziende-sync (v1, 2026-11-04)
// Zite Aziende -> public.companies. Called by the Gestionale's server (a Zite endpoint), never by a browser.
//
// Why: until today public.companies had been loaded once (2026-10-19) and new Zite aziende never reached
// Supabase, so their pratiche, Qonto invoices and supplier invoices could not find their company.
//
// Trust model: the same as portal-bridge's server-to-server actions (sync_pratica, sync_partner):
//   header "x-bridge-secret" = BRIDGE_SECRET_STAFF (the Gestionale's secret). The portal secret is refused.
// Kept separate from portal-bridge on purpose: adding it cannot affect messages, the Portale segnalatori or
// the other syncs. It can be merged into portal-bridge later.
//
// Request:  POST { "action": "sync_azienda", "zite_azienda_id", "name", "vat_number"?, "qonto_client_id"? }
//           POST { "action": "resync_aziende", "aziende": [ { same fields }, ... ] }   (250 at most per call)
// Response: { ok: true, data: { inserted, updated, unchanged, skipped, qonto_conflicts, ... } } or { ok: false, error }
//
// Field rules (enforced in private.sync_companies):
//   - never deletes: an azienda removed in Zite stays (other records point to it)
//   - vat_number: key absent = kept; null or blank = cleared
//   - qonto_client_id: only filled when empty (Supabase also writes it when matching Qonto invoices by P.IVA);
//     a different value is reported in qonto_conflicts, never overwritten
//   - resync_aziende upserts only and marks nothing as removed, so the list can be split into several calls safely

import postgres from "npm:postgres@3.4.5";

const SECRET_STAFF = Deno.env.get("BRIDGE_SECRET_STAFF") ?? "";
const DB_URL = Deno.env.get("SUPABASE_DB_URL")!;
const MAX_ROWS = 250;

const sql = postgres(DB_URL, { prepare: false, max: 2, idle_timeout: 20 });

class SyncError extends Error {
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

const text = (v: unknown, name: string, max: number) => {
  if (typeof v !== "string" || v.trim().length === 0 || v.length > max) throw new SyncError(400, `invalid_${name}`);
  return v.trim();
};

type AziendaRow = { zite_azienda_id: string; name: string; vat_number?: string | null; qonto_client_id?: string | null };

function parseAzienda(raw: unknown): AziendaRow {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) throw new SyncError(400, "invalid_azienda");
  const p = raw as Record<string, unknown>;
  const row: AziendaRow = {
    zite_azienda_id: text(p.zite_azienda_id, "zite_azienda_id", 100),
    name: text(p.name, "name", 300),
  };
  // Key absent = keep what Supabase has. null / blank = clear.
  if (Object.hasOwn(p, "vat_number")) {
    const v = p.vat_number;
    if (v == null || (typeof v === "string" && v.trim() === "")) row.vat_number = null;
    else row.vat_number = text(v, "vat_number", 40);
  }
  if (Object.hasOwn(p, "qonto_client_id")) {
    const q = p.qonto_client_id;
    row.qonto_client_id = q == null || (typeof q === "string" && q.trim() === "") ? null : text(q, "qonto_client_id", 100);
  }
  return row;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { ok: false, error: "method_not_allowed" });
  if (!SECRET_STAFF) return reply(500, { ok: false, error: "not_configured" });
  if (!safeEqual(req.headers.get("x-bridge-secret") ?? "", SECRET_STAFF)) {
    return reply(401, { ok: false, error: "unauthorized" });
  }

  let payload: Record<string, unknown>;
  try {
    const raw = await req.text();
    if (raw.length > 64_000) return reply(413, { ok: false, error: "too_large" });
    payload = JSON.parse(raw);
    if (typeof payload !== "object" || payload === null || Array.isArray(payload)) throw new Error("not an object");
  } catch {
    return reply(400, { ok: false, error: "invalid_json" });
  }

  try {
    let rows: AziendaRow[];
    if (payload.action === "sync_azienda") {
      rows = [parseAzienda(payload)];
    } else if (payload.action === "resync_aziende") {
      if (!Array.isArray(payload.aziende) || payload.aziende.length === 0 || payload.aziende.length > MAX_ROWS) {
        throw new SyncError(400, "invalid_aziende");
      }
      rows = payload.aziende.map(parseAzienda);
    } else {
      throw new SyncError(400, "unknown_action");
    }
    const [r] = await sql`select private.sync_companies(${JSON.stringify(rows)}::text::jsonb) as result`;
    return reply(200, { ok: true, data: r.result });
  } catch (e) {
    if (e instanceof SyncError) return reply(e.status, { ok: false, error: e.code });
    // Code and message only, never the payload
    console.error("aziende-sync error", (e as { code?: string })?.code ?? "", (e as { message?: string })?.message ?? "");
    return reply(500, { ok: false, error: "internal_error" });
  }
});
