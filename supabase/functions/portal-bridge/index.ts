// portal-bridge (v3)
// Lets Zite endpoints use Supabase on behalf of the person logged in to Zite.
//
// Trust model:
// - Two secrets, one per Zite app:
//     BRIDGE_SECRET_STAFF  -> gestionale (internal): only acts for staff
//     BRIDGE_SECRET_PORTAL -> portale segnalatori (external): never acts for staff
// - The caller (a Zite endpoint) must pass the email of the logged-in Zite user
//   taken from context.user — never from anything the browser sends.
// - Every action runs inside Postgres AS THAT PERSON (role "authenticated" +
//   their user id), so the Row Level Security rules decide what they can see/do.
// - Action "session" returns a short-lived Supabase access token (no refresh
//   token) so the browser can talk to Supabase directly, still under RLS.
//
// Request:  POST  headers: { "x-bridge-secret": <secret>, "content-type": "application/json" }
//           body:  { "email": "...", "action": "...", ...params }
// Response: { ok: true, data } or { ok: false, error }
//
// 2026-10-19: the schema now has what this code expects (partners.archived and the
// P0429 send limit, migration 20261019190000). Code unchanged from the deployed v2.
// 2026-10-20 (v3): staff follow the Gestionale's Ruoli table. Every staff-secret call carries
// zite_user_id, staff_role ('admin' | 'manager') and optional names; the bridge creates or updates the
// staff profile to match (migration 20261020183659). New action staff_leave (admin only).
// The portal refuses former_staff as well as staff.

import postgres from "npm:postgres@3.4.5";
import { createClient } from "npm:@supabase/supabase-js@2.50.0";

