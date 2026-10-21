// message-emails (v2, steps 6 and 7, 2026-10-21)
// Emails about referrer (segnalatore) messages, sent by Supabase + Resend instead of Zite (0 Zite runs).
// Called only by the database (migration 20261021133651): the trigger on messages (mode "message", one conversation,
// right after Gemina writes) and pg_cron every 5 minutes (mode "sweep"). The call carries the internal secret the
// database keeps in Vault ('message_emails_secret'); nothing else can make it send.
//
// Rules (Giacomo, 21 Oct):
// - To the referrer: when Gemina writes, at once; at most ONE email per conversation every 10 minutes; none if the
//   referrer has already read it in the portal. Content: "Hai un nuovo messaggio da Gemina Advisory", the subject of the
//   conversation (never the text), a button to the portal. Replies by email are not invited (reply-to stays partners@).
// - To the team: a message notification still unread by anyone at Gemina after 15 minutes: one email per person per run,
//   listing the subjects (never the text). Never for kind 'event' (Zite emails those).
// - Documents (step 7, migration 20261021145534): "Notifica segnalatore" (public.notify_document) calls mode "document": one
//   email to the referrer with the document's name (never its content) and a button to the portal. A file the referrer
//   shares outside a message gives the team a bell (kind 'document'): unread by anyone at Gemina after 15 minutes, it joins
//   the same team email as the messages.
// - Real referrer addresses only where the project allows them (PARTNER_EMAILS_REAL=true in production,
//   DEV_TEST_PARTNER_EMAILS in dev), as the bridge. Placeholders (@example.test) never.
// - Each conversation/notification is claimed in the database before sending; if Resend fails it is released, so the
//   next sweep tries again.
//
// Settings (Edge Function secrets): RESEND_API_KEY (required; dev also accepts RESEND_SUPABASE_KEY); PARTNER_EMAILS_REAL / DEV_TEST_PARTNER_EMAILS (as the
// bridge); optional URL_PORTALE, URL_GESTIONALE.

import postgres from "npm:postgres@3.4.5";

const DB_URL = Deno.env.get("SUPABASE_DB_URL")!;
// The dev project holds the key as RESEND_SUPABASE_KEY (set 21 Oct); production uses RESEND_API_KEY (checklist).
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? Deno.env.get("RESEND_SUPABASE_KEY") ?? "";
const PARTNER_EMAILS_REAL = Deno.env.get("PARTNER_EMAILS_REAL") === "true";
const DEV_TEST_PARTNER_EMAILS = new Set((Deno.env.get("DEV_TEST_PARTNER_EMAILS") ?? "")
  .split(",").map((e) => e.trim().toLowerCase()).filter(Boolean));
const URL_PORTALE = (Deno.env.get("URL_PORTALE") ?? "https://partners.geminaadvisory.com").replace(/\/+$/, "");
const URL_GESTIONALE = (Deno.env.get("URL_GESTIONALE") ?? "https://gestionale.geminaadvisory.com").replace(/\/+$/, "");

const FROM_REFERRER = "Gemina Team Segnalatori <partners@mail.geminaadvisory.com>";
const REPLY_TO_REFERRER = "partners@geminaadvisory.com";
const FROM_TEAM = "Gemina Advisory <gestionale@mail.geminaadvisory.com>";
const LOGO = "https://img.geminaadvisory.com/logo/Gemina%20logo%20blue%20chiaro.png";
const ACCENT = "#71a1f9";
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const sql = postgres(DB_URL, { prepare: false, max: 2, idle_timeout: 20 });

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

const esc = (t: string) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// ---------------------------------------------------------------------------------------------------------------------------
// The Gemina template (same look as the Zite one, lib/modelloEmail.ts): logo, title, paragraphs, button, footer.
// Everything that comes from a person is escaped; the only link is the button, chosen here.
// ---------------------------------------------------------------------------------------------------------------------------
type Email = { titolo: string; paragrafi: string[]; elenco?: string[]; pulsante: { etichetta: string; url: string }; piede: string };

