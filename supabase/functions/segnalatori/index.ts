// segnalatori (v1, 2026-11-12; migration staff_leave_francesca_and_partner_reference_manager)
// Segnalatori data that lives only in Supabase (not in the Zite Segnalatori table). Called by the Gestionale's server (Zite), never by a browser.
// Same trust model and secret as beni and allegati-firma: header "x-bridge-secret" = BRIDGE_SECRET_STAFF; the colleague is named by zite_user_id,
// taken by the Gestionale's server from context.user, never from the browser. Kept apart from portal-bridge so it cannot affect the rest.
//
// Actions:
//   invitato { zite_user_id, zite_segnalatore_id }
//     The Gestionale has just sent this segnalatore the portal invitation (button «Invita al portale» or a new segnalatore with an email).
//     The colleague who sent it becomes the Reference Manager (partners.reference_manager_id), only if none is set: a default, never an
//     overwrite. A colleague without a current staff profile, or a segnalatore not yet in Supabase, changes nothing.  -> { set: 0 | 1 }

import postgres from "npm:postgres@3.4.5";

const SECRET_STAFF = Deno.env.get("BRIDGE_SECRET_STAFF") ?? "";
const DB_URL = Deno.env.get("SUPABASE_DB_URL")!;
const MAX_BODY = 10_000;
const ZITE_ID = /^[A-Za-z0-9_-]{1,100}$/;

const sql = postgres(DB_URL, { prepare: false, max: 2, idle_timeout: 20 });

class SegnalatoriError extends Error {
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

const ziteId = (v: unknown, name: string): string => {
  if (typeof v !== "string" || !ZITE_ID.test(v)) throw new SegnalatoriError(400, `invalid_${name}`);
  return v;
};

async function invitato(p: Record<string, unknown>) {
  const utente = ziteId(p.zite_user_id, "zite_user_id");
  const segnalatore = ziteId(p.zite_segnalatore_id, "zite_segnalatore_id");
  const righe = await sql`
    update public.partners pa
       set reference_manager_id = s.id
      from public.profiles s
     where pa.zite_segnalatore_id = ${segnalatore}
       and pa.reference_manager_id is null
       and s.zite_user_id = ${utente}
       and s.role = 'staff'
    returning pa.id`;
  return { set: righe.length };
}

const AZIONI: Record<string, (p: Record<string, unknown>) => Promise<unknown>> = { invitato };

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
    if (!Object.hasOwn(AZIONI, action)) throw new SegnalatoriError(400, "unknown_action");
    return reply(200, { ok: true, data: await AZIONI[action](payload) });
  } catch (e) {
    if (e instanceof SegnalatoriError) return reply(e.status, { ok: false, error: e.code });
    const code = (e as { code?: string })?.code ?? "";
    console.error("segnalatori error", code, (e as { message?: string })?.message ?? "");
    if (code === "22023") return reply(400, { ok: false, error: (e as { message?: string })?.message ?? "invalid", message: true });
    return reply(500, { ok: false, error: "internal_error" });
  }
});
