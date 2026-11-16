// Sends signed-out visitors to /login; shows the page otherwise.
import { Navigate, Outlet } from "react-router-dom";
import { useSession } from "../../features/auth/hooks/SessionProvider";
import { pageStyle } from "../../ui/styles";

export function RequireSession() {
  const { session, loading } = useSession();
  if (loading) return <main style={pageStyle}><p>Caricamento…</p></main>;
  return session ? <Outlet /> : <Navigate to="/login" replace />;
}
