// portale-fatture (v2, 2026-11-10)
// v2 (revisione di sicurezza provvisoria, migrazione portal_uploads_hardening): 100 MB per file; alla conferma si leggono i primi byte e un file il cui
// contenuto non corrisponde all'estensione diventa 'rejected' e si toglie dal bucket; 20 codici sbagliati in 15 minuti dallo stesso indirizzo = 429
// (si salva solo l'impronta HMAC dell'IP); CORS solo verso gli indirizzi nel segreto PORTALE_FATTURE_ORIGINS (separati da virgola; vuoto = nessuna pagina).
// Portale di caricamento fatture: il cliente carica da una pagina pubblica, i file vanno nel bucket privato "portal-uploads",
// il Gestionale li scarica e li mette su Drive.
//
// Due tipi di chiamata, nessuna con JWT (verify_jwt = false: l'autenticazione la fa questa funzione):
//
// A) PUBBLICHE, dal browser del cliente. Si autenticano con il codice del link (campo "token"; nel database c'è solo il suo sha256).
//    info     { token }                              -> { cliente, pratiche: [{id, code, title}] }  (solo pratiche aperte del cliente)
//    prepara  { token, pratica_id, files: [{name, size}] } -> { files: [{id, name, upload_url}] }   (URL firmati di caricamento, max 100 file)
//    conferma { token, file_ids }                    -> { confermati, mancanti }   (controlla che il file sia davvero nel bucket)
//
// B) DEL GESTIONALE, da server a server. Header "x-bridge-secret" = BRIDGE_SECRET_STAFF (lo stesso di fatture-import).
//    da_trasferire { pratica_id?, limit? }           -> { totale, files: [{id, pratica_id, file_name, size_bytes, download_url}] }
//    trasferito    { file_id, drive_file_id }        -> segna il file come copiato su Drive e lo toglie dal bucket
//    fallito       { file_id, error }                -> annota l'errore (il file resta da trasferire)
//    crea_link     { zite_user_id, company_id, label?, days? }  -> { portal_id, token, expires_at }  (come il collega: public.create_upload_portal)
//    revoca_link   { zite_user_id, portal_id }       -> public.revoke_upload_portal

import postgres from "npm:postgres@3.4.5";
import { createClient } from "npm:@supabase/supabase-js@2.50.0";

const SECRET_STAFF = Deno.env.get("BRIDGE_SECRET_STAFF") ?? "";
const DB_URL = Deno.env.get("SUPABASE_DB_URL")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SECRET_KEY = (() => {
  try { return JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}")["default"]; } catch { return undefined; }
})() ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const BUCKET = "portal-uploads";
const MAX_FILES_PER_CALL = 100;
const MAX_FILES_PER_DAY = 3000;
const MAX_FILE_BYTES = 100 * 1024 * 1024; // lo stesso limite del bucket
const MAX_FALLITI = 20;          // codici sbagliati per indirizzo...
const FINESTRA_MIN = 15;         // ...in questi minuti
const ORIGINS = new Set((Deno.env.get("PORTALE_FATTURE_ORIGINS") ?? "").split(",").map((x) => x.trim().replace(/\/+$/, "")).filter(Boolean));
const MAX_BODY = 200_000;
const EXTENSIONS = ["xml", "p7m", "pdf", "zip", "xls", "xlsx", "csv"];

const sql = postgres(DB_URL, { prepare: false, max: 2, idle_timeout: 20 });
const admin = createClient(SUPABASE_URL, SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

class PortalError extends Error {
  constructor(public status: number, public code: string) { super(code); }
}

/** CORS solo per le pagine autorizzate: un'altra pagina non può chiamare il portale dal browser del cliente. */
function cors(origin: string | null): Record<string, string> {
  if (!origin || !ORIGINS.has(origin)) return { vary: "origin" };
  return {
    "access-control-allow-origin": origin,
    "access-control-allow-methods": "POST, OPTIONS",
    "access-control-allow-headers": "content-type",
    "access-control-max-age": "86400",
    vary: "origin",
  };
}

function replyTo(status: number, body: unknown, origin: string | null = null) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store", ...cors(origin) } });
}

