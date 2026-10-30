// qonto-sync (v1, PRDDISC-4, 2026-10-23; v2 2026-10-30, PRDDISC-34: the run answers with the unmatched count the database stored after linking by VAT number)
// Fetches the invoices and credit notes of the Qonto third-party API and upserts them into public.qonto_documents,
// logging every run in public.qonto_sync_runs. Read-only toward Qonto (GET only). Zite keeps its own sync unchanged.
//
// Called only by the database schedule (PRDDISC-5) or by hand with the internal secret the database keeps in Vault
// ('qonto_sync_secret', header x-sync-secret); verify_jwt is off because the function checks that secret itself.
//
// Rules (Giacomo, PRDDISC-1, 23 Oct):
// - Money is integer cents as Qonto gives it (total_amount_cents, vat_amount_cents); net = total - VAT (a generated column).
//   Credit notes are stored negative. No setup-fee exclusion and no DSO here.
// - Status as Zite statoDaQonto: paid -> Incassata; canceled -> Annullata; unpaid, late, partial -> Emessa. Drafts and unknown
//   statuses are not imported (counted as skipped). "Scaduta" is never stored.
// - paid_at is Qonto's paid_at (date part), null when absent: no fallback to the issue date. A credit note is stored Incassata
//   (as in Zite) with paid_at null unless Qonto sends one.
// - company_id comes from companies.qonto_client_id = Qonto client id; unmatched documents are kept with company_id null and
//   counted in the run (a company linked later fills company_id on the next run). zite_pratica_id is never touched here.
// - Upsert on qonto_id: a document is written only if something changed, so a second run reports 0 inserted and 0 updated.
// - Rows are never deleted: a document Qonto no longer returns gets removed_at (cleared if it comes back). Nothing is marked
//   unless both lists were fetched completely and at least one document came back.
// - Any error is written to the run row and answered with a non-200 status; invoices already saved stay saved.
//
// Settings (Edge Function secrets): QONTO_LOGIN (the Qonto API credential, "organization-slug:secret-key", sent as the
// Authorization header; never logged). Vault secret qonto_sync_secret (migration 20261023125951).

import postgres from "npm:postgres@3.4.5";

const DB_URL = Deno.env.get("SUPABASE_DB_URL")!;
const QONTO_LOGIN = Deno.env.get("QONTO_LOGIN") ?? "";
const BASE_URL = "https://thirdparty.qonto.com/v2";
const PER_PAGE = 100;
const MAX_PAGES = 200;      // 20,000 documents per list: a runaway pagination stops here with an error
const CHUNK = 200;

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

// ---------------------------------------------------------------------------------------------------------------------------
// Qonto (GET only)
// ---------------------------------------------------------------------------------------------------------------------------
async function qontoGet(path: string): Promise<Record<string, unknown>> {
  const res = await fetch(`${BASE_URL}${path}`, {
    headers: { Authorization: QONTO_LOGIN, "Content-Type": "application/json" },
    signal: AbortSignal.timeout(30_000),
  });
  if (!res.ok) throw new Error(`Qonto ${path.split("?")[0]} -> ${res.status}: ${(await res.text()).slice(0, 300)}`);
  return await res.json() as Record<string, unknown>;
}

async function paged(path: string, key: string): Promise<Record<string, any>[]> {
  const out: Record<string, any>[] = [];
  for (let page = 1; page <= MAX_PAGES; page++) {
    const data = await qontoGet(`${path}?current_page=${page}&per_page=${PER_PAGE}`);
    const items = data[key];
    if (!Array.isArray(items)) throw new Error(`Qonto ${path}: no "${key}" list in the answer`);
    out.push(...items);
    const next = (data.meta as { next_page?: number | null } | undefined)?.next_page;
    if (!next) return out;
  }
  throw new Error(`Qonto ${path}: more than ${MAX_PAGES} pages`);
}

// ---------------------------------------------------------------------------------------------------------------------------
// Mapping (Zite src/lib/qonto.ts: statoDaQonto, importiDaQonto, noteDiCreditoDaQonto)
// ---------------------------------------------------------------------------------------------------------------------------
type Doc = {
  qonto_id: string; kind: "invoice" | "credit_note"; number: string | null; status_qonto: string; status: string;
  issue_date: string; due_date: string | null; paid_at: string | null; currency: string;
  total_cents: number; vat_cents: number; qonto_client_id: string | null; description: string | null; raw: unknown;
};

