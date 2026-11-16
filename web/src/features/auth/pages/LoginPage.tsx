// Staff login: an email link or Google. Invite-only: Supabase refuses everyone who was not invited, so the page never says whether an address exists.
import { type FormEvent, useState } from "react";
import { sendSignInLink, signInWithGoogle } from "../hooks/authActions";

type Status = { kind: "idle" } | { kind: "sending" } | { kind: "sent" } | { kind: "error"; message: string };

export function LoginPage() {
  const [email, setEmail] = useState("");
  const [status, setStatus] = useState<Status>({ kind: "idle" });
  const redirectTo = window.location.origin;

  async function sendLink(e: FormEvent) {
    e.preventDefault();
    setStatus({ kind: "sending" });
    const error = await sendSignInLink(email.trim(), redirectTo);
    // An address that was not invited gets an error from Supabase; the person sees the same message either way.
    setStatus(error && error.status !== 400 && error.status !== 422 ? { kind: "error", message: "Non è stato possibile inviare il link. Riprova tra poco." } : { kind: "sent" });
  }

  async function google() {
    const error = await signInWithGoogle(redirectTo);
    if (error) setStatus({ kind: "error", message: "L'accesso con Google non è disponibile." });
  }

  return (
    <main style={{ fontFamily: "system-ui, sans-serif", maxWidth: 380, margin: "18vh auto", padding: "0 16px" }}>
      <h1>Geminup</h1>
      <p>Accedi con il tuo indirizzo email. L'accesso è solo su invito.</p>
      <form onSubmit={sendLink} style={{ display: "grid", gap: 8 }}>
        <input type="email" required autoComplete="email" placeholder="nome@esempio.it" value={email} onChange={(e) => setEmail(e.target.value)}
               style={{ padding: 10, fontSize: 16 }} />
        <button type="submit" disabled={status.kind === "sending"} style={{ padding: 10, fontSize: 16 }}>Inviami il link di accesso</button>
      </form>
      <p style={{ textAlign: "center", color: "#888" }}>oppure</p>
      <button onClick={google} style={{ padding: 10, fontSize: 16, width: "100%" }}>Accedi con Google</button>
      {status.kind === "sent" && <p>Se l'indirizzo è abilitato, riceverai a breve un'email con il link di accesso.</p>}
      {status.kind === "error" && <p role="alert" style={{ color: "#b00020" }}>{status.message}</p>}
    </main>
  );
}