type Ctx = { ipHash: string };

/** Impronta dell'indirizzo del chiamante (HMAC con il segreto di staff): serve solo a contare i tentativi, l'IP in chiaro non si salva. */
async function impronta(req: Request): Promise<string> {
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || req.headers.get("cf-connecting-ip") || "sconosciuto";
  const chiave = await crypto.subtle.importKey("raw", new TextEncoder().encode(SECRET_STAFF || "portale-fatture"), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", chiave, new TextEncoder().encode(ip)));
  return [...mac].map((x) => x.toString(16).padStart(2, "0")).join("");
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
const TOKEN = /^[0-9a-f]{64}$/;

const oneUuid = (v: unknown, name: string): string => {
  if (typeof v !== "string" || !UUID.test(v)) throw new PortalError(400, `invalid_${name}`);
  return v;
};
const uuids = (v: unknown, name: string, max: number): string[] => {
  if (!Array.isArray(v) || v.length === 0 || v.length > max || v.some((x) => typeof x !== "string" || !UUID.test(x))) throw new PortalError(400, `invalid_${name}`);
  return v as string[];
};

async function sha256Hex(text: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(d)].map((x) => x.toString(16).padStart(2, "0")).join("");
}

/** Il link del cliente: valido se esiste, non è revocato né scaduto. Ogni errore è lo stesso, per non dire nulla a chi prova a indovinare. */
async function linkValido(token: unknown, ctx: Ctx) {
  const [{ n }] = await sql`select count(*)::int as n from private.portal_link_failures
                             where ip_hash = ${ctx.ipHash} and at > now() - make_interval(mins => ${FINESTRA_MIN})`;
  if (n >= MAX_FALLITI) throw new PortalError(429, "troppi_tentativi");
  const hash = typeof token === "string" && TOKEN.test(token) ? await sha256Hex(token) : null;
  const [p] = hash ? await sql`
    select pt.id, pt.organization_id, pt.company_id, c.name as company_name
      from public.upload_portals pt join public.companies c on c.id = pt.company_id
     where pt.token_hash = ${hash} and pt.revoked_at is null and pt.expires_at > now()` : [];
  if (!p) {
    await sql`insert into private.portal_link_failures (ip_hash) values (${ctx.ipHash})`;
    await sql`delete from private.portal_link_failures where at < now() - interval '1 day'`;
    throw new PortalError(401, "link_non_valido");
  }
  await sql`update public.upload_portals set last_used_at = now() where id = ${p.id}`;
  return p as { id: string; organization_id: string; company_id: string; company_name: string };
}

/** Nome sicuro per il bucket (l'originale resta nel database e viene usato su Drive). */
function nomeSicuro(name: string): string {
  const s = name.normalize("NFKD").replace(/[^A-Za-z0-9._-]+/g, "_").replace(/^\.+/, "").slice(-120);
  return s || "file";
}

function estensione(name: string): string | null {
  const m = /\.([A-Za-z0-9]{1,5})$/.exec(name.trim());
  return m && EXTENSIONS.includes(m[1].toLowerCase()) ? m[1].toLowerCase() : null;
}
const estensioneOk = (name: string) => estensione(name) !== null;

/** Il contenuto corrisponde all'estensione? Si guardano i primi byte (il tipo dichiarato dal browser non conta). */
export function contenutoOk(ext: string, b: Uint8Array): boolean {
  const inizia = (...firma: number[]) => firma.every((x, i) => b[i] === x);
  const testo = new TextDecoder("utf-8", { fatal: false }).decode(b).replace(/^\uFEFF/, "");
  const senzaNul = !b.includes(0);
  switch (ext) {
    case "pdf": return testo.slice(0, 1024).includes("%PDF-");
    case "zip": case "xlsx": return inizia(0x50, 0x4b, 0x03, 0x04) || inizia(0x50, 0x4b, 0x05, 0x06);
    case "xls": return inizia(0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1);
    case "xml": return senzaNul && /^\s*</.test(testo);
    case "p7m": return (b[0] === 0x30 && [0x80, 0x81, 0x82, 0x83, 0x84].includes(b[1])) || /^\s*(MI|-----BEGIN)/.test(testo);
    case "csv": return senzaNul && b.length > 0;
    default: return false;
  }
}

async function primiByte(path: string): Promise<Uint8Array | null> {
  const { data, error } = await admin.storage.from(BUCKET).createSignedUrl(path, 60);
  if (error || !data?.signedUrl) return null;
  const r = await fetch(data.signedUrl, { headers: { range: "bytes=0-1023" } });
  if (!r.ok && r.status !== 206) { await r.body?.cancel(); return null; }
  return new Uint8Array(await r.arrayBuffer()).slice(0, 1024);
}

// ---------- A) pubbliche
async function info(p: Record<string, unknown>, ctx: Ctx) {
  const portale = await linkValido(p.token, ctx);
  const pratiche = await sql`
    select id, code, title from public.pratiche
     where company_id = ${portale.company_id} and removed_at is null and is_open
     order by created_at desc limit 200`;
  return { cliente: portale.company_name, estensioni: EXTENSIONS, max_bytes: MAX_FILE_BYTES, pratiche };
}

async function prepara(p: Record<string, unknown>, ctx: Ctx) {
  const portale = await linkValido(p.token, ctx);
  const pratica = oneUuid(p.pratica_id, "pratica_id");
  if (!Array.isArray(p.files) || p.files.length === 0 || p.files.length > MAX_FILES_PER_CALL) throw new PortalError(400, "invalid_files");
  const [prat] = await sql`select id from public.pratiche where id = ${pratica} and company_id = ${portale.company_id} and removed_at is null and is_open`;
  if (!prat) throw new PortalError(404, "pratica_non_trovata");
  const [{ n }] = await sql`select count(*)::int as n from public.upload_portal_files where portal_id = ${portale.id} and created_at > now() - interval '1 day'`;
  if (n + p.files.length > MAX_FILES_PER_DAY) throw new PortalError(429, "troppi_file");

  const out: { id: string; name: string; upload_url?: string; error?: string }[] = [];
  for (const raw of p.files) {
    const f = (raw ?? {}) as Record<string, unknown>;
    const name = typeof f.name === "string" ? f.name.trim() : "";
    const size = typeof f.size === "number" && Number.isFinite(f.size) ? Math.floor(f.size) : -1;
    if (!name || name.length > 255) { out.push({ id: "", name, error: "nome_non_valido" }); continue; }
    if (!estensioneOk(name)) { out.push({ id: "", name, error: "tipo_non_ammesso" }); continue; }
    if (size < 0 || size > MAX_FILE_BYTES) { out.push({ id: "", name, error: "file_troppo_grande" }); continue; }
    const id = crypto.randomUUID();
    const path = `${portale.organization_id}/${portale.id}/${id}/${nomeSicuro(name)}`;
    const { data, error } = await admin.storage.from(BUCKET).createSignedUploadUrl(path);
    if (error || !data?.signedUrl) {
      console.error("portale-fatture signed upload", error?.message ?? "");
      out.push({ id: "", name, error: "errore_interno" });
      continue;
    }
    await sql`insert into public.upload_portal_files (id, organization_id, portal_id, company_id, pratica_id, file_name, storage_path, size_bytes)
              values (${id}, ${portale.organization_id}, ${portale.id}, ${portale.company_id}, ${pratica}, ${name}, ${path}, ${size})`;
    out.push({ id, name, upload_url: data.signedUrl });
  }
  return { files: out };
}

async function conferma(p: Record<string, unknown>, ctx: Ctx) {
  const portale = await linkValido(p.token, ctx);
  const ids = uuids(p.file_ids, "file_ids", MAX_FILES_PER_CALL);
  const righe = await sql`select id, storage_path, file_name from public.upload_portal_files where portal_id = ${portale.id} and id = any(${ids}::uuid[]) and status = 'pending'`;
  const confermati: string[] = [];
  const mancanti: string[] = [];
  const rifiutati: string[] = [];
  for (const r of righe) {
    const dir = r.storage_path.slice(0, r.storage_path.lastIndexOf("/"));
    const nome = r.storage_path.slice(r.storage_path.lastIndexOf("/") + 1);
    const { data } = await admin.storage.from(BUCKET).list(dir, { limit: 5, search: nome });
    const obj = data?.find((o) => o.name === nome);
    if (!obj) { mancanti.push(r.id); continue; }
    const size = Number((obj.metadata as Record<string, unknown> | null)?.size ?? 0);
    const ext = estensione(r.file_name);
    const testa = ext ? await primiByte(r.storage_path) : null;
    if (!ext || !testa || size > MAX_FILE_BYTES || !contenutoOk(ext, testa)) {
      // contenuto diverso da quello che il nome dice (o illeggibile): non si tiene e non arriva mai su Drive
      const { error } = await admin.storage.from(BUCKET).remove([r.storage_path]);
      if (error) console.error("portale-fatture remove", error.message);
      await sql`update public.upload_portal_files set status = 'rejected', size_bytes = ${size}, error = 'contenuto_non_valido' where id = ${r.id} and status = 'pending'`;
      rifiutati.push(r.id);
      continue;
    }
    await sql`update public.upload_portal_files set status = 'uploaded', uploaded_at = now(), size_bytes = ${size} where id = ${r.id} and status = 'pending'`;
    confermati.push(r.id);
  }
  return { confermati, mancanti, rifiutati };
}

// ---------- B) del Gestionale
async function daTrasferire(p: Record<string, unknown>) {
  const pratica = p.pratica_id == null ? null : oneUuid(p.pratica_id, "pratica_id");
  const limit = Number.isSafeInteger(p.limit) ? Math.min(Math.max(Number(p.limit), 1), 25) : 10;
  const [{ n }] = await sql`select count(*)::int as n from public.upload_portal_files where status = 'uploaded' and (${pratica}::uuid is null or pratica_id = ${pratica}::uuid)`;
  const righe = await sql`select id, pratica_id, company_id, file_name, size_bytes, storage_path from public.upload_portal_files
                           where status = 'uploaded' and (${pratica}::uuid is null or pratica_id = ${pratica}::uuid)
                           order by uploaded_at limit ${limit}`;
  const files = [];
  for (const r of righe) {
    const { data, error } = await admin.storage.from(BUCKET).createSignedUrl(r.storage_path, 3600, { download: r.file_name });
    if (error || !data?.signedUrl) { console.error("portale-fatture signed url", error?.message ?? ""); continue; }
    files.push({ id: r.id, pratica_id: r.pratica_id, company_id: r.company_id, file_name: r.file_name, size_bytes: r.size_bytes, download_url: data.signedUrl });
  }
  return { totale: n, files };
}

async function trasferito(p: Record<string, unknown>) {
  const id = oneUuid(p.file_id, "file_id");
  if (typeof p.drive_file_id !== "string" || !p.drive_file_id || p.drive_file_id.length > 200) throw new PortalError(400, "invalid_drive_file_id");
  const [r] = await sql`update public.upload_portal_files set status = 'transferred', transferred_at = now(), drive_file_id = ${p.drive_file_id}, error = null
                         where id = ${id} and status = 'uploaded' returning storage_path`;
  if (!r) throw new PortalError(404, "file_non_trovato");
  const { error } = await admin.storage.from(BUCKET).remove([r.storage_path]);
  if (error) console.error("portale-fatture remove", error.message);
  return { ok: true };
}

async function fallito(p: Record<string, unknown>) {
  const id = oneUuid(p.file_id, "file_id");
  const msg = typeof p.error === "string" ? p.error.slice(0, 1000) : "errore";
  const [r] = await sql`update public.upload_portal_files set error = ${msg} where id = ${id} and status = 'uploaded' returning id`;
  if (!r) throw new PortalError(404, "file_non_trovato");
  return { ok: true };
}

async function comeCollega<T>(p: Record<string, unknown>, fn: (tx: postgres.TransactionSql) => Promise<T>): Promise<T> {
  if (typeof p.zite_user_id !== "string" || !p.zite_user_id || p.zite_user_id.length > 100) throw new PortalError(400, "invalid_zite_user_id");
  const [me] = await sql`select id from public.profiles where zite_user_id = ${p.zite_user_id} and role = 'staff'`;
  if (!me) throw new PortalError(403, "staff_unknown");
  return await sql.begin(async (tx) => {
    await tx`select set_config('request.jwt.claims', ${JSON.stringify({ sub: me.id, role: "authenticated" })}, true)`;
    await tx.unsafe("set local role authenticated");
    return await fn(tx);
  }) as T;
}

async function creaLink(p: Record<string, unknown>) {
  const company = oneUuid(p.company_id, "company_id");
  const label = typeof p.label === "string" ? p.label.slice(0, 200) : null;
  const days = Number.isSafeInteger(p.days) ? Number(p.days) : 90;
  return await comeCollega(p, async (tx) => {
    const [r] = await tx`select public.create_upload_portal(${company}::uuid, ${label}::text, ${days}::int) as data`;
    return r.data;
  });
}

async function revocaLink(p: Record<string, unknown>) {
  const portal = oneUuid(p.portal_id, "portal_id");
  return await comeCollega(p, async (tx) => {
    await tx`select public.revoke_upload_portal(${portal}::uuid)`;
    return { ok: true };
  });
}

const PUBBLICHE: Record<string, (p: Record<string, unknown>, ctx: Ctx) => Promise<unknown>> = { info, prepara, conferma };
const GESTIONALE: Record<string, (p: Record<string, unknown>) => Promise<unknown>> = {
  da_trasferire: daTrasferire, trasferito, fallito, crea_link: creaLink, revoca_link: revocaLink,
};

Deno.serve(async (req) => {
  const origin = req.headers.get("origin");
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(origin) });
  const reply = (status: number, body: unknown) => replyTo(status, body, origin);
  if (req.method !== "POST") return reply(405, { ok: false, error: "method_not_allowed" });

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
    if (Object.hasOwn(PUBBLICHE, action)) return reply(200, { ok: true, data: await PUBBLICHE[action](payload, { ipHash: await impronta(req) }) });
    if (Object.hasOwn(GESTIONALE, action)) {
      if (!SECRET_STAFF) return reply(500, { ok: false, error: "not_configured" });
      if (!safeEqual(req.headers.get("x-bridge-secret") ?? "", SECRET_STAFF)) return reply(401, { ok: false, error: "unauthorized" });
      return reply(200, { ok: true, data: await GESTIONALE[action](payload) });
    }
    throw new PortalError(400, "unknown_action");
  } catch (e) {
    if (e instanceof PortalError) return reply(e.status, { ok: false, error: e.code });
    const code = (e as { code?: string })?.code ?? "";
    console.error("portale-fatture error", code, (e as { message?: string })?.message ?? "");
    if (code === "22023" || code === "P0001") return reply(400, { ok: false, error: (e as { message?: string })?.message ?? "invalid", message: true });
    if (code === "42501") return reply(403, { ok: false, error: "not_allowed" });
    return reply(500, { ok: false, error: "internal_error" });
  }
});
