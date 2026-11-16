// Reads a Zite export from a folder: one file per table, `<Table name>.json` (an array of objects) or `<Table name>.csv` (header row).
// The folder is outside the repo. If the real export uses another layout, only this file changes.
import type { Row, Source } from "./types.ts";

export function parseCsv(text: string): Row[] {
  const rows: string[][] = [];
  let row: string[] = [], cell = "", quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') { cell += '"'; i++; }
      else if (c === '"') quoted = false;
      else cell += c;
    } else if (c === '"') quoted = true;
    else if (c === ",") { row.push(cell); cell = ""; }
    else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++;
      row.push(cell); cell = ""; rows.push(row); row = [];
    } else cell += c;
  }
  if (cell !== "" || row.length) { row.push(cell); rows.push(row); }
  const [header, ...body] = rows.filter((r) => r.length > 1 || r[0] !== "");
  if (!header) return [];
  return body.map((r) => Object.fromEntries(header.map((h, i) => [h, r[i] === "" ? null : r[i]])));
}

export class DirectorySource implements Source {
  constructor(private dir: string) {}
  async read(table: string): Promise<Row[]> {
    if (table.includes("/") || table.includes("..")) throw new Error(`bad table name: ${table}`);
    for (const ext of ["json", "csv"]) {
      const path = `${this.dir}/${table}.${ext}`;
      try {
        const text = await Deno.readTextFile(path);
        return ext === "json" ? JSON.parse(text) as Row[] : parseCsv(text);
      } catch (e) {
        if (!(e instanceof Deno.errors.NotFound)) throw new Error(`cannot read ${path}: ${(e as Error).message}`);
      }
    }
    throw new Error(`the export has no file for "${table}" (${this.dir}/${table}.json or .csv)`);
  }
}

export class MemorySource implements Source {
  constructor(private tables: Record<string, Row[]>) {}
  read(table: string): Promise<Row[]> {
    if (!(table in this.tables)) return Promise.reject(new Error(`no table "${table}" in the source`));
    return Promise.resolve(this.tables[table]);
  }
}
