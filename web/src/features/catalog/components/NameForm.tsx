// One text box and a button: add a category or a milestone. The server checks the name; its Italian message is shown as it is.
import { useState } from "react";
import { errorStyle, inputStyle } from "../../../ui/styles";

export function NameForm({ label, button, onSubmit, pending, error }: { label: string; button: string; onSubmit: (name: string) => Promise<unknown>; pending: boolean; error?: string }) {
  const [name, setName] = useState("");
  return (
    <form style={{ display: "flex", gap: 8, margin: "12px 0", alignItems: "center", flexWrap: "wrap" }}
      onSubmit={(e) => { e.preventDefault(); onSubmit(name).then(() => setName(""), () => {}); }}>
      <label>{label} <input style={inputStyle} value={name} onChange={(e) => setName(e.target.value)} /></label>
      <button type="submit" disabled={pending || !name.trim()}>{button}</button>
      {error && <span role="alert" style={errorStyle}>{error}</span>}
    </form>
  );
}
