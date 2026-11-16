// The signed-in session, from Supabase Auth. Replaces Zite's context.user (PM-145).
import type { Session } from "@supabase/supabase-js";
import { createContext, type ReactNode, useContext, useEffect, useState } from "react";
import { supabase } from "../../../shared/api/supabase";

interface SessionState { session: Session | null; loading: boolean }
const SessionContext = createContext<SessionState>({ session: null, loading: true });

export function SessionProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<SessionState>({ session: null, loading: true });

  useEffect(() => {
    let active = true;
    supabase.auth.getSession().then(({ data }) => { if (active) setState({ session: data.session, loading: false }); });
    const { data: sub } = supabase.auth.onAuthStateChange((_event, session) => setState({ session, loading: false }));
    return () => { active = false; sub.subscription.unsubscribe(); };
  }, []);

  return <SessionContext.Provider value={state}>{children}</SessionContext.Provider>;
}

export const useSession = () => useContext(SessionContext);
