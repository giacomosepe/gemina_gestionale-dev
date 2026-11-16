export const pageStyle = { fontFamily: "system-ui, sans-serif", maxWidth: 520, margin: "18vh auto", padding: "0 16px" } as const;

// Styling tokens and the few shared styles of the app (one place to change the look; a redesign starts here).
export const tokens = { ink: "#1a1a1a", muted: "#666", line: "#e2e2e2", accent: "#1f4fd8", danger: "#b3261e", surface: "#fafafa" } as const;
export const contentStyle = { fontFamily: "system-ui, sans-serif", maxWidth: 920, margin: "0 auto", padding: "16px", color: tokens.ink } as const;
export const tableStyle = { width: "100%", borderCollapse: "collapse" } as const;
export const cellStyle = { textAlign: "left", padding: "8px 6px", borderBottom: `1px solid ${tokens.line}`, verticalAlign: "top" } as const;
export const mutedStyle = { color: tokens.muted, fontSize: 14 } as const;
export const errorStyle = { color: tokens.danger } as const;
export const rowActionsStyle = { display: "flex", gap: 6, flexWrap: "wrap" } as const;
export const fieldStyle = { display: "grid", gap: 4, marginBottom: 10 } as const;
export const inputStyle = { padding: "6px 8px", border: `1px solid ${tokens.line}`, borderRadius: 6, font: "inherit" } as const;
