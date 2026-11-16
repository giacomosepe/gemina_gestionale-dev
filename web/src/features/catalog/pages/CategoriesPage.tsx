import { Link } from "react-router-dom";
import { useWhoAmI } from "../../auth/hooks/useWhoAmI";
import { cellStyle, errorStyle, mutedStyle, rowActionsStyle, tableStyle } from "../../../ui/styles";
import { NameForm } from "../components/NameForm";
import { ReorderButtons } from "../components/ReorderButtons";
import { useCategories, useDeleteCategory, useMoveCategory, useSaveCategory } from "../hooks/useCatalog";

export function CategoriesPage() {
  const list = useCategories();
  const save = useSaveCategory();
  const move = useMoveCategory();
  const remove = useDeleteCategory();
  const canEdit = useWhoAmI().data?.staffRole === "admin";
  const busy = save.isPending || move.isPending || remove.isPending;
  const error = save.error?.message ?? move.error?.message ?? remove.error?.message;
  const categories = list.data?.categories ?? [];

  return (
    <main>
      <h1>Categorie dei servizi</h1>
      {list.isPending && <p>Caricamento…</p>}
      {list.isError && <p role="alert" style={errorStyle}>{list.error.message}</p>}
      {error && <p role="alert" style={errorStyle}>{error}</p>}
      <table style={tableStyle}>
        <thead><tr><th style={cellStyle}>Nome</th><th style={cellStyle}>Servizi</th><th style={cellStyle}>Stato</th>{canEdit && <th style={cellStyle}></th>}</tr></thead>
        <tbody>
          {categories.map((c, i) => (
            <tr key={c.id}>
              <td style={cellStyle}><Link to={`/catalogo/categorie/${c.id}`}>{c.name}</Link></td>
              <td style={cellStyle}>{c.active_services} attivi su {c.services}</td>
              <td style={cellStyle}>{c.active ? "Attiva" : <span style={mutedStyle}>Archiviata</span>}</td>
              {canEdit && (
                <td style={cellStyle}><div style={rowActionsStyle}>
                  <ReorderButtons first={i === 0} last={i === categories.length - 1} disabled={busy} onMove={(direction) => move.mutate({ id: c.id, direction })} />
                  <button disabled={busy} onClick={() => save.mutate({ id: c.id, active: !c.active })}>{c.active ? "Archivia" : "Ripristina"}</button>
                  <button disabled={busy} onClick={() => { if (confirm(`Eliminare la categoria “${c.name}”?`)) remove.mutate({ id: c.id }); }}>Elimina</button>
                </div></td>
              )}
            </tr>
          ))}
        </tbody>
      </table>
      {canEdit
        ? <NameForm label="Nuova categoria" button="Aggiungi" pending={busy} onSubmit={(name) => save.mutateAsync({ name })} />
        : <p style={mutedStyle}>Solo gli amministratori modificano il catalogo.</p>}
    </main>
  );
}
