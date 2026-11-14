// Placeholder: proves the build, the preview per branch and the hosting. The real app replaces it (PM-147).
export function App() {
  const supabaseUrl: string | undefined = import.meta.env.VITE_SUPABASE_URL;
  return (
    <main style={{ fontFamily: "system-ui, sans-serif", maxWidth: 520, margin: "20vh auto", padding: "0 16px" }}>
      <h1>Geminup</h1>
      <p>In costruzione.</p>
      <p style={{ color: "#666", fontSize: 14 }}>
        Ambiente: {supabaseUrl ? supabaseUrl.replace("https://", "").split(".")[0] : "nessun database collegato"}
      </p>
    </main>
  );
}
