// Against a real database (TEST_DB_URL + PGPASSWORD, in the staging workflow): temporary tables inside one transaction that is rolled back.
import assert from "node:assert/strict";
import { runImport } from "./engine.ts";
import { inTransaction } from "./pg_sink.ts";
import { MemorySource } from "./source.ts";
import type { Step } from "./types.ts";

const URL = Deno.env.get("TEST_DB_URL");

Deno.test({ name: "PgSink: inserts in one transaction, resolves links, rolls back as a whole", ignore: !URL, sanitizeOps: false, sanitizeResources: false, async fn() {
  const steps: Step[] = [
    { name: "parents", source: "P", table: "import_test_parents", map: (r) => ({ name: r.name }) },
    { name: "children", source: "C", table: "import_test_children", map: (r) => ({ name: r.name }),
      foreignKeys: [{ linkTable: "P__C", fromColumn: "cId", toColumn: "pId", toStep: "parents", column: "parent_id", required: true }] },
  ];
  const source = new MemorySource({
    P: [{ id: "p1", name: "Uno" }, { id: "p2", name: "Due" }],
    C: [{ id: "c1", name: "Figlio" }],
    P__C: [{ cId: "c1", pId: "p2" }],
  });
  const result = await inTransaction(URL!, async (sink, tx) => {
    await tx`create temp table import_test_parents (id uuid primary key, legacy_id text not null, name text)`;
    await tx`create temp table import_test_children (id uuid primary key, legacy_id text not null, name text, parent_id uuid references import_test_parents(id))`;
    const report = await runImport(steps, source, sink);
    const [row] = await tx`select c.legacy_id, p.legacy_id as parent from import_test_children c join import_test_parents p on p.id = c.parent_id`;
    return { report, row };
  }, true);
  assert.equal(result.report.ok, true, result.report.problems.join());
  assert.deepEqual({ ...result.row }, { legacy_id: "c1", parent: "p2" });
}});