function statoDaQonto(status: string): string | null {
  if (status === "paid") return "Incassata";
  if (status === "canceled") return "Annullata";
  if (status === "unpaid" || status === "late" || status.includes("partial")) return "Emessa";
  return null;  // draft or unrecognised: not imported
}

const day = (v: unknown): string | null => {
  if (typeof v !== "string") return null;
  const d = v.slice(0, 10);
  return /^\d{4}-\d{2}-\d{2}$/.test(d) ? d : null;
};
const cents = (v: unknown): number | null => (typeof v === "number" && Number.isSafeInteger(v) ? v : null);
const text = (v: unknown, max: number): string | null => (typeof v === "string" && v.trim() ? v.trim().slice(0, max) : null);
const currencyOf = (v: unknown) => (typeof v === "string" && v.length === 3 ? v.toUpperCase() : "EUR");

function mapInvoice(i: Record<string, any>): Doc | "skip" {
  const status = typeof i.status === "string" ? i.status : "";
  const stato = statoDaQonto(status);
  const issue = day(i.issue_date), total = cents(i.total_amount_cents), vat = cents(i.vat_amount_cents ?? 0);
  if (!stato || typeof i.id !== "string" || !i.id || !issue || total === null || vat === null) return "skip";
  return {
    qonto_id: i.id, kind: "invoice", number: text(i.number, 100), status_qonto: status.slice(0, 50), status: stato,
    issue_date: issue, due_date: day(i.due_date), paid_at: day(i.paid_at), currency: currencyOf(i.currency),
    total_cents: total, vat_cents: vat, qonto_client_id: text(i.client?.id, 100),
    description: text(i.items?.[0]?.title, 500), raw: i,
  };
}

function mapCreditNote(n: Record<string, any>): Doc | "skip" {
  const issue = day(n.issue_date), total = cents(n.total_amount_cents), vat = cents(n.vat_amount_cents ?? 0);
  if (typeof n.id !== "string" || !n.id || !issue || total === null || vat === null) return "skip";
  return {
    qonto_id: n.id, kind: "credit_note", number: text(n.number, 100) ?? `NC-${n.id.slice(0, 6)}`,
    status_qonto: (text(n.status, 50) ?? "credit_note"), status: "Incassata",  // settled on issue, as in Zite
    issue_date: issue, due_date: issue, paid_at: day(n.paid_at), currency: currencyOf(n.currency),
    total_cents: -Math.abs(total), vat_cents: -Math.abs(vat), qonto_client_id: text(n.client?.id, 100),
    description: text(n.items?.[0]?.title, 500), raw: n,
  };
}

// ---------------------------------------------------------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------------------------------------------------------
async function upsert(docs: Doc[]): Promise<{ inserted: number; updated: number }> {
  let inserted = 0, updated = 0;
  for (let i = 0; i < docs.length; i += CHUNK) {
    const rows = await sql`
      insert into public.qonto_documents as t
        (qonto_id, kind, number, status_qonto, status, issue_date, due_date, paid_at, currency, total_cents, vat_cents,
         company_id, qonto_client_id, description, raw, removed_at)
      select r.qonto_id, r.kind, r.number, r.status_qonto, r.status, r.issue_date, r.due_date, r.paid_at, r.currency,
             r.total_cents, r.vat_cents,
             (select c.id from public.companies c where c.qonto_client_id = r.qonto_client_id),
             r.qonto_client_id, r.description, r.raw, null
        from jsonb_to_recordset(${JSON.stringify(docs.slice(i, i + CHUNK))}::text::jsonb) as r(
          qonto_id text, kind text, number text, status_qonto text, status text, issue_date date, due_date date,
          paid_at date, currency text, total_cents bigint, vat_cents bigint, qonto_client_id text, description text, raw jsonb)
      on conflict (qonto_id) do update set
        kind = excluded.kind, number = excluded.number, status_qonto = excluded.status_qonto, status = excluded.status,
        issue_date = excluded.issue_date, due_date = excluded.due_date, paid_at = excluded.paid_at,
        currency = excluded.currency, total_cents = excluded.total_cents, vat_cents = excluded.vat_cents,
        company_id = coalesce(excluded.company_id, t.company_id), qonto_client_id = excluded.qonto_client_id,
        description = excluded.description, raw = excluded.raw, removed_at = null, synced_at = now()
      where (t.kind, t.number, t.status_qonto, t.status, t.issue_date, t.due_date, t.paid_at, t.currency, t.total_cents,
             t.vat_cents, t.company_id, t.qonto_client_id, t.description, t.raw, t.removed_at)
            is distinct from
            (excluded.kind, excluded.number, excluded.status_qonto, excluded.status, excluded.issue_date, excluded.due_date,
             excluded.paid_at, excluded.currency, excluded.total_cents, excluded.vat_cents,
             coalesce(excluded.company_id, t.company_id), excluded.qonto_client_id, excluded.description, excluded.raw, null)
      returning (xmax = 0) as inserted`;
    for (const r of rows) r.inserted ? inserted++ : updated++;
  }
  return { inserted, updated };
}