function html(e: Email): string {
  const p = (t: string) => `<p style="margin:0 0 14px;font-size:15px;line-height:1.55;color:#1f2937">${esc(t)}</p>`;
  const elenco = e.elenco?.length
    ? `<ul style="margin:0 0 14px;padding-left:20px;font-size:15px;line-height:1.55;color:#1f2937">${e.elenco.map((x) => `<li>${esc(x)}</li>`).join("")}</ul>`
    : "";
  return `<!doctype html><html><body style="margin:0;background:#f4f6fa;font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:28px 12px">
<table role="presentation" width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%;background:#ffffff;border-radius:12px">
<tr><td style="padding:24px 28px 8px"><img src="${LOGO}" alt="Gemina Advisory" height="32" style="display:block;border:0;height:32px;width:auto;color:${ACCENT};font-size:20px;letter-spacing:6px"></td></tr>
<tr><td style="padding:8px 28px 24px">
<h1 style="margin:8px 0 14px;font-size:20px;line-height:1.3;color:#111827">${esc(e.titolo)}</h1>
${e.paragrafi.map(p).join("")}${elenco}
<p style="margin:22px 0 4px"><a href="${esc(e.pulsante.url)}" style="display:inline-block;background:${ACCENT};color:#ffffff;text-decoration:none;font-size:15px;font-weight:600;padding:10px 20px;border-radius:8px">${esc(e.pulsante.etichetta)}</a></p>
</td></tr>
<tr><td style="padding:14px 28px 22px;border-top:1px solid #e5e7eb;font-size:12px;color:#9ca3af">${esc(e.piede)}</td></tr>
</table></td></tr></table></body></html>`;
}

function text(e: Email): string {
  return [e.titolo, ...e.paragrafi, e.elenco?.map((x) => `- ${x}`).join("\n"), `${e.pulsante.etichetta}: ${e.pulsante.url}`, `—\n${e.piede}`]
    .filter(Boolean).join("\n\n");
}

async function send(m: { from: string; to: string; replyTo?: string; subject: string; email: Email }): Promise<boolean> {
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { authorization: `Bearer ${RESEND_API_KEY}`, "content-type": "application/json" },
    body: JSON.stringify({
      from: m.from, to: [m.to], subject: m.subject, html: html(m.email), text: text(m.email),
      ...(m.replyTo ? { reply_to: m.replyTo } : {}),
    }),
  });
  if (!res.ok) console.error("resend failed", res.status, (await res.text()).slice(0, 200));
  return res.ok;
}

const oneLine = (t: string, max: number) => {
  const s = t.replace(/\s+/g, " ").trim();
  return s.length > max ? `${s.slice(0, max - 1)}…` : s;
};

function referrerAddressAllowed(email: string | null): email is string {
  if (!email || !EMAIL.test(email) || email.toLowerCase().endsWith("@example.test")) return false;
  return PARTNER_EMAILS_REAL || DEV_TEST_PARTNER_EMAILS.has(email.toLowerCase());
}

