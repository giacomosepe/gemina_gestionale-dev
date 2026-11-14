// The base of every domain function (PM-146). A function is a set of named actions:
//
//   POST { "action": "cases.list", "input": { ... } }   with   Authorization: Bearer <the user's Supabase session token>
//   -> 200 { "ok": true, "data": ... }   or   { "ok": false, "error": { "code", "message" (Italian), "details"? } }
//
// For every request the router: answers CORS, checks the session, opens ONE database transaction as that user (so row-level security applies and a
// failure rolls the whole action back), reads the organization and staff role through the database helpers, checks the audience and the permission,
// validates the input with the action's Zod schema, runs the handler, and writes ONE structured log line (function, action, user, organization,
// duration, outcome). The pieces that touch the outside world are injected (`Deps`), so the router is unit-tested without a network or database.
import { z } from "npm:zod@3.23.8";
import { AppError, errorBody, STATUS, toAppError } from "./errors.ts";

export interface AuthUser { id: string; email: string | null }

export interface Identity { organizationId: string | null; staffRole: string | null }

export interface Context<Tx> extends Identity {
  requestId: string;
  userId: string;
  email: string | null;
  /** The database transaction of this request; it runs as the signed-in user. */
  tx: Tx;
  can(permission: string): Promise<boolean>;
}

export interface Deps<Tx> {
  authenticate(req: Request): Promise<AuthUser>;
  runAsUser<T>(user: AuthUser, fn: (tx: Tx) => Promise<T>): Promise<T>;
  loadIdentity(tx: Tx): Promise<Identity>;
  hasPermission(tx: Tx, permission: string): Promise<boolean>;
  log(line: Record<string, unknown>): void;
  allowedOrigins: string[];
  newId(): string;
  now(): number;
}

export interface ActionDef<I, O, Tx> {
  input: z.ZodType<I, z.ZodTypeDef, unknown>;
  /** "staff" (default): signed in AND a member of the organization's staff. "any": any signed-in user that belongs to an organization. */
  audience?: "staff" | "any";
  /** A permission key (see table permissions) the user's role must hold. */
  permission?: string;
  handler(ctx: Context<Tx>, input: I): Promise<O>;
}

// deno-lint-ignore no-explicit-any
export type Actions<Tx> = Record<string, ActionDef<any, unknown, Tx>>;

export function defineFunction<Tx>(name: string, actions: Actions<Tx>) {
  return { name, handle: (req: Request, deps: Deps<Tx>) => handle(name, actions, req, deps) };
}

function corsHeaders(req: Request, allowed: string[]): Record<string, string> {
  const origin = req.headers.get("origin");
  if (!origin || !(allowed.includes("*") || allowed.includes(origin))) return {};
  return {
    "access-control-allow-origin": origin,
    "access-control-allow-headers": "authorization, content-type, apikey, x-client-info",
    "access-control-allow-methods": "POST, OPTIONS",
    "access-control-max-age": "600",
    vary: "origin",
  };
}

async function handle<Tx>(name: string, actions: Actions<Tx>, req: Request, deps: Deps<Tx>): Promise<Response> {
  const started = deps.now();
  const requestId = deps.newId();
  const cors = corsHeaders(req, deps.allowedOrigins);
  const log: Record<string, unknown> = { fn: name, request_id: requestId, action: null, user: null, organization: null };
  const finish = (status: number, body: unknown, outcome: string) => {
    deps.log({ ...log, status, outcome, ms: deps.now() - started });
    return new Response(JSON.stringify(body), {
      status, headers: { "content-type": "application/json", "x-request-id": requestId, ...cors },
    });
  };
  const fail = (e: unknown) => {
    const err = toAppError(e);
    if (err.code === "internal") log.error = String((e as Error)?.message ?? e).slice(0, 500);
    return finish(STATUS[err.code], errorBody(err), err.code);
  };

  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  try {
    if (req.method !== "POST") throw new AppError("method_not_allowed");
    let body: { action?: unknown; input?: unknown };
    try { body = await req.json(); } catch { throw new AppError("invalid_input", undefined, [{ path: [], message: "the body is not JSON" }]); }
    if (typeof body?.action !== "string") throw new AppError("invalid_input", undefined, [{ path: ["action"], message: "required" }]);
    log.action = body.action;
    const def = Object.hasOwn(actions, body.action) ? actions[body.action] : undefined;
    if (!def) throw new AppError("unknown_action");

    const user = await deps.authenticate(req);
    log.user = user.id;

    const data = await deps.runAsUser(user, async (tx) => {
      const identity = await deps.loadIdentity(tx);
      log.organization = identity.organizationId;
      if (!identity.organizationId) throw new AppError("forbidden");
      if ((def.audience ?? "staff") === "staff" && !identity.staffRole) throw new AppError("forbidden");
      if (def.permission && !(await deps.hasPermission(tx, def.permission))) throw new AppError("forbidden");

      const parsed = def.input.safeParse(body.input ?? {});
      if (!parsed.success) {
        throw new AppError("invalid_input", undefined, parsed.error.issues.map((i) => ({ path: i.path, message: i.message })));
      }
      const ctx: Context<Tx> = {
        ...identity, requestId, userId: user.id, email: user.email, tx,
        can: (permission) => deps.hasPermission(tx, permission),
      };
      return await def.handler(ctx, parsed.data);
    });
    return finish(200, { ok: true, data }, "ok");
  } catch (e) {
    return fail(e);
  }
}
