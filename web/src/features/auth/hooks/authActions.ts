// Sign-in and sign-out calls to Supabase Auth. Pages call these, never the client itself.
import { supabase } from "../../../shared/api/supabase";

type AuthError = { status?: number } | null;

export async function sendSignInLink(email: string, redirectTo: string): Promise<AuthError> {
  const { error } = await supabase.auth.signInWithOtp({ email, options: { shouldCreateUser: false, emailRedirectTo: redirectTo } });
  return error;
}

export async function signInWithGoogle(redirectTo: string): Promise<AuthError> {
  const { error } = await supabase.auth.signInWithOAuth({ provider: "google", options: { redirectTo } });
  return error;
}

export const signOut = () => supabase.auth.signOut();
