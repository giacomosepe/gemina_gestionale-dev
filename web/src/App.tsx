// Routes (real URLs) and providers. New screens are added as routes under RequireSession.
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { RequireSession } from "./app/layouts/RequireSession";
import { SessionProvider, useSession } from "./features/auth/hooks/SessionProvider";
import { HomePage } from "./features/auth/pages/HomePage";
import { LoginPage } from "./features/auth/pages/LoginPage";
import { isConfigured } from "./shared/api/supabase";
import { pageStyle } from "./ui/styles";

const queryClient = new QueryClient({ defaultOptions: { queries: { staleTime: 60_000, refetchOnWindowFocus: false } } });

function LoginRoute() {
  const { session, loading } = useSession();
  if (loading) return <main style={pageStyle}><p>Caricamento…</p></main>;
  return session ? <Navigate to="/" replace /> : <LoginPage />;
}

export function App() {
  if (!isConfigured) {
    return <main style={pageStyle}><h1>Geminup</h1><p>In costruzione.</p><p style={{ color: "#666", fontSize: 14 }}>Nessun database collegato.</p></main>;
  }
  return (
    <QueryClientProvider client={queryClient}>
      <SessionProvider>
        <BrowserRouter>
          <Routes>
            <Route path="/login" element={<LoginRoute />} />
            <Route element={<RequireSession />}>
              <Route path="/" element={<HomePage />} />
            </Route>
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </BrowserRouter>
      </SessionProvider>
    </QueryClientProvider>
  );
}
