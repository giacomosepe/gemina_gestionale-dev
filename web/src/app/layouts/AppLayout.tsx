// The frame of the signed-in app: top bar with the sections and the exit button; the page goes in the Outlet.
import { NavLink, Outlet } from "react-router-dom";
import { signOut } from "../../features/auth/hooks/authActions";
import { contentStyle, tokens } from "../../ui/styles";

const link = ({ isActive }: { isActive: boolean }) => ({ color: isActive ? tokens.accent : tokens.ink, textDecoration: isActive ? "underline" : "none", marginRight: 16 });

export function AppLayout() {
  return (
    <div style={contentStyle}>
      <header style={{ display: "flex", justifyContent: "space-between", alignItems: "center", paddingBottom: 12, borderBottom: `1px solid ${tokens.line}`, marginBottom: 16 }}>
        <nav aria-label="Sezioni">
          <NavLink to="/" end style={link}><strong>Geminup</strong></NavLink>
          <NavLink to="/catalogo/categorie" style={link}>Categorie</NavLink>
          <NavLink to="/catalogo/milestone" style={link}>Milestone</NavLink>
          <NavLink to="/catalogo/dati" style={link}>Dati</NavLink>
        </nav>
        <button onClick={() => signOut()}>Esci</button>
      </header>
      <Outlet />
    </div>
  );
}
