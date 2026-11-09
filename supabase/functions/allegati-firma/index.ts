// allegati-firma (v1, 2026-11-09, piano pagine passo 8; migration signature_attachments)
// The «Allegati per la firma» of a pratica's scadenza. Called by the Gestionale's server (Zite endpoint allegatiFirma), never by a browser.
// Same trust model and secret as fatture-import: header "x-bridge-secret" = BRIDGE_SECRET_STAFF. Kept apart from portal-bridge.
// Every action acts AS the colleague logged in to Zite (zite_user_id from context.user, never from the browser): role authenticated with that staff
// profile, so the RLS and the triggers of the migration apply (who created, sent, marked; the history). A Zite user without a current staff profile is
// refused with "staff_unknown" (the Gestionale creates it through the bridge and calls again).
//
// Actions:
//   elenco  { zite_user_id, pratica_id, scadenza_id }                     -> { drive_folder, allegati: signature_attachments_v rows, files: [{attachment_id, drive_file_id, file_name}] }
//   prepara { zite_user_id, pratica_id, scadenza_id, voci: [{zite_dato_id, name, signatures_required, signers}] }  (max 100)
//           one row per voce (insert, or update name and signatures while nothing is sent or signed: the database keeps them frozen after) -> elenco
//   cartella { zite_user_id, pratica_id, scadenza_id, drive_folder | null } -> elenco
//   file    { zite_user_id, attachment_id, kind, file_name, drive_file_id, signatures, sha256, size_bytes, base64? }
//           the copy goes to the private bucket "signature-files" at <organization>/<attachment>/<sha256>.<ext> (service role; checked: the sha256 is the
//           bytes'), then the version row is written as the colleague. Without base64 (file too large to pass) the version is written with no copy.
//           -> { result: 'nuova' | 'gia_presente', copy: boolean }
//   segna   { zite_user_id, attachment_ids, firmato }                     «Segna come firmati» (true) or back (false) -> { n }

import postgres from "npm:postgres@3.4.5";
import { createClient } from "npm:@supabase/supabase-js@2.50.0";

const SECRET_STAFF = Deno.env.get("BRIDGE_SECRET_STAFF") ?? "";
const DB_URL = Deno.env.get("SUPABASE_DB_URL")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SECRET_KEY = (() => {
  try { return JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}")["default"]; } catch { return undefined; }
})() ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const BUCKET = "signature-files";
const MAX_BODY = 36_000_000;           // a 25 MB file in base64 and the rest
const MAX_FILE = 26_214_400;           // 25 MB, as the Gestionale's Drive limit
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SHA = /^[0-9a-f]{64}$/;
const DRIVE_ID = /^[A-Za-z0-9_-]{10,200}$/;
const MIME: Record<string, string> = {
  pdf: "application/pdf", p7m: "application/pkcs7-mime",
  docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
};

