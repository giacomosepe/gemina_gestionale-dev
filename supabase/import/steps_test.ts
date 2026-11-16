// The catalogue steps against made-up rows in the shape Zite's SQL API returns.
import assert from "node:assert/strict";
import { runImport } from "./engine.ts";
import { MemorySource } from "./source.ts";
import { steps } from "./steps.ts";
import type { Row, Sink } from "./types.ts";

class MemorySink implements Sink {
  tables: Record<string, Row[]> = {};
  count(t: string) { return Promise.resolve(this.tables[t]?.length ?? 0); }
  insert(t: string, rows: Row[]) { this.tables[t] = [...(this.tables[t] ?? []), ...rows]; return Promise.resolve(); }
}

const fixture = (over: Record<string, Row[]> = {}) => new MemorySource({
  Categorie: [{ id: "cat1", nome: "Test category", ordine: 1, attivo: true, macroCategoria: "Valutativi", scadenzeModello: '[{"chiave":"dom","nome":"Domanda"}]', milestoneAttive: '[{"m":"mil1"}]', attivitaAttive: "[]", outputModello: null }],
  Strumenti: [{
    id: "svc1", nome: "Test service", attivo: true, Tipo: "Bando", Stato: "In arrivo", Procedura: "Autodichiarazione (nel modello F24)", "Dotazione (€)": "1500.50",
    "Tipo agevolazione": ["Fondo perduto"], Beneficiari: '["Imprese"]', Apertura: "2026-03-01T00:00:00.000Z", Revisionato: false,
  }],
  Dati: [{ id: "dat1", nome: "Test data", tipo: "Sì / No", genere: "Temporaneo", validita: "Fino a scadenza", salvaSuPratica: true, colonna: "progetto.dataEsito" }],
  "Campi strumento": [{ id: "fld1", etichetta: "Test field", tipo: "euro", obbligoPratica: "Obbligatorio", inScadenze: '["dom"]', perScadenza: true }],
  "Fasi di attivita": [{ id: "mil1", nome: "Test milestone", ordine: 2, giorni: 7 }],
  "Attivita modello": [{ id: "tpl1", titolo: "Test template", responsabile: "team", tipo: "Chiamata" }],
  "Attivita standard": [{ id: "std1", titolo: "Test standard", responsabile: "team" }],
  Opzioni: [{ id: "opt1", campo: "procedura", valore: "Sportello", ordine: 1, attivo: true }],
  Categorie__Strumenti: [{ strumentiId: "svc1", categorieId: "cat1" }],
  "Campi strumento__Categorie": [{ "campi strumentoId": "fld1", categorieId: "cat1" }],
  "Campi strumento__Strumenti": [],
  "Campi strumento__Dati": [{ "campi strumentoId": "fld1", datiId: "dat1" }],
  "Categorie__Fasi di attivita": [{ "fasi di attivitaId": "mil1", categorieId: "cat1" }],
  "Attivita modello__Categorie": [{ "attivita modelloId": "tpl1", categorieId: "cat1" }],
  "Attivita modello__Strumenti": [],
  "Attivita modello__Fasi di attivita": [{ "attivita modelloId": "tpl1", "fasi di attivitaId": "mil1" }],
  "Attivita standard__Fasi di attivita": [{ "attivita standardId": "std1", "fasi di attivitaId": "mil1" }],
  ...over,
});

Deno.test("catalogue: every step loads, links resolve, Italian values become codes", async () => {
  const sink = new MemorySink();
  const r = await runImport(steps, fixture(), sink);
  assert.equal(r.ok, true, r.problems.join("; "));
  const svc = sink.tables.services[0];
  assert.equal(svc.kind, "grant_call");
  assert.equal(svc.status, "upcoming");
  assert.equal(svc.budget_cents, 150050);
  assert.equal(svc.opens_on, "2026-03-01");
  assert.deepEqual(svc.benefit_types, ["Fondo perduto"]);
  assert.deepEqual(svc.beneficiaries, ["Imprese"]);
  assert.equal(svc.procedure, "Autodichiarazione (nel modello F24)");   // a label, kept as data
  assert.equal(svc.category_id, sink.tables.service_categories[0].id);
  const dr = sink.tables.data_requests[0];
  assert.deepEqual([dr.data_type, dr.lifetime, dr.validity, dr.save_on_case, dr.legacy_target_column], ["yes_no", "temporary", "until_deadline", true, "progetto.dataEsito"]);
  const f = sink.tables.service_fields[0];
  assert.deepEqual([f.field_type, f.required_on_case, f.required_on_deal, f.per_deadline], ["money", "required", null, true]);
  assert.equal(f.data_request_id, dr.id);
  assert.equal(f.category_id, sink.tables.service_categories[0].id);
  assert.deepEqual(sink.tables.service_categories[0].deadline_templates, [{ chiave: "dom", nome: "Domanda" }]);
  assert.equal(sink.tables.activity_templates[0].milestone_id, sink.tables.milestones[0].id);
  assert.equal(sink.tables.standard_activities[0].milestone_id, sink.tables.milestones[0].id);
  assert.equal(sink.tables.lookup_options[0].kind, "procedure");
  assert.deepEqual(r.steps.map((s) => s.sourceRows === s.inserted), steps.map(() => true));
});

Deno.test("catalogue: a value without an English code stops the import", async () => {
  await assert.rejects(runImport(steps, fixture({ Strumenti: [{ id: "svc1", nome: "X", Tipo: "Concorso" }] }), new MemorySink()), /no English code for "Concorso"/);
  await assert.rejects(runImport(steps, fixture({ Categorie: [{ id: "cat1", nome: "X", scadenzeModello: "{broken" }] }), new MemorySink()), /not valid JSON/);
});

Deno.test("catalogue: a link to a record that does not exist is reported", async () => {
  const r = await runImport(steps, fixture({ Categorie__Strumenti: [{ strumentiId: "svc1", categorieId: "gone" }] }), new MemorySink());
  assert.equal(r.ok, false);
  assert.equal(r.steps.find((s) => s.name === "services")!.unresolved[0].missingId, "gone");
});
