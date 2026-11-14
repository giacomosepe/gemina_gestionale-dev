// Calls the sample function `ping` with the session token: proves the whole chain from the browser (session -> function -> database as the user).
import { useEffect, useState } from "react";
import { publishableKeyValue, supabaseUrl } from "./supabase";
import { useSession } from "./SessionProvider";

export type WhoAmI =
  | { state: "loading" }
  | { state: "ok"; staffRole: string | null; organizationId: string | null }
  | { state: "refused"; message: string };

export function useWhoAmI(): WhoAmI {
  const { session } = useSession();
  const [result, setResult] = useState<WhoAmI>({ state: "loading" });
  const token = session?.access_token;

  useEffect(() => {
    if (!token) return;
    let active = true;
    fetch(`${supabaseUrl}/functions/v1/ping`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${token}`, apikey: publishableKeyValue },
      body: JSON.stringify({ action: "whoami" }),
    })
      .then((r) => r.json())
      .then((body) => {
        if (!active) return;
        setResult(body.ok ? { state: "ok", staffRole: body.data.staffRole, organizationId: body.data.organizationId }
                          : { state: "refused", message: body.error?.message ?? "Accesso non consentito." });
      })
      .catch(() => active && setResult({ state: "refused", message: "Il server non risponde." }));
    return () => { active = false; };
  }, [token]);

  return result;
}
