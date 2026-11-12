// resend-webhook (v1, 2026-11-10)
// Resend calls this when an email changes state. Today it is used for «Richiedi firma» (Allegati per la firma, passo 9): the Gestionale stores the Resend id
// of the email in signature_attachments.sent_message_id; here «delivered» / «bounced» / «complained» (and «opened», if open tracking is ever turned on)
// become events in the document's history (signature_events, source 'resend'). Emails that are not a «Richiedi firma» (notifications…) are ignored.
//
// Trust: no JWT (Resend cannot send one). Every call is signed by Resend with the webhook's signing secret (Svix scheme: headers svix-id, svix-timestamp,
// svix-signature; HMAC-SHA256 of "<id>.<timestamp>.<body>" with the base64 key after "whsec_"). The secret is RESEND_WEBHOOK_SECRET in the Edge Function
// secrets, set by Giacomo in the Supabase dashboard (never in the repo, never in a chat). Unsigned, wrongly signed or older than 5 minutes = 401.
// Each Resend event is recorded once (external_event_id = svix-id + document), so Resend's retries are harmless. Unknown emails answer 200, so Resend stops retrying.

import postgres from "npm:postgres@3.4.5";

const SECRET = Deno.env.get("RESEND_WEBHOOK_SECRET") ?? "";
const DB_URL = Deno.env.get("SUPABASE_DB_URL")!;
const MAX_BODY = 200_000;
const TOLLERANZA_S = 300;

const sql = postgres(DB_URL, { prepare: false, max: 2, idle_timeout: 20 });

const EVENTI: Record<string, string> = {
  "email.delivered": "delivered",
  "email.bounced": "bounced",
  "email.complained": "bounced",
  "email.opened": "opened",
};

function reply(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function base64ToBytes(b64: string): Uint8Array<ArrayBuffer> {
  const bin = atob(b64);
  const out = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function safeEqual(a: string, b: string) {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  if (ea.length !== eb.length || ea.length === 0) return false;
  let diff = 0;
  for (let i = 0; i < ea.length; i++) diff |= ea[i] ^ eb[i];
  return diff === 0;
}

async function firmaValida(id: string, ts: string, firme: string, corpo: string): Promise<boolean> {
  if (!SECRET.startsWith("whsec_")) return false;
  const quando = Number(ts);
  if (!Number.isFinite(quando) || Math.abs(Date.now() / 1000 - quando) > TOLLERANZA_S) return false;
  let chiave: CryptoKey;
  try {
    chiave = await crypto.subtle.importKey("raw", base64ToBytes(SECRET.slice("whsec_".length)), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  } catch { return false; }
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", chiave, new TextEncoder().encode(`${id}.${ts}.${corpo}`)));
  const attesa = btoa(String.fromCharCode(...mac));
  // the header can hold several signatures ("v1,<sig> v1,<sig>") while the secret is being rotated
  return firme.split(" ").some((f) => { const [v, s] = f.split(","); return v === "v1" && !!s && safeEqual(s, attesa); });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { ok: false, error: "method_not_allowed" });
  if (!SECRET) return reply(500, { ok: false, error: "not_configured" });
  const corpo = await req.text();
  if (corpo.length > MAX_BODY) return reply(413, { ok: false, error: "too_large" });
  const id = req.headers.get("svix-id") ?? "", ts = req.headers.get("svix-timestamp") ?? "", firme = req.headers.get("svix-signature") ?? "";
  if (!id || id.length > 100 || !(await firmaValida(id, ts, firme, corpo))) return reply(401, { ok: false, error: "invalid_signature" });

  let evento: { type?: unknown; created_at?: unknown; data?: Record<string, unknown> };
  try { evento = JSON.parse(corpo); } catch { return reply(400, { ok: false, error: "invalid_json" }); }
  const tipo = typeof evento.type === "string" ? EVENTI[evento.type] : undefined;
  const emailId = typeof evento.data?.email_id === "string" ? evento.data.email_id : null;
  if (!tipo || !emailId) return reply(200, { ok: true, ignored: true });

  try {
    const bounce = evento.data?.bounce as Record<string, unknown> | undefined;
    const dettaglio = {
      resend_type: evento.type, at: typeof evento.created_at === "string" ? evento.created_at : null,
      to: Array.isArray(evento.data?.to) ? (evento.data!.to as unknown[]).filter((x) => typeof x === "string").slice(0, 20) : [],
      ...(bounce ? { motivo: String(bounce.message ?? bounce.subType ?? bounce.type ?? "").slice(0, 300) } : {}),
    };
    const righe = await sql`
      insert into public.signature_events (organization_id, attachment_id, event, source, detail, external_event_id)
      select a.organization_id, a.id, ${tipo}, 'resend', ${JSON.stringify(dettaglio)}::jsonb, ${id} || ':' || a.id::text
        from public.signature_attachments a
       where a.sent_message_id = ${emailId}
      on conflict (external_event_id) do nothing
      returning attachment_id`;
    return reply(200, { ok: true, recorded: righe.length });
  } catch (e) {
    console.error("resend-webhook error", (e as { code?: string })?.code ?? "", (e as { message?: string })?.message ?? "");
    return reply(500, { ok: false, error: "internal_error" });
  }
});