const SECRET_STAFF = Deno.env.get("BRIDGE_SECRET_STAFF") ?? "";
const SECRET_PORTAL = Deno.env.get("BRIDGE_SECRET_PORTAL") ?? "";
const DB_URL = Deno.env.get("SUPABASE_DB_URL")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SECRET_KEY = (() => {
  try { return JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}")["default"]; }
  catch { return undefined; }
})() ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PUBLISHABLE_KEY = (() => {
  try { return JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") ?? "{}")["default"]; }
  catch { return undefined; }
})() ?? Deno.env.get("SUPABASE_ANON_KEY")!;

const sql = postgres(DB_URL, { prepare: false, max: 3, idle_timeout: 20 });
const admin = createClient(SUPABASE_URL, SECRET_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

type Audience = "staff" | "portal";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

class BridgeError extends Error {
  constructor(public status: number, public code: string) { super(code); }
}

function reply(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function safeEqual(a: string, b: string) {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  if (ea.length !== eb.length || ea.length === 0) return false;
  let diff = 0;
  for (let i = 0; i < ea.length; i++) diff |= ea[i] ^ eb[i];
  return diff === 0;
}

const uuid = (v: unknown, name: string) => {
  if (typeof v !== "string" || !UUID.test(v)) throw new BridgeError(400, `invalid_${name}`);
  return v;
};
const optUuid = (v: unknown, name: string) => (v == null ? null : uuid(v, name));
const text = (v: unknown, name: string, max: number) => {
  if (typeof v !== "string" || v.trim().length === 0 || v.length > max) throw new BridgeError(400, `invalid_${name}`);
  return v.trim();
};
const optText = (v: unknown, name: string, max: number) => (v == null || v === "" ? null : text(v, name, max));

// ---------------------------------------------------------------------------
// Identity: find (or, for known referrers, create) the Supabase user for an email.
// Runs with full privileges; nothing here is influenced by the browser.
// ---------------------------------------------------------------------------
// What the Gestionale says about the person (2026-10-20: staff follow the Zite "Ruoli" table). Only the
// staff secret can send it, and the Gestionale refuses anyone without a Ruoli row before calling, so it is
// the Gestionale's server, not a browser, that vouches for "this person is in the team, with this role".
type StaffInfo = { ziteUserId: string; staffRole: "admin" | "manager"; nameFirst: string | null; nameLast: string | null };
function staffInfo(p: Record<string, unknown>): StaffInfo {
  const ziteUserId = text(p.zite_user_id, "zite_user_id", 100);
  const staffRole = p.staff_role;
  if (staffRole !== "admin" && staffRole !== "manager") throw new BridgeError(400, "invalid_staff_role");
  return { ziteUserId, staffRole, nameFirst: optText(p.name_first, "name_first", 100), nameLast: optText(p.name_last, "name_last", 100) };
}

// Creates, updates or brings back the staff profile for this email so it matches Ruoli.
async function resolveStaff(email: string, info: StaffInfo): Promise<{ id: string; role: string }> {
  const [profile] = await sql`select id, role, zite_user_id from public.profiles where lower(email) = ${email}`;
  const [owner] = await sql`select id from public.profiles where zite_user_id = ${info.ziteUserId}`;
  if (owner && owner.id !== profile?.id) {
    // The Zite user's email changed, or two Zite users share a profile: needs a person to look at it.
    console.error("zite_user_id already on another profile", info.ziteUserId);
    throw new BridgeError(409, "zite_user_conflict");
  }
  if (profile && profile.role !== "staff" && profile.role !== "former_staff") {
    // The address belongs to a referrer or a client: never turn it into staff.
    throw new BridgeError(403, "email_not_staff");
  }
  let id: string = profile?.id;
  if (!id) {
    const { data, error } = await admin.auth.admin.createUser({ email, email_confirm: true });
    if (error || !data?.user) {
      console.error("createUser (staff) failed", error?.message);
      throw new BridgeError(500, "account_creation_failed");
    }
    id = data.user.id;
  }
  // organization_id is filled by the profiles_set_staff_organization trigger.
  await sql`update public.profiles
               set role = 'staff', staff_role = ${info.staffRole}, zite_user_id = ${info.ziteUserId},
                   name_first = coalesce(${info.nameFirst}, name_first), name_last = coalesce(${info.nameLast}, name_last)
             where id = ${id}
               and (role is distinct from 'staff' or staff_role is distinct from ${info.staffRole}::public.staff_role
                    or zite_user_id is distinct from ${info.ziteUserId}
                    or (${info.nameFirst}::text is not null and name_first is distinct from ${info.nameFirst})
                    or (${info.nameLast}::text is not null and name_last is distinct from ${info.nameLast}))`;
  return { id, role: "staff" };
}

async function resolveUser(email: string, audience: Audience, payload: Record<string, unknown>): Promise<{ id: string; role: string }> {
  if (audience === "staff") return resolveStaff(email, staffInfo(payload));

  const [profile] = await sql`select id, role from public.profiles where lower(email) = ${email}`;
  // Active referrer whose Zite email matches (archived ones don't count).
  const [partner] = await sql`select id from public.partners where lower(email) = ${email} and not archived`;

  if (profile) {
    // The portal never acts for Gemina's team, past or present.
    if (profile.role === "staff" || profile.role === "former_staff") throw new BridgeError(403, "staff_use_gestionale");

    if (profile.role === "partner") {
      // Membership follows the email on the referrer record: if the email changed
      // or the referrer was archived, access is removed here.
      await sql`delete from public.partner_members
                 where profile_id = ${profile.id}
                   and partner_id is distinct from ${partner?.id ?? null}`;
      if (!partner) throw new BridgeError(403, "unknown_user");
      await sql`insert into public.partner_members (partner_id, profile_id)
                values (${partner.id}, ${profile.id}) on conflict do nothing`;
    }
    return { id: profile.id, role: profile.role };
  }

  // Only active referrers known in Zite get an account automatically, and only
  // through the portal. Staff come from the Gestionale (resolveStaff); clients come later.
  if (!partner) throw new BridgeError(403, "unknown_user");

  const { data, error } = await admin.auth.admin.createUser({ email, email_confirm: true });
  if (error || !data?.user) {
    console.error("createUser failed", error?.message);
    throw new BridgeError(500, "account_creation_failed");
  }
  const id = data.user.id;
  await sql`update public.profiles set role = 'partner' where id = ${id}`;
  await sql`insert into public.partner_members (partner_id, profile_id)
            values (${partner.id}, ${id}) on conflict do nothing`;
  return { id, role: "partner" };
}

// Run fn inside a transaction as the given user, so RLS applies.
async function asUser<T>(userId: string, fn: (tx: postgres.TransactionSql) => Promise<T>): Promise<T> {
  return await sql.begin(async (tx) => {
    await tx`select set_config('request.jwt.claims', ${JSON.stringify({ sub: userId, role: "authenticated" })}, true)`;
    await tx.unsafe("set local role authenticated");
    return await fn(tx);
  }) as T;
}

// Someone left the Gemina team (set to "Nessuno" in the Gestionale's Accesso al Gestionale card, which only an
// administrator can do). Staff secret only; the caller must be an admin. Their profile becomes former_staff: no
// access from now on (rules test role = 'staff'), name kept on old messages. Their current token (at most about
// 1 hour) cannot be renewed: the Gestionale refuses them and the bridge only makes staff from the Gestionale.
async function staffLeave(audience: Audience, callerId: string, p: Record<string, unknown>) {
  if (audience !== "staff") throw new BridgeError(403, "staff_only");
  const target = text(p.target_zite_user_id, "target_zite_user_id", 100);
  const [caller] = await sql`select staff_role, zite_user_id from public.profiles where id = ${callerId}`;
  if (caller?.staff_role !== "admin") throw new BridgeError(403, "admin_only");
  if (caller.zite_user_id === target) throw new BridgeError(400, "cannot_remove_self");
  const rows = await sql`update public.profiles
                            set role = 'former_staff', staff_role = null, organization_id = null
                          where zite_user_id = ${target} and role = 'staff'
                          returning id`;
  return { removed: rows.length };
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------
type Handler = (tx: postgres.TransactionSql, userId: string, p: Record<string, unknown>) => Promise<unknown>;

// Short-lived Supabase access token for the browser (no refresh token: the Zite
// endpoint asks again before it expires, so Zite stays the gatekeeper).
async function createSession(email: string) {
  const { data: link, error: linkErr } = await admin.auth.admin.generateLink({ type: "magiclink", email });
  const tokenHash = link?.properties?.hashed_token;
  if (linkErr || !tokenHash) {
    console.error("generateLink failed", linkErr?.message);
    throw new BridgeError(500, "session_failed");
  }
  const anon = createClient(SUPABASE_URL, PUBLISHABLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await anon.auth.verifyOtp({ token_hash: tokenHash, type: "email" });
  if (error || !data?.session) {
    console.error("verifyOtp failed", error?.message);
    throw new BridgeError(500, "session_failed");
  }
  return {
    access_token: data.session.access_token,
    expires_at: data.session.expires_at, // unix seconds
    user_id: data.session.user.id,
    supabase_url: SUPABASE_URL,
    publishable_key: PUBLISHABLE_KEY,
  };
}

const actions: Record<string, Handler> = {
  async me(tx, userId) {
    const [me] = await tx`select id, email, role, staff_role, name_first, name_last
                          from public.profiles where id = ${userId}`;
    const partners = await tx`select id, name, zite_segnalatore_id from public.partners order by name`;
    const companies = me.role === "client"
      ? await tx`select id, name, zite_azienda_id from public.companies order by name`
      : [];
    return { me, partners: me.role === "staff" ? [] : partners, companies };
  },

  // Conversations visible to me, newest activity first, with last message and unread count.
  async list_conversations(tx, userId, p) {
    const limit = Math.min(Number(p.limit ?? 50) || 50, 200);
    return await tx`
      select c.id, c.kind, c.title, c.company_id, c.partner_id,
             co.name as company_name, pa.name as partner_name,
             c.zite_pratica_id, c.zite_trattativa_id, c.zite_provvigione_id,
             c.created_at,
             lm.body as last_message, lm.created_at as last_message_at,
             coalesce(lm.created_at, c.created_at) as activity_at,
             (select count(*)::int from public.messages m
               where m.conversation_id = c.id
                 and m.sender_id is distinct from ${userId}
                 and m.created_at > coalesce(cm.last_read_at, 'epoch'::timestamptz)) as unread
        from public.conversations c
        left join public.companies co on co.id = c.company_id
        left join public.partners pa on pa.id = c.partner_id
        left join public.conversation_members cm on cm.conversation_id = c.id and cm.profile_id = ${userId}
        left join lateral (select m.body, m.created_at from public.messages m
                            where m.conversation_id = c.id
                            order by m.created_at desc limit 1) lm on true
       order by activity_at desc
       limit ${limit}`;
  },

  async list_messages(tx, userId, p) {
    const conversationId = uuid(p.conversation_id, "conversation_id");
    const after = p.after == null ? null : new Date(String(p.after));
    if (after && isNaN(after.getTime())) throw new BridgeError(400, "invalid_after");
    const [conv] = await tx`select id, title, kind from public.conversations where id = ${conversationId}`;
    if (!conv) throw new BridgeError(404, "conversation_not_found");
    // Newest 500 (or everything after `after`), returned oldest-first for display.
    const messages = await tx`
      select * from (
        select m.id, m.body, m.internal, m.created_at, m.sender_id,
               (m.sender_id = ${userId}) as is_me,
               nullif(trim(coalesce(pr.name_first,'') || ' ' || coalesce(pr.name_last,'')), '') as sender_name,
               pr.role as sender_role
          from public.messages m
          left join public.profiles pr on pr.id = m.sender_id
         where m.conversation_id = ${conversationId}
           and (${after}::timestamptz is null or m.created_at > ${after}::timestamptz)
         order by m.created_at desc
         limit 500
      ) t order by t.created_at asc`;
    return { conversation: conv, messages };
  },

  async send_message(tx, userId, p) {
    const conversationId = uuid(p.conversation_id, "conversation_id");
    const body = text(p.body, "body", 10000);
    const internal = p.internal === true;
    const [m] = await tx`
      insert into public.messages (conversation_id, sender_id, body, internal)
      values (${conversationId}, ${userId}, ${body}, ${internal})
      returning id, created_at`;
    await tx`
      insert into public.conversation_members (conversation_id, profile_id, last_read_at)
      values (${conversationId}, ${userId}, now())
      on conflict (conversation_id, profile_id) do update set last_read_at = excluded.last_read_at`;
    return m;
  },

  async mark_read(tx, userId, p) {
    const conversationId = uuid(p.conversation_id, "conversation_id");
    await tx`
      insert into public.conversation_members (conversation_id, profile_id, last_read_at)
      values (${conversationId}, ${userId}, now())
      on conflict (conversation_id, profile_id) do update set last_read_at = excluded.last_read_at`;
    return { ok: true };
  },

  // Staff: any scope. Referrer: a new conversation in their own scope.
  async create_conversation(tx, userId, p) {
    const title = text(p.title, "title", 200);
    const firstMessage = optText(p.first_message, "first_message", 10000);
    const [me] = await tx`select role from public.profiles where id = ${userId}`;
    let kind: "client" | "partner";
    let companyId: string | null = null;
    let partnerId: string | null = null;

    if (me.role === "partner") {
      const mine = await tx`select partner_id from public.partner_members where profile_id = ${userId}`;
      const requested = optUuid(p.partner_id, "partner_id");
      partnerId = requested ?? (mine.length === 1 ? mine[0].partner_id : null);
      if (!partnerId) throw new BridgeError(400, "partner_id_required");
      kind = "partner";
      // Referrers can't link conversations to Zite records (the database enforces this too).
      p = { ...p, zite_pratica_id: null, zite_trattativa_id: null, zite_provvigione_id: null };
    } else {
      kind = p.kind === "client" ? "client" : "partner";
      companyId = optUuid(p.company_id, "company_id");
      partnerId = optUuid(p.partner_id, "partner_id");
    }

    const [c] = await tx`
      insert into public.conversations
        (kind, title, company_id, partner_id, created_by,
         zite_pratica_id, zite_trattativa_id, zite_provvigione_id)
      values (${kind}, ${title}, ${companyId}, ${partnerId}, ${userId},
              ${optText(p.zite_pratica_id, "zite_pratica_id", 100)},
              ${optText(p.zite_trattativa_id, "zite_trattativa_id", 100)},
              ${optText(p.zite_provvigione_id, "zite_provvigione_id", 100)})
      returning id`;
    if (firstMessage) {
      await tx`insert into public.messages (conversation_id, sender_id, body)
               values (${c.id}, ${userId}, ${firstMessage})`;
    }
    return c;
  },

  // Staff only (RLS enforces): find the Supabase ids for Zite records.
  async lookup(tx, _userId, p) {
    const ziteAziendaId = optText(p.zite_azienda_id, "zite_azienda_id", 100);
    const ziteSegnalatoreId = optText(p.zite_segnalatore_id, "zite_segnalatore_id", 100);
    const company = ziteAziendaId
      ? (await tx`select id, name from public.companies where zite_azienda_id = ${ziteAziendaId}`)[0] ?? null
      : null;
    const partner = ziteSegnalatoreId
      ? (await tx`select id, name from public.partners where zite_segnalatore_id = ${ziteSegnalatoreId}`)[0] ?? null
      : null;
    return { company, partner };
  },
};

// ---------------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { ok: false, error: "method_not_allowed" });
  if (!SECRET_STAFF || !SECRET_PORTAL || SECRET_STAFF === SECRET_PORTAL) {
    return reply(500, { ok: false, error: "bridge_not_configured" });
  }
  const given = req.headers.get("x-bridge-secret") ?? "";
  const isStaff = safeEqual(given, SECRET_STAFF);
  const isPortal = safeEqual(given, SECRET_PORTAL);
  if (!isStaff && !isPortal) return reply(401, { ok: false, error: "unauthorized" });
  const audience: Audience = isStaff ? "staff" : "portal";

  let payload: Record<string, unknown>;
  try {
    const raw = await req.text();
    if (raw.length > 64_000) return reply(413, { ok: false, error: "too_large" });
    payload = JSON.parse(raw);
  } catch {
    return reply(400, { ok: false, error: "invalid_json" });
  }

  try {
    const email = String(payload.email ?? "").trim().toLowerCase();
    if (!EMAIL.test(email)) throw new BridgeError(400, "invalid_email");
    const action = String(payload.action ?? "");
    if (action !== "session" && action !== "staff_leave" && !Object.hasOwn(actions, action)) throw new BridgeError(400, "unknown_action");

    const user = await resolveUser(email, audience, payload);
    if (action === "session") return reply(200, { ok: true, data: await createSession(email) });
    if (action === "staff_leave") return reply(200, { ok: true, data: await staffLeave(audience, user.id, payload) });
    const data = await asUser(user.id, (tx) => actions[action](tx, user.id, payload));
    return reply(200, { ok: true, data });
  } catch (e) {
    if (e instanceof BridgeError) return reply(e.status, { ok: false, error: e.code });
    const code = (e as { code?: string })?.code;
    // 42501 = RLS / permission denied; P0429 = send limit
    if (code === "42501") return reply(403, { ok: false, error: "not_allowed" });
    if (code === "P0429") return reply(429, { ok: false, error: "rate_limited" });
    if (code === "23503" || code === "23514") return reply(400, { ok: false, error: "invalid_reference" });
    console.error("bridge error", e);
    return reply(500, { ok: false, error: "internal_error" });
  }
});
