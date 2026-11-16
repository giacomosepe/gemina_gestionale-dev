import { useState } from "react";
import { useWhoAmI } from "../../auth/hooks/useWhoAmI";
import { cellStyle, errorStyle, inputStyle, mutedStyle, rowActionsStyle, tableStyle } from "../../../ui/styles";
import { NameForm } from "../components/NameForm";
import { ReorderButtons } from "../components/ReorderButtons";
import { useMilestones, useMoveMilestone, useSaveMilestone, useSetMilestoneActive } from "../hooks/useCatalog";
import type { Milestone } from "../logic/types";

function DaysCell({ m, canEdit, onSave }: { m: Milestone; canEdit: boolean; onSave: (days: number | null) => void }) {
  const [value, setValue] = useState(m.days?.toString() ?? "");
  if (!canEdit) return <>{m.days ?? "—"}</>;
  const commit = () => { const n = value.trim() === "" ? null : Number(value); if (n !== m.days) onSave(Number.isNaN(n) ? null : n); };
  return <input aria-label={`Giorni di ${m.name}`} style={{ ...inputStyle, width: 70 }} inputMode="numeric" value={value} onChange={(e) => setValue(e.target.value)} onBlur={commit} />;
}

export function MilestonesPage() {
  const list = useMilestones();
  const save = useSaveMilestone();
  const setActive = useSetMilestoneActive();
  const move = useMoveMilestone();
  const canEdit = useWhoAmI().data?.staffRole === "admin";
  const busy = save.isPending || setActive.isPending || move.isPending;
  const error = save.error?.message ?? setActive.error?.message ?? move.error?.message;
  const milestones = list.data?.milestones ?? [];

  return (
    <main>
      <h1>Milestone</h1>
      <p style={mutedStyle}>Le fasi di lavoro delle pratiche. «Giorni» = scadenza predefinita dalla creazione della pratica.</p>
      {list.isPending && <p>Caricamento…</p>}
      {list.isError && <p role="alert" style={errorStyle}>{list.error.message}</p>}
      {error && <p role="alert" style={errorStyle}>{error}</p>}
      <table style={tableStyle}>
        <thead><tr><th style={cellStyle}>Nome</th><th style={cellStyle}>Giorni</th><th style={cellStyle}>Stato</th>{canEdit && <th style={cellStyle}></th>}</tr></thead>
        <tbody>
          {milestones.map((m, i) => (
            <tr key={m.id}>
              <td style={cellStyle}>{m.name}</td>
              <td style={cellStyle}><DaysCell key={`${m.id}-${m.days}`} m={m} canEdit={canEdit} onSave={(days) => save.mutate({ id: m.id, name: m.name, days })} /></td>
              <td style={cellStyle}>{m.active ? "Attiva" : <span style={mutedStyle}>Archiviata</span>}</td>
              {canEdit && (
                <td style={cellStyle}><div style={rowActionsStyle}>
                  <ReorderButtons first={i === 0} last={i === milestones.length - 1} disabled={busy} onMove={(direction) => move.mutate({ id: m.id, direction })} />
                  <button disabled={busy} onClick={() => setActive.mutate({ id: m.id, active: !m.active })}>{m.active ? "Archivia" : "Ripristina"}</button>
                </div></td>
              )}
            </tr>
          ))}
        </tbody>
      </table>
      {canEdit && <NameForm label="Nuova milestone" button="Aggiungi" pending={busy} onSubmit={(name) => save.mutateAsync({ name })} />}
    </main>
  );
}
