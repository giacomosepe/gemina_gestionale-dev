// The one typed client for our Edge Functions: POST { action, ...payload } with the session token.
// Replies are { ok: true, data } or { ok: false, error: { code, message } } (see supabase/functions/_shared/errors.ts).
import { publishableKeyValue, supabase, supabaseUrl } from "./supabase";

export class ApiError extends Error {
  constructor(readonly code: string, message: string, readonly status: number) { super(message); }
}

export async function callFunction<T>(fn: string, action: string, payload: Record<string, unknown> = {}): Promise<T> {
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) throw new ApiError("unauthorized", "Accesso non autorizzato: effettua di nuovo l'accesso.", 401);
  let response: Response;
  try {
    response = await fetch(`${supabaseUrl}/functions/v1/${fn}`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${session.access_token}`, apikey: publishableKeyValue },
      body: JSON.stringify({ action, input: payload }),
    });
  } catch {
    throw new ApiError("network", "Il server non risponde.", 0);
  }
  const body = await response.json().catch(() => null);
  if (body?.ok) return body.data as T;
  throw new ApiError(body?.error?.code ?? "unknown", body?.error?.message ?? "Accesso non consentito.", response.status);
}
