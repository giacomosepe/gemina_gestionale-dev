// The shell for now: login, then a page that says who you are. The real app replaces it (PM-147).
import { LoginPage } from "./auth/LoginPage";
import { SessionProvider, useSession } from "./auth/SessionProvider";
import { isConfigured, supabase, supabaseUrl } from "./auth/supabase";
import { useWhoAmI } from "./auth/useWhoAmI";

const page = { fontFamily: "system-ui, sans-serif", maxWidth: 520, margin: "18vh auto", padding: "0 16px" } as const;

function Home() {
  const { session } = useSession();
  const who = useWhoAmI();
  return (
    <main style={page}>
      <h1>Geminup</h1>
      <p>Ciao {session?.user.email}.</p>
      {who.state === "loading" && <p>Controllo il tuo accesso…</p>}
      {who.state === "ok" && <p>Accesso confermato{who.staffRole ? `: ${who.staffRole}` : ""}.</p>}
      {who.state === "refused" && <p role="alert">{who.message}</p>}
      <button onClick={() => supabase.auth.signOut()}>Esci</button>
      <p style={{ color: "#666", fontSize: 14 }}>In costruzione. Ambiente: {supabaseUrl?.replace("https://", "").split(".")[0]}</p>
    </main>
  );
}

function Gate() {
  const { session, loading } = useSession();
  if (loading) return <main style={page}><p>Caricamento…</p></main>;
  return session ? <Home /> : <LoginPage />;
}

export function App() {
  if (!isConfigured) {
    return <main style={page}><h1>Geminup</h1><p>In costruzione.</p><p style={{ color: "#666", fontSize: 14 }}>Nessun database collegato.</p></main>;
  }
  return <SessionProvider><Gate /></SessionProvider>;
}
