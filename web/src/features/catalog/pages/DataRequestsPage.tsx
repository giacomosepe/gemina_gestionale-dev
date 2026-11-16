import { useMemo, useState } from "react";
import { useWhoAmI } from "../../auth/hooks/useWhoAmI";
import { cellStyle, errorStyle, mutedStyle, tableStyle } from "../../../ui/styles";
import { DataRequestForm } from "../components/DataRequestForm";
import { useArchiveDataRequest, useDataRequests } from "../hooks/useCatalog";
import { DATA_TYPE_LABELS, savedOn } from "../logic/labels";

export function DataRequestsPage() {
  const list = useDataRequests();
  const archive = useArchiveDataRequest();
  const canEdit = useWhoAmI().data?.staffRole === "admin";
  const [search, setSearch] = useState("");
  const [showArchived, setShowArchived] = useState(false);
  const rows = useMemo(
    () => (list.data?.data_requests ?? []).filter((d) => (showArchived || !d.archived) && d.name.toLowerCase().includes(search.trim().toLowerCase())),
    [list.data, search, showArchived],
  );

  return (
    <main>
      <h1>Dati da raccogliere</h1>
      <div style={{ display: "flex", gap: 12, alignItems: "center", flexWrap: "wrap", margin: "8px 0" }}>
        <input aria-label="Cerca un dato" placeholder="Cerca…" value={search} onChange={(e) => setSearch(e.target.value)} />
        <label><input type="checkbox" checked={showArchived} onChange={(e) => setShowArchived(e.target.checked)} /> Mostra archiviati</label>
        <span style={mutedStyle}>{rows.length} dati</span>
      </div>
      {list.isPending && <p>Caricamento…</p>}
      {list.isError && <p role="alert" style={errorStyle}>{list.error.message}</p>}
      {archive.isError && <p role="alert" style={errorStyle}>{archive.error.message}</p>}
      <table style={tableStyle}>
        <thead><tr><th style={cellStyle}>Nome</th><th style={cellStyle}>Tipo</th><th style={cellStyle}>Si salva su</th><th style={cellStyle}>Usato in</th>{canEdit && <th style={cellStyle}></th>}</tr></thead>
        <tbody>
          {rows.map((d) => (
            <tr key={d.id}>
              <td style={cellStyle}>{d.name}{d.archived && <span style={mutedStyle}> (archiviato)</span>}</td>
              <td style={cellStyle}>{DATA_TYPE_LABELS[d.data_type ?? ""] ?? "—"}</td>
              <td style={cellStyle}>{savedOn(d) || "—"}</td>
              <td style={cellStyle}>{d.used_in.length ? d.used_in.join(", ") : <span style={mutedStyle}>mai</span>}</td>
              {canEdit && <td style={cellStyle}><button disabled={archive.isPending} onClick={() => archive.mutate({ id: d.id, archived: !d.archived })}>{d.archived ? "Ripristina" : "Archivia"}</button></td>}
            </tr>
          ))}
        </tbody>
      </table>
      {canEdit && <DataRequestForm />}
    </main>
  );
}
