// The real `Deps` of the router: Supabase Auth to check the session, a direct database connection to run as the user.
import postgres from "npm:postgres@3.4.5";
import { AppError } from "./errors.ts";
import type { AuthUser, Deps } from "./router.ts";

export type Tx = postgres.TransactionSql;

export function supabaseDeps(env = Deno.env): Deps<Tx> {
  const url = (env.get("SUPABASE_URL") ?? "").replace(/\/+$/, "");
  const apikey = env.get("SUPABASE_ANON_KEY") ?? env.get("SUPABASE_PUBLISHABLE_KEY") ?? "";
  const sql = postgres(env.get("SUPABASE_DB_URL") ?? "", { prepare: false, max: 4, idle_timeout: 20 });

  return {
    allowedOrigins: (env.get("ALLOWED_ORIGINS") ?? "").split(",").map((o) => o.trim()).filter(Boolean),
    newId: () => crypto.randomUUID(),
    now: () => Date.now(),
    log: (line) => console.log(JSON.stringify(line)),

    // Asks Supabase Auth who the token belongs to: works for any signing key, and a revoked session is refused at once.
    async authenticate(req): Promise<AuthUser> {
      const header = req.headers.get("authorization") ?? "";
      const token = header.toLowerCase().startsWith("bearer ") ? header.slice(7).trim() : "";
      if (!token) throw new AppError("unauthorized");
      const res = await fetch(`${url}/auth/v1/user`, { headers: { authorization: `Bearer ${token}`, apikey } });
      if (!res.ok) throw new AppError("unauthorized");
      const u = await res.json();
      if (typeof u?.id !== "string") throw new AppError("unauthorized");
      return { id: u.id, email: typeof u.email === "string" ? u.email : null };
    },

    // One transaction as the signed-in user: role `authenticated` and the claims row-level security reads. Everything inside rolls back together.
    runAsUser: (user, fn) =>
      sql.begin(async (tx) => {
        await tx`select set_config('request.jwt.claims', ${JSON.stringify({ sub: user.id, role: "authenticated", email: user.email })}, true)`;
        await tx`set local role authenticated`;
        return await fn(tx);
      }) as Promise<never>,

    async loadIdentity(tx) {
      const [r] = await tx`select private.current_organization_id() as organization_id,
                                  (select p.staff_role::text from public.profiles p where p.id = (select auth.uid()) and p.role = 'staff') as staff_role`;
      return { organizationId: r?.organization_id ?? null, staffRole: r?.staff_role ?? null };
    },

    async hasPermission(tx, permission) {
      const [r] = await tx`select private.has_permission(${permission}) as ok`;
      return r?.ok === true;
    },
  };
}
