import { Link, useParams } from "react-router-dom";
import { useWhoAmI } from "../../auth/hooks/useWhoAmI";
import { cellStyle, errorStyle, mutedStyle, rowActionsStyle, tableStyle } from "../../../ui/styles";
import { FieldForm } from "../components/FieldForm";
import { ReorderButtons } from "../components/ReorderButtons";
import { useCategories, useCategoryFields, useMoveField, useSetFieldActive } from "../hooks/useCatalog";
import { FIELD_TYPE_LABELS } from "../logic/labels";

export function CategoryPage() {
  const { id = "" } = useParams();
  const categories = useCategories();
  const fields = useCategoryFields(id);
  const setActive = useSetFieldActive(id);
  const move = useMoveField(id);
  const canEdit = useWhoAmI().data?.staffRole === "admin";
  const category = categories.data?.categories.find((c) => c.id === id);
  const rows = fields.data?.fields ?? [];
  const busy = setActive.isPending || move.isPending;
  const error = setActive.error?.message ?? move.error?.message;

  return (
    <main>
      <p><Link to="/catalogo/categorie">← Categorie</Link></p>
      <h1>{category?.name ?? "Categoria"}</h1>
      <h2>Campi che la categoria chiede alle pratiche</h2>
      {fields.isPending && <p>Caricamento…</p>}
      {fields.isError && <p role="alert" style={errorStyle}>{fields.error.message}</p>}
      {error && <p role="alert" style={errorStyle}>{error}</p>}
      {fields.isSuccess && rows.length === 0 && <p style={mutedStyle}>Nessun campo.</p>}
      {rows.length > 0 && (
        <table style={tableStyle}>
          <thead><tr><th style={cellStyle}>Nome</th><th style={cellStyle}>Tipo</th><th style={cellStyle}>Obbligatorio</th><th style={cellStyle}>Stato</th>{canEdit && <th style={cellStyle}></th>}</tr></thead>
          <tbody>
            {rows.map((f, i) => (
              <tr key={f.id}>
                <td style={cellStyle}>{f.label}</td>
                <td style={cellStyle}>{FIELD_TYPE_LABELS[f.field_type ?? ""] ?? "—"}</td>
                <td style={cellStyle}>{f.required ? "Sì" : "No"}</td>
                <td style={cellStyle}>{f.active ? "Attivo" : <span style={mutedStyle}>Archiviato</span>}</td>
                {canEdit && (
                  <td style={cellStyle}><div style={rowActionsStyle}>
                    <ReorderButtons first={i === 0} last={i === rows.length - 1} disabled={busy} onMove={(direction) => move.mutate({ id: f.id, direction })} />
                    <button disabled={busy} onClick={() => setActive.mutate({ id: f.id, active: !f.active })}>{f.active ? "Archivia" : "Ripristina"}</button>
                  </div></td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {canEdit && <FieldForm categoryId={id} />}
    </main>
  );
}
