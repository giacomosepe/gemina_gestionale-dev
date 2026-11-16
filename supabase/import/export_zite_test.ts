import assert from "node:assert/strict";
import { exportAll, selectAll } from "./export_zite.ts";

// A fake Zite: two tables (one with 4500 made-up rows to force paging) and one link table.
function fakeZite(): (url: string, init?: RequestInit) => Promise<Response> {
  return (url, init) => {
    const json = (b: unknown) => Promise.resolve(new Response(JSON.stringify(b), { status: 200 }));
    if (url.endsWith("/sql/schema?includeFields=false")) return json({ tables: [{ name: "Big" }, { name: "Small" }], linkTables: [{ name: "Big__Small", sourceTableIdColumn: "bigId", targetTableIdColumn: "smallId" }] });
    const { sql } = JSON.parse(String(init!.body)) as { sql: string };
    const [, limit, offset] = sql.match(/limit (\d+) offset (\d+)/)!;
    const total = sql.includes('from "Big" ') ? 4500 : sql.includes('from "Small" ') ? 2 : 3;
    const rows = Array.from({ length: Math.max(0, Math.min(Number(limit), total - Number(offset))) }, (_, i) => ({ id: `r${Number(offset) + i}` }));
    return json({ rows, rowCount: rows.length, truncated: false });
  };
}

Deno.test("pages past the 2000-row cap and writes one file per table and link table", async () => {
  const written: Record<string, number> = {};
  const counts = await exportAll(fakeZite(), "k", "db", (n, rows) => { written[n] = rows.length; return Promise.resolve(); });
  assert.deepEqual(counts, { Big: 4500, Small: 2, Big__Small: 3 });
  assert.deepEqual(written, counts);
});

Deno.test("an error from Zite stops the export", async () => {
  const f = () => Promise.resolve(new Response("nope", { status: 401 }));
  await assert.rejects(selectAll(f, "bad", "db", () => "select 1"), /401/);
});
