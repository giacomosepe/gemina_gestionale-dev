// jobs (PM-151): the runner of the job queue.
// Called only by the database (private.jobs_tick, every minute while a job is waiting) with the secret kept in Vault ('jobs_secret').
// It takes waiting jobs with private.jobs_claim, runs the handler of each kind, and reports back with private.job_done / private.job_fail.
// The rules (wait between tries, 5 tries, dead letter, alert) live in SQL (migration 20261115100000) and are tested there (test 040).
// To add a job kind: add a handler below and call private.enqueue_job('<kind>', '<json>') from SQL or a function.
import postgres from "npm:postgres@3.4.5";

const DB_URL = Deno.env.get("SUPABASE_DB_URL") ?? "";
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? Deno.env.get("RESEND_SUPABASE_KEY") ?? "";
const PARTNER_EMAILS_REAL = Deno.env.get("PARTNER_EMAILS_REAL") === "true";
const DEV_TEST_PARTNER_EMAILS = new Set((Deno.env.get("DEV_TEST_PARTNER_EMAILS") ?? "").split(",").map((e) => e.trim().toLowerCase()).filter(Boolean));
const ALERT_EMAILS = (Deno.env.get("ALERT_EMAILS") ?? "").split(",").map((e) => e.trim()).filter(Boolean);
const FROM_TEAM = "Gemina Advisory <gestionale@mail.geminaadvisory.com>";
const TIME_BUDGET_MS = 50_000;

const sql = postgres(DB_URL, { prepare: false, max: 2, idle_timeout: 20 });

type Job = { msg_id: number; read_ct: number; message: { kind: string; payload: Record<string, unknown> } };
type Handler = (payload: Record<string, unknown>) => Promise<void>;

// Same rule as message-emails: outside production an email goes only to an address on DEV_TEST_PARTNER_EMAILS.
const allowed = (to: string) => PARTNER_EMAILS_REAL || DEV_TEST_PARTNER_EMAILS.has(to.toLowerCase());

const handlers: Record<string, Handler> = {
  // An email to ALERT_EMAILS (the admins) about a failure. Without Resend or recipients it fails, and is retried like any job.
  alert: async (p) => {
    if (!RESEND_API_KEY) throw new Error("resend_not_configured");
    const to = ALERT_EMAILS.filter(allowed);
    if (ALERT_EMAILS.length === 0) throw new Error("ALERT_EMAILS is not set");
    if (to.length === 0) { console.warn("alert blocked: no recipient is on DEV_TEST_PARTNER_EMAILS and this project is not live"); return; }
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { authorization: `Bearer ${RESEND_API_KEY}`, "content-type": "application/json" },
      body: JSON.stringify({ from: FROM_TEAM, to, subject: String(p.subject ?? "Avviso"), text: String(p.text ?? "") }),
    });
    if (!res.ok) throw new Error(`resend ${res.status}: ${(await res.text()).slice(0, 200)}`);
  },
  noop: async () => {},
};

function safeEqual(a: string, b: string) {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  if (ea.length !== eb.length || ea.length === 0) return false;
  let diff = 0;
  for (let i = 0; i < ea.length; i++) diff |= ea[i] ^ eb[i];
  return diff === 0;
}

const reply = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { ok: false, error: "method_not_allowed" });
  const [s] = await sql`select decrypted_secret from vault.decrypted_secrets where name = 'jobs_secret'`;
  if (!s?.decrypted_secret || !safeEqual(req.headers.get("x-jobs-secret") ?? "", s.decrypted_secret)) return reply(401, { ok: false, error: "unauthorized" });

  const started = Date.now();
  const result = { done: 0, retried: 0, dead: 0 };
  while (Date.now() - started < TIME_BUDGET_MS) {
    const jobs = await sql<Job[]>`select msg_id, read_ct, message from private.jobs_claim(10, 120)`;
    if (jobs.length === 0) break;
    for (const job of jobs) {
      const handler = handlers[job.message.kind];
      try {
        if (!handler) throw new Error(`no handler for job kind "${job.message.kind}"`);
        await handler(job.message.payload ?? {});
        await sql`select private.job_done(${job.msg_id})`;
        result.done++;
      } catch (e) {
        const [r] = await sql`select private.job_fail(${job.msg_id}, ${String((e as Error).message ?? e)}) as r`;
        console.error("job failed", job.message.kind, job.msg_id, (e as Error).message, r?.r);
        if (r?.r === "dead") result.dead++; else result.retried++;
      }
    }
  }
  return reply(200, { ok: true, ...result });
});
