// Pulls every table and link table of the Zite database into one JSON file each, in the layout the import runner reads (source.ts).
//   ZITE_API_KEY=... deno run --allow-net=tables.zite.com --allow-env=ZITE_API_KEY --allow-write supabase/import/export_zite.ts --database <id> --out <folder>
// The key comes from Zite > Settings > Developer. The folder must be OUTSIDE this repo (real data, CLAUDE.md rule 6). Read-only: only GET schema and SELECT queries.
import { parseArgs } from "node:util";
import { resolve, sep } from "node:path";

const BASE = "https://tables.zite.com/api/v1";
const PAGE = 2000;
type Fetch = (url: string, init?: RequestInit) => Promise<Response>;
interface Schema { tables: { name: string }[]; linkTables: { name: string; sourceTableIdColumn: string; targetTableIdColumn: string }[] }

const q = (name: string) => `"${name.replaceAll('"', '""')}"`;

async function call<T>(f: Fetch, key: string, path: string, body?: unknown): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    const res = await f(`${BASE}${path}`, {
      method: body ? "POST" : "GET",
      headers: { authorization: `Bearer ${key}`, ...(body ? { "content-type": "application/json" } : {}) },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    if (res.status === 429 && attempt < 5) { await new Promise((r) => setTimeout(r, Number(res.headers.get("retry-after") ?? 1) * 1000)); continue; }
    if (!res.ok) throw new Error(`Zite ${path}: ${res.status} ${(await res.text()).slice(0, 200)}`);
    return await res.json() as T;
  }
}

/** All rows of one SELECT, paged so that nothing is lost past the 2000-row cap. */
export async function selectAll(f: Fetch, key: string, database: string, sql: (limit: number, offset: number) => string): Promise<Record<string, unknown>[]> {
  const rows: Record<string, unknown>[] = [];
  for (let offset = 0; ; offset += PAGE) {
    const r = await call<{ rows: Record<string, unknown>[] }>(f, key, `/bases/${database}/sql`, { sql: sql(PAGE, offset), statementTimeoutMs: 60000 });
    rows.push(...r.rows);
    if (r.rows.length < PAGE) return rows;
  }
}

export async function exportAll(f: Fetch, key: string, database: string, write: (name: string, rows: unknown[]) => Promise<void>): Promise<Record<string, number>> {
  const schema = await call<Schema>(f, key, `/bases/${database}/sql/schema?includeFields=false`);
  const counts: Record<string, number> = {};
  for (const t of schema.tables) {
    const rows = await selectAll(f, key, database, (l, o) => `select * from ${q(t.name)} order by id limit ${l} offset ${o}`);
    await write(t.name, rows); counts[t.name] = rows.length;
  }
  for (const l of schema.linkTables) {
    const rows = await selectAll(f, key, database, (lim, o) => `select ${q(l.sourceTableIdColumn)}, ${q(l.targetTableIdColumn)} from ${q(l.name)} order by ${q(l.sourceTableIdColumn)}, ${q(l.targetTableIdColumn)} limit ${lim} offset ${o}`);
    await write(l.name, rows); counts[l.name] = rows.length;
  }
  return counts;
}

if (import.meta.main) {
  const { values } = parseArgs({ options: { database: { type: "string" }, out: { type: "string" } } });
  const key = Deno.env.get("ZITE_API_KEY");
  if (!values.database || !values.out || !key) { console.error("usage: see the header (--database, --out and ZITE_API_KEY are required)"); Deno.exit(2); }
  const repoRoot = resolve(import.meta.dirname!, "..", "..");
  if ((resolve(values.out) + sep).startsWith(repoRoot + sep)) { console.error("refused: the output folder is inside the repository; real data must stay outside it"); Deno.exit(2); }
  await Deno.mkdir(values.out, { recursive: true });
  const counts = await exportAll(fetch, key, values.database, (name, rows) => {
    if (name.includes("/") || name.includes("..")) throw new Error(`bad table name: ${name}`);
    return Deno.writeTextFile(`${values.out}/${name}.json`, JSON.stringify(rows));
  });
  const total = Object.values(counts).reduce((a, b) => a + b, 0);
  console.log(`exported ${Object.keys(counts).length} tables, ${total} rows, to ${values.out}`);
  console.log(Object.entries(counts).map(([k, v]) => `${k}: ${v}`).join("\n"));
}
