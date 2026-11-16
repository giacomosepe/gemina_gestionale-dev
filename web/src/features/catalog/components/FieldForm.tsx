// Adds an information field to a category (what its cases are asked). The server checks the rules; its Italian message is shown.
import { useState } from "react";
import { errorStyle, fieldStyle, inputStyle } from "../../../ui/styles";
import { useSaveField } from "../hooks/useCatalog";
import { FIELD_TYPE_LABELS } from "../logic/labels";

const empty = { label: "", field_type: "text", options: "", required: false };

export function FieldForm({ categoryId }: { categoryId: string }) {
  const save = useSaveField(categoryId);
  const [form, setForm] = useState(empty);
  return (
    <form style={{ marginTop: 16, maxWidth: 520 }} onSubmit={(e) => { e.preventDefault(); save.mutate({ ...form, options: form.options || null }, { onSuccess: () => setForm(empty) }); }}>
      <h3>Nuovo campo</h3>
      <label style={fieldStyle}>Nome<input style={inputStyle} value={form.label} onChange={(e) => setForm({ ...form, label: e.target.value })} /></label>
      <label style={fieldStyle}>Tipo
        <select style={inputStyle} value={form.field_type} onChange={(e) => setForm({ ...form, field_type: e.target.value })}>
          {Object.entries(FIELD_TYPE_LABELS).map(([code, label]) => <option key={code} value={code}>{label}</option>)}
        </select>
      </label>
      {(form.field_type === "choice" || form.field_type === "multi_choice") && (
        <label style={fieldStyle}>Opzioni (una per riga)<textarea style={inputStyle} rows={3} value={form.options} onChange={(e) => setForm({ ...form, options: e.target.value })} /></label>
      )}
      <label style={{ display: "block", marginBottom: 10 }}><input type="checkbox" checked={form.required} onChange={(e) => setForm({ ...form, required: e.target.checked })} /> Obbligatorio</label>
      <button type="submit" disabled={save.isPending || !form.label.trim()}>Aggiungi campo</button>
      {save.isError && <p role="alert" style={errorStyle}>{save.error.message}</p>}
    </form>
  );
}
