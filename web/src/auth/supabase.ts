// The browser client of Supabase. Only the publishable key lives here (CLAUDE.md rule 5).
import { createClient } from "@supabase/supabase-js";

export const supabaseUrl: string | undefined = import.meta.env.VITE_SUPABASE_URL;
const publishableKey: string | undefined = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;

export const isConfigured = Boolean(supabaseUrl && publishableKey);

export const supabase = createClient(supabaseUrl ?? "http://localhost", publishableKey ?? "missing", {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
});

export const publishableKeyValue = publishableKey ?? "";