// ---------------------------------------------------------------------------------------------------------------------------
// To the referrer
// ---------------------------------------------------------------------------------------------------------------------------
async function referrerEmails(conversationId: string | null): Promise<number> {
  // Claim the conversations due (row lock + update): Gemina wrote something the referrer has not read and was not emailed
  // about, and no email went out for it in the last 10 minutes. The previous value is kept to release the claim on failure.
  const due = await sql`
    with cand as (
      select c.id, c.partner_emailed_at as previous
        from public.conversations c
       where c.kind = 'partner'
         and (${conversationId}::uuid is null or c.id = ${conversationId}::uuid)
         and (c.partner_emailed_at is null or c.partner_emailed_at < now() - interval '10 minutes')
         and exists (
           select 1 from public.messages m
             join public.profiles s on s.id = m.sender_id and s.role in ('staff', 'former_staff')
            where m.conversation_id = c.id and not m.internal and m.deleted_at is null
              and m.created_at > coalesce(c.partner_read_at, '-infinity'::timestamptz)
              and m.created_at > coalesce(c.partner_emailed_at, '-infinity'::timestamptz)
              and m.created_at > now() - interval '2 days')
       for update of c skip locked)
    update public.conversations c set partner_emailed_at = now()
      from cand, public.partners pa
     where c.id = cand.id and pa.id = c.partner_id
    returning c.id, c.title, cand.previous, pa.email, pa.archived`;

  let sent = 0;
  for (const c of due) {
    const ok = !c.archived && referrerAddressAllowed(c.email) && await send({
      from: FROM_REFERRER, to: c.email, replyTo: REPLY_TO_REFERRER,
      subject: `Nuovo messaggio da Gemina Advisory: ${oneLine(c.title, 120)}`,
      email: {
        titolo: "Hai un nuovo messaggio da Gemina Advisory",
        paragrafi: [`Oggetto: ${oneLine(c.title, 200)}`, "Leggilo e rispondi dal portale."],
        pulsante: { etichetta: "Rispondi dal portale", url: `${URL_PORTALE}/#/messaggi` },
        piede: "Messaggio automatico di Gemina Advisory: per rispondere usa il portale.",
      },
    });
    if (ok) sent++;
    else if (!c.archived && referrerAddressAllowed(c.email)) {
      // Resend failed: release the claim so the next sweep tries again. (A placeholder or archived referrer stays claimed:
      // there is nobody to email.)
      await sql`update public.conversations set partner_emailed_at = ${c.previous} where id = ${c.id}`;
    }
  }
  return sent;
}

// ---------------------------------------------------------------------------------------------------------------------------
// To the team: message notifications unread by anyone at Gemina after 15 minutes (the last 2 days only)
// ---------------------------------------------------------------------------------------------------------------------------
async function teamEmails(): Promise<number> {
  const messages = await sql`
    with cand as (
      select n.id
        from public.notifications n
        join public.conversations c on c.id = n.conversation_id
        join public.profiles r on r.id = n.recipient_id and r.role = 'staff'
       where n.kind = 'message' and n.read_at is null and n.emailed_at is null
         and n.created_at < now() - interval '15 minutes'
         and n.created_at > now() - interval '2 days'
         and c.kind = 'partner'
         and n.created_at > coalesce(c.staff_read_at, '-infinity'::timestamptz)
       for update of n skip locked)
    update public.notifications n set emailed_at = now()
      from cand, public.conversations c, public.partners pa, public.profiles r
     where n.id = cand.id and c.id = n.conversation_id and pa.id = c.partner_id and r.id = n.recipient_id
    returning n.id, r.email, r.name_first, c.title, pa.name as partner`;
  // Files a referrer shared outside a message (step 7), same rules; a hidden document is not announced.
  const documents = await sql`
    with cand as (
      select n.id
        from public.notifications n
        join public.documents d on d.id = n.document_id
        join public.profiles r on r.id = n.recipient_id and r.role = 'staff'
       where n.kind = 'document' and n.read_at is null and n.emailed_at is null
         and n.created_at < now() - interval '15 minutes'
         and n.created_at > now() - interval '2 days'
         and d.kind = 'partner' and d.deleted_at is null and not d.from_gemina
       for update of n skip locked)
    update public.notifications n set emailed_at = now()
      from cand, public.documents d, public.partners pa, public.profiles r
     where n.id = cand.id and d.id = n.document_id and pa.id = d.partner_id and r.id = n.recipient_id
    returning n.id, r.email, r.name_first, d.title, pa.name as partner`;

  const perPerson = new Map<string, { nome: string | null; ids: string[]; righe: Set<string> }>();
  const add = (d: { id: string; email: string | null; name_first: string | null; title: string; partner: string | null }, prefix: string) => {
    if (!d.email || !EMAIL.test(d.email)) return;
    const p = perPerson.get(d.email) ?? { nome: d.name_first, ids: [], righe: new Set<string>() };
    p.ids.push(d.id);
    p.righe.add(`${oneLine(d.partner ?? "Segnalatore", 60)}: ${prefix}${oneLine(d.title, 120)}`);
    perPerson.set(d.email, p);
  };
  for (const d of messages) add(d as never, "");
  for (const d of documents) add(d as never, "documento ");

  let sent = 0;
  for (const [email, p] of perPerson) {
    const n = p.righe.size;
    const ok = await send({
      from: FROM_TEAM, to: email,
      subject: n === 1 ? "Una novità da un segnalatore aspetta una risposta" : `${n} novità dai segnalatori aspettano una risposta`,
      email: {
        titolo: n === 1 ? "Una novità non ancora letta" : `${n} novità non ancora lette`,
        paragrafi: [`${p.nome ? `Ciao ${p.nome}, ` : ""}da più di 15 minuti nessuno di Gemina ha letto:`],
        elenco: [...p.righe],
        pulsante: { etichetta: "Apri il Gestionale", url: URL_GESTIONALE },
        piede: "Messaggio automatico: non rispondere a questa email. Rispondi dentro l’app Gemina.",
      },
    });
    if (ok) sent++;
    else await sql`update public.notifications set emailed_at = null where id = any(${p.ids}::uuid[])`;
  }
  return sent;
}

