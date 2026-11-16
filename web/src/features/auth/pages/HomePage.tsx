import { environmentName } from "../../../shared/environment";
import { signOut } from "../hooks/authActions";
import { useSession } from "../hooks/SessionProvider";
import { useWhoAmI } from "../hooks/useWhoAmI";
import { pageStyle } from "../../../ui/styles";

export function HomePage() {
  const { session } = useSession();
  const who = useWhoAmI();
  return (
    <main style={pageStyle}>
      <h1>Geminup</h1>
      <p>Ciao {session?.user.email}.</p>
      {who.isPending && <p>Controllo il tuo accesso…</p>}
      {who.isSuccess && <p>Accesso confermato{who.data.staffRole ? `: ${who.data.staffRole}` : ""}.</p>}
      {who.isError && <p role="alert">{who.error.message}</p>}
      <button onClick={() => signOut()}>Esci</button>
      <p style={{ color: "#666", fontSize: 14 }}>In costruzione. Ambiente: {environmentName}</p>
    </main>
  );
}