async function run(runId: string) {
  const counts = { fetched: 0, inserted: 0, updated: 0, unmatched: 0, skipped: 0, removed: 0 };
  const save = async (error: string | null) => {
    const [row] = await sql`update public.qonto_sync_runs set finished_at = now(), fetched_count = ${counts.fetched},
                inserted_count = ${counts.inserted}, updated_count = ${counts.updated}, unmatched_count = ${counts.unmatched},
                skipped_count = ${counts.skipped}, removed_count = ${counts.removed}, error = ${error} where id = ${runId}
                returning unmatched_count`;
    // PRDDISC-34: when a run ends without error the database links the invoices it can by VAT number (trigger on this update) and rewrites
    // unmatched_count afterwards. The count computed above is from before that, so the answer of the run (and the Gestionale's button) takes the stored one.
    if (row && typeof row.unmatched_count === "number") counts.unmatched = row.unmatched_count;
  };
  try {
    if (!QONTO_LOGIN) throw new Error("QONTO_LOGIN is not set");
    const invoices = await paged("/client_invoices", "client_invoices");
    const creditNotes = await paged("/credit_notes", "credit_notes");
    counts.fetched = invoices.length + creditNotes.length;

    const clients = new Set((await sql`select qonto_client_id from public.companies where qonto_client_id is not null`)
      .map((r) => r.qonto_client_id as string));
    const byId = new Map<string, Doc>();
    for (const d of [...invoices.map(mapInvoice), ...creditNotes.map(mapCreditNote)]) {
      if (d === "skip") counts.skipped++; else byId.set(d.qonto_id, d);
    }
    const docs = [...byId.values()];
    counts.unmatched = docs.filter((d) => !d.qonto_client_id || !clients.has(d.qonto_client_id)).length;

    // invoices first, so a problem with the credit notes never loses them
    const invoiceDocs = docs.filter((d) => d.kind === "invoice");
    const noteDocs = docs.filter((d) => d.kind === "credit_note");
    for (const part of [invoiceDocs, noteDocs]) {
      const r = await upsert(part);
      counts.inserted += r.inserted;
      counts.updated += r.updated;
    }

    if (docs.length > 0) {
      const gone = await sql`
        update public.qonto_documents set removed_at = now()
         where removed_at is null and not (qonto_id = any(${docs.map((d) => d.qonto_id)}::text[]))
        returning 1`;
      counts.removed = gone.length;
    }
    await save(null);
    return { ok: true as const, run_id: runId, ...counts };
  } catch (e) {
    const message = ((e as { message?: string })?.message ?? "error").slice(0, 1000);
    console.error("qonto-sync error", (e as { code?: string })?.code ?? "", message);
    try { await save(message); } catch (e2) { console.error("qonto-sync: could not write the error", (e2 as { message?: string })?.message); }
    return { ok: false as const, run_id: runId, error: message, ...counts };
  }
}

// ---------------------------------------------------------------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { ok: false, error: "method_not_allowed" });
  const [s] = await sql`select decrypted_secret from vault.decrypted_secrets where name = 'qonto_sync_secret'`;
  if (!s?.decrypted_secret || !safeEqual(req.headers.get("x-sync-secret") ?? "", s.decrypted_secret)) {
    return reply(401, { ok: false, error: "unauthorized" });
  }
  let runId: string;
  try {
    [{ id: runId }] = await sql`insert into public.qonto_sync_runs default values returning id`;
  } catch (e) {
    console.error("qonto-sync: could not start the run", (e as { message?: string })?.message);
    return reply(500, { ok: false, error: "internal_error" });
  }
  const result = await run(runId);
  return reply(result.ok ? 200 : 502, result);
});