// ---------------------------------------------------------------------------------------------------------------------------
// "Notifica segnalatore": one Gemina document announced to its referrer (the database has checked staff and document)
// ---------------------------------------------------------------------------------------------------------------------------
async function documentEmail(documentId: string): Promise<number> {
  const [d] = await sql`
    select d.title, pa.email, pa.archived
      from public.documents d join public.partners pa on pa.id = d.partner_id
     where d.id = ${documentId}::uuid and d.kind = 'partner' and d.from_gemina and d.shared
       and d.deleted_at is null and d.uploaded_at is not null and d.message_id is null
       and d.notified_at > now() - interval '5 minutes'`;
  if (!d || d.archived || !referrerAddressAllowed(d.email)) return 0;
  const ok = await send({
    from: FROM_REFERRER, to: d.email, replyTo: REPLY_TO_REFERRER,
    subject: `Nuovo documento da Gemina Advisory: ${oneLine(d.title, 120)}`,
    email: {
      titolo: "Gemina Advisory ha condiviso un documento con te",
      paragrafi: [`Documento: ${oneLine(d.title, 200)}`, "Lo trovi nel portale, in Messaggi e documenti."],
      pulsante: { etichetta: "Apri il portale", url: `${URL_PORTALE}/#/messaggi` },
      piede: "Messaggio automatico di Gemina Advisory: per rispondere usa il portale.",
    },
  });
  return ok ? 1 : 0;
}

// ---------------------------------------------------------------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { ok: false, error: "method_not_allowed" });
  if (!RESEND_API_KEY) return reply(500, { ok: false, error: "resend_not_configured" });
  const [s] = await sql`select decrypted_secret from vault.decrypted_secrets where name = 'message_emails_secret'`;
  if (!s?.decrypted_secret || !safeEqual(req.headers.get("x-email-secret") ?? "", s.decrypted_secret)) {
    return reply(401, { ok: false, error: "unauthorized" });
  }
  let body: { mode?: string; conversation_id?: string | null; document_id?: string | null };
  try { body = await req.json(); } catch { return reply(400, { ok: false, error: "invalid_json" }); }

  try {
    if (body.mode === "message") {
      if (typeof body.conversation_id !== "string") return reply(400, { ok: false, error: "conversation_id_required" });
      return reply(200, { ok: true, referrer: await referrerEmails(body.conversation_id) });
    }
    if (body.mode === "document") {
      if (typeof body.document_id !== "string") return reply(400, { ok: false, error: "document_id_required" });
      return reply(200, { ok: true, referrer: await documentEmail(body.document_id) });
    }
    if (body.mode === "sweep") {
      const [referrer, team] = [await referrerEmails(null), await teamEmails()];
      return reply(200, { ok: true, referrer, team });
    }
    return reply(400, { ok: false, error: "unknown_mode" });
  } catch (e) {
    console.error("message-emails error", (e as { code?: string })?.code ?? "", (e as { message?: string })?.message ?? "");
    return reply(500, { ok: false, error: "internal_error" });
  }
});
