// Who may receive an email. Outside production an email goes only to an address on the allowlist (CLAUDE.md rule 6).
export function parseAllowlist(raw: string | undefined): Set<string> {
  return new Set((raw ?? "").split(",").map((e) => e.trim().toLowerCase()).filter(Boolean));
}

export function recipientAllowed(to: string, live: boolean, allowlist: Set<string>): boolean {
  return live || allowlist.has(to.trim().toLowerCase());
}