const sql = postgres(DB_URL, { prepare: false, max: 2, idle_timeout: 20 });
const admin = createClient(SUPABASE_URL, SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

class AllegatiError extends Error {
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
  if (typeof v !== "string" || !UUID.test(v)) throw new AllegatiError(400, `invalid_${name}`);
  return v;
};
const uuids = (v: unknown, name: string, max: number): string[] => {
  if (!Array.isArray(v) || v.length === 0 || v.length > max || v.some((x) => typeof x !== "string" || !UUID.test(x))) throw new AllegatiError(400, `invalid_${name}`);
  return v as string[];
};
const text = (v: unknown, name: string, max: number): string => {
  if (typeof v !== "string" || !v.trim() || v.length > max) throw new AllegatiError(400, `invalid_${name}`);
  return v.trim();
};

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

/** The extension kept in the bucket: «pdf», «pdf.p7m», «pdf.p7m.p7m»…; anything odd becomes «bin». */
function estensione(nome: string): string {
  const m = /((?:\.[A-Za-z0-9]{1,5})(?:\.p7m)*)$/i.exec(nome.trim());
  const e = (m?.[1] ?? "").replace(/^\./, "").toLowerCase();
  return e && e.length <= 40 ? e : "bin";
}

async function comeCollega<T>(p: Record<string, unknown>, fn: (tx: postgres.TransactionSql) => Promise<T>): Promise<T> {
  if (typeof p.zite_user_id !== "string" || !p.zite_user_id || p.zite_user_id.length > 100) throw new AllegatiError(400, "invalid_zite_user_id");
  const [me] = await sql`select id from public.profiles where zite_user_id = ${p.zite_user_id} and role = 'staff'`;
  if (!me) throw new AllegatiError(403, "staff_unknown");
  return await sql.begin(async (tx) => {
    await tx`select set_config('request.jwt.claims', ${JSON.stringify({ sub: me.id, role: "authenticated" })}, true)`;
    await tx.unsafe("set local role authenticated");
    return await fn(tx);
  }) as T;
}

async function leggiElenco(tx: postgres.TransactionSql, pratica: string, scadenza: string) {
  const [s] = await tx`select id, drive_folder from public.scadenze where id = ${scadenza} and pratica_id = ${pratica}`;
  if (!s) throw new AllegatiError(404, "scadenza_not_found");
  const allegati = await tx`select * from public.signature_attachments_v where scadenza_id = ${scadenza} order by name`;
  const files = await tx`select f.attachment_id, f.drive_file_id, f.file_name from public.signature_attachment_files f
                          join public.signature_attachments a on a.id = f.attachment_id where a.scadenza_id = ${scadenza}`;
  return { drive_folder: s.drive_folder, allegati, files };
}

async function elenco(p: Record<string, unknown>) {
  const pratica = oneUuid(p.pratica_id, "pratica_id"), scadenza = oneUuid(p.scadenza_id, "scadenza_id");
  return await comeCollega(p, (tx) => leggiElenco(tx, pratica, scadenza));
}

async function prepara(p: Record<string, unknown>) {
  const pratica = oneUuid(p.pratica_id, "pratica_id"), scadenza = oneUuid(p.scadenza_id, "scadenza_id");
  if (!Array.isArray(p.voci) || p.voci.length > 100) throw new AllegatiError(400, "invalid_voci");
  const voci = p.voci.map((raw) => {
    const v = (raw ?? {}) as Record<string, unknown>;
    const firme = Number(v.signatures_required);
    const signers = Array.isArray(v.signers) ? v.signers.filter((x): x is string => x === "cliente" || x === "gemina") : [];
    if (!Number.isInteger(firme) || firme < 1 || firme > 5 || signers.length === 0) throw new AllegatiError(400, "invalid_voce");
    return { zite_dato_id: text(v.zite_dato_id, "zite_dato_id", 64), name: text(v.name, "name", 200), signatures_required: firme, signers: [...new Set(signers)].slice(0, firme) };
  });
  return await comeCollega(p, async (tx) => {
    for (const v of voci) {
      await tx`insert into public.signature_attachments (pratica_id, scadenza_id, zite_dato_id, name, signatures_required, signers)
               values (${pratica}, ${scadenza}, ${v.zite_dato_id}, ${v.name}, ${v.signatures_required}, ${v.signers}::text[])
               on conflict (scadenza_id, zite_dato_id) do update
                 set name = excluded.name, signatures_required = excluded.signatures_required, signers = excluded.signers
                 where (public.signature_attachments.name, public.signature_attachments.signatures_required, public.signature_attachments.signers)
                       is distinct from (excluded.name, excluded.signatures_required, excluded.signers)`;
    }
    return await leggiElenco(tx, pratica, scadenza);
  });
}

async function cartella(p: Record<string, unknown>) {
  const pratica = oneUuid(p.pratica_id, "pratica_id"), scadenza = oneUuid(p.scadenza_id, "scadenza_id");
  const link = p.drive_folder == null ? null : text(p.drive_folder, "drive_folder", 300);
  return await comeCollega(p, async (tx) => {
    const r = await tx`update public.scadenze set drive_folder = ${link} where id = ${scadenza} and pratica_id = ${pratica} returning id`;
    if (!r.length) throw new AllegatiError(404, "scadenza_not_found");
    return await leggiElenco(tx, pratica, scadenza);
  });
}

async function file(p: Record<string, unknown>) {
  const attachment = oneUuid(p.attachment_id, "attachment_id");
  const kind = p.kind === "signed" ? "signed" : p.kind === "original" ? "original" : null;
  if (!kind) throw new AllegatiError(400, "invalid_kind");
  const nome = text(p.file_name, "file_name", 255);
  const drive = text(p.drive_file_id, "drive_file_id", 200);
  if (!DRIVE_ID.test(drive)) throw new AllegatiError(400, "invalid_drive_file_id");
  const firme = Number(p.signatures);
  if (!Number.isInteger(firme) || firme < 0 || firme > 5 || (kind === "original") !== (firme === 0)) throw new AllegatiError(400, "invalid_signatures");
  if (typeof p.sha256 !== "string" || !SHA.test(p.sha256)) throw new AllegatiError(400, "invalid_sha256");
  const size = Number(p.size_bytes);
  if (!Number.isSafeInteger(size) || size < 0 || size > 52_428_800) throw new AllegatiError(400, "invalid_size_bytes");

  return await comeCollega(p, async (tx) => {
    // the colleague must see the document (staff), and it must take files (not archived)
    const [a] = await tx`select id, organization_id, archived from public.signature_attachments where id = ${attachment}`;
    if (!a) throw new AllegatiError(404, "attachment_not_found");
    if (a.archived) throw new AllegatiError(400, "attachment_archived");
    const [gia] = await tx`select id from public.signature_attachment_files where attachment_id = ${attachment} and sha256 = ${p.sha256 as string}`;
    if (gia) return { result: "gia_presente", copy: false };

    let path: string | null = null;
    if (typeof p.base64 === "string" && p.base64) {
      const bytes = base64ToBytes(p.base64);
      if (bytes.length > MAX_FILE) throw new AllegatiError(413, "file_too_large");
      if ((await sha256Hex(bytes)) !== p.sha256) throw new AllegatiError(400, "sha_mismatch");
      const ext = estensione(nome);
      const candidate = `${a.organization_id}/${attachment}/${p.sha256}.${ext}`;
      const { error } = await admin.storage.from(BUCKET).upload(candidate, bytes, {
        contentType: MIME[ext.split(".").pop() ?? ""] ?? "application/octet-stream", upsert: false,
      });
      // the same bytes stored before (an earlier attempt that stopped half way): the copy is there, keep it
      if (!error || /exist|duplicate/i.test(error.message)) path = candidate;
      else console.error("allegati-firma storage", error.message);
    }
    await tx`insert into public.signature_attachment_files (attachment_id, kind, file_name, drive_file_id, signatures, sha256, size_bytes, storage_path)
             values (${attachment}, ${kind}, ${nome}, ${drive}, ${firme}, ${p.sha256 as string}, ${size}, ${path})`;
    return { result: "nuova", copy: path !== null };
  });
}

async function segna(p: Record<string, unknown>) {
  const ids = uuids(p.attachment_ids, "attachment_ids", 200);
  if (typeof p.firmato !== "boolean") throw new AllegatiError(400, "invalid_firmato");
  return await comeCollega(p, async (tx) => {
    const r = p.firmato
      ? await tx`update public.signature_attachments set marked_signed_at = now() where id = any(${ids}::uuid[]) and marked_signed_at is null and not archived returning id`
      : await tx`update public.signature_attachments set marked_signed_at = null where id = any(${ids}::uuid[]) and marked_signed_at is not null returning id`;
    return { n: r.length };
  });
}

const AZIONI: Record<string, (p: Record<string, unknown>) => Promise<unknown>> = { elenco, prepara, cartella, file, segna };

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
    if (!Object.hasOwn(AZIONI, action)) throw new AllegatiError(400, "unknown_action");
    return reply(200, { ok: true, data: await AZIONI[action](payload) });
  } catch (e) {
    if (e instanceof AllegatiError) return reply(e.status, { ok: false, error: e.code });
    const code = (e as { code?: string })?.code ?? "";
    console.error("allegati-firma error", code, (e as { message?: string })?.message ?? "");
    // the database's own sentences (wrong scadenza, archived document…) are written for the operator
    if (code === "22023" || code === "23503" || code === "P0001") return reply(400, { ok: false, error: (e as { message?: string })?.message ?? "invalid", message: true });
    if (code === "23514") return reply(400, { ok: false, error: "invalid_value" });
    if (code === "42501") return reply(403, { ok: false, error: "not_allowed" });
    return reply(500, { ok: false, error: "internal_error" });
  }
});
