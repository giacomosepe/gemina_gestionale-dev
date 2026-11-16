import assert from "node:assert/strict";
import { formatReport, runImport } from "./engine.ts";
import { MemorySource, parseCsv } from "./source.ts";
import type { Row, Sink, Step } from "./types.ts";

class MemorySink implements Sink {
  tables: Record<string, Row[]> = {};
  count(t: string) { return Promise.resolve(this.tables[t]?.length ?? 0); }
  insert(t: string, rows: Row[]) { this.tables[t] = [...(this.tables[t] ?? []), ...rows]; return Promise.resolve(); }
}

// Made-up data: companies, contacts (each linked to a company through a link table), tags (many-to-many with contacts).
const source = (extra: Record<string, Row[]> = {}) => new MemorySource({
  Aziende: [{ id: "a1", name: "Alfa" }, { id: "a2", name: "Beta" }],
  Contatti: [{ id: "c1", name: "Ugo", fee: "10.5" }, { id: "c2", name: "Ida", fee: "4.25" }, { id: "c3", name: "Noa", fee: "1" }],
  Aziende__Contatti: [{ contattiId: "c1", aziendeId: "a1" }, { contattiId: "c2", aziendeId: "a2" }, { contattiId: "c3", aziendeId: "a2" }],
  Etichette: [{ id: "t1", name: "vip" }],
  Contatti__Etichette: [{ contattiId: "c1", etichetteId: "t1" }, { contattiId: "c2", etichetteId: "t1" }],
  ...extra,
});

const steps: Step[] = [
  { name: "companies", source: "Aziende", table: "companies", map: (r) => ({ name: r.name }) },
  { name: "tags", source: "Etichette", table: "tags", map: (r) => ({ name: r.name }) },
  {
    name: "contacts", source: "Contatti", table: "contacts", totals: ["fee"],
    map: (r) => ({ name: r.name, fee: Number(r.fee) }),
    foreignKeys: [{ linkTable: "Aziende__Contatti", fromColumn: "contattiId", toColumn: "aziendeId", toStep: "companies", column: "company_id", required: true }],
    junctions: [{ linkTable: "Contatti__Etichette", leftColumn: "contattiId", leftStep: "contacts", leftTargetColumn: "contact_id", rightColumn: "etichetteId", rightStep: "tags", rightTargetColumn: "tag_id", table: "contact_tags" }],
  },
];
const ids = () => { let n = 0; return () => `id-${++n}`; };

Deno.test("loads in order, keeps the Zite id as legacy_id and resolves links to the new ids", async () => {
  const sink = new MemorySink();
  const r = await runImport(steps, source(), sink, ids());
  assert.equal(r.ok, true, r.problems.join());
  const company = sink.tables.companies.find((c) => c.legacy_id === "a1")!;
  const contact = sink.tables.contacts.find((c) => c.legacy_id === "c1")!;
  assert.equal(contact.company_id, company.id);
  assert.equal(sink.tables.contact_tags.length, 2);
  assert.deepEqual(r.steps.map((s) => [s.name, s.sourceRows, s.inserted]), [["companies", 2, 2], ["tags", 1, 1], ["contacts", 3, 3]]);
  assert.equal(r.steps[2].totals.fee, 15.75);
});

Deno.test("two runs on empty targets give the same report", async () => {
  const a = formatReport(await runImport(steps, source(), new MemorySink()));
  const b = formatReport(await runImport(steps, source(), new MemorySink()));
  assert.equal(a, b);
});

Deno.test("a broken link is reported, never dropped silently", async () => {
  const bad = source({ Aziende__Contatti: [{ contattiId: "c1", aziendeId: "GONE" }, { contattiId: "c2", aziendeId: "a2" }] });
  const r = await runImport(steps, bad, new MemorySink());
  assert.equal(r.ok, false);
  const contacts = r.steps.find((s) => s.name === "contacts")!;
  assert.deepEqual(contacts.unresolved.map((u) => [u.legacyId, u.missingId]), [["c1", "GONE"], ["c3", "(no link)"]]);
  assert.match(formatReport(r), /GONE/);
});

Deno.test("a junction row pointing at a missing record is reported", async () => {
  const r = await runImport(steps, source({ Contatti__Etichette: [{ contattiId: "c1", etichetteId: "nope" }] }), new MemorySink());
  assert.equal(r.ok, false);
  assert.equal(r.steps[2].unresolved[0].missingId, "nope");
});

Deno.test("refuses a target that is not empty", async () => {
  const sink = new MemorySink();
  await sink.insert("companies", [{ id: "x" }]);
  const r = await runImport(steps, source(), sink);
  assert.equal(r.ok, false);
  assert.match(r.problems[0], /companies is not empty/);
  assert.equal(sink.tables.contacts, undefined);
});

Deno.test("duplicate and missing ids and a step order that cannot work are problems", async () => {
  const dup = await runImport(steps, source({ Aziende: [{ id: "a1", name: "A" }, { id: "a1", name: "B" }, { name: "no id" }] }), new MemorySink());
  assert.equal(dup.ok, false);
  assert.ok(dup.problems.some((p) => p.includes("duplicate id a1")) && dup.problems.some((p) => p.includes("has no id")));
  const order = await runImport([steps[2], steps[0]], source(), new MemorySink());
  assert.match(order.problems[0], /does not run before it/);
});

Deno.test("more than one link on a to-one key is counted", async () => {
  const two = source({ Aziende__Contatti: [{ contattiId: "c1", aziendeId: "a1" }, { contattiId: "c1", aziendeId: "a2" }, { contattiId: "c2", aziendeId: "a2" }, { contattiId: "c3", aziendeId: "a2" }] });
  const r = await runImport(steps, two, new MemorySink());
  assert.equal(r.steps[2].multipleLinks, 1);
});

Deno.test("csv: quotes, commas, new lines inside a cell, empty cell is null", () => {
  const rows = parseCsv('id,name,note\r\nr1,"Rossi, Mario","line1\nline2"\nr2,"say ""hi""",\n');
  assert.deepEqual(rows, [{ id: "r1", name: "Rossi, Mario", note: "line1\nline2" }, { id: "r2", name: 'say "hi"', note: null }]);
});
