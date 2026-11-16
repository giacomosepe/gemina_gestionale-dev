// Adds a data request to the catalogue. The server checks the rules (where it is saved, options…) and its Italian message is shown.
import { useState } from "react";
import { errorStyle, fieldStyle, inputStyle } from "../../../ui/styles";
import { useSaveDataRequest } from "../hooks/useCatalog";
import { DATA_TYPE_LABELS } from "../logic/labels";

const empty = { name: "", data_type: "text", save_on_company: false, save_on_contact: false, save_on_deal: false, save_on_case: true, required_by_default: false, options: "" };

export function DataRequestForm() {
  const save = useSaveDataRequest();
  const [form, setForm] = useState(empty);
  const set = <K extends keyof typeof empty>(key: K, value: (typeof empty)[K]) => setForm((f) => ({ ...f, [key]: value }));
  const check = (key: "save_on_company" | "save_on_contact" | "save_on_deal" | "save_on_case" | "required_by_default", label: string) => (
    <label style={{ marginRight: 12 }}><input type="checkbox" checked={form[key]} onChange={(e) => set(key, e.target.checked)} /> {label}</label>
  );
  return (
    <form style={{ marginTop: 24, maxWidth: 520 }} onSubmit={(e) => { e.preventDefault(); save.mutate({ ...form, options: form.options || null }, { onSuccess: () => setForm(empty) }); }}>
      <h2>Nuovo dato</h2>
      <label style={fieldStyle}>Nome<input style={inputStyle} value={form.name} onChange={(e) => set("name", e.target.value)} /></label>
      <label style={fieldStyle}>Tipo
        <select style={inputStyle} value={form.data_type} onChange={(e) => set("data_type", e.target.value)}>
          {Object.entries(DATA_TYPE_LABELS).map(([code, label]) => <option key={code} value={code}>{label}</option>)}
        </select>
      </label>
      {(form.data_type === "choice" || form.data_type === "multi_choice") && (
        <label style={fieldStyle}>Opzioni (una per riga)<textarea style={inputStyle} rows={3} value={form.options} onChange={(e) => set("options", e.target.value)} /></label>
      )}
      <fieldset style={{ marginBottom: 10 }}><legend>Si salva su</legend>
        {check("save_on_company", "Azienda")}{check("save_on_contact", "Contatto")}{check("save_on_deal", "Trattativa")}{check("save_on_case", "Pratica")}
      </fieldset>
      <div style={{ marginBottom: 10 }}>{check("required_by_default", "Obbligatorio di partenza")}</div>
      <button type="submit" disabled={save.isPending || !form.name.trim()}>Aggiungi dato</button>
      {save.isError && <p role="alert" style={errorStyle}>{save.error.message}</p>}
    </form>
  );
}
