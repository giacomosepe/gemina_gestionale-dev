// The import steps, in dependency order. Each domain adds its own here when its schema exists. A step maps one Zite table to one new table;
// its Zite id goes to `legacy_id`. The value maps below are the one place where Italian Zite values become the English codes of the new schema.
import type { Row, Step } from "./types.ts";

const text = (v: unknown): string | null => (v === null || v === undefined || v === "" ? null : String(v));
const bool = (v: unknown): boolean => v === true || v === "true";
const num = (v: unknown): number | null => (v === null || v === undefined || v === "" ? null : Number(v));
const cents = (v: unknown): number | null => (num(v) === null ? null : Math.round(num(v)! * 100));
const date = (v: unknown): string | null => (text(v) === null ? null : String(v).slice(0, 10));

/** Zite long-text columns that hold JSON: a value that is not valid JSON stops the import (it is reported, never dropped). */
function json(v: unknown, where: string): unknown {
  if (v === null || v === undefined || v === "") return null;
  if (typeof v !== "string") return v;
  try { return JSON.parse(v); } catch { throw new Error(`${where}: not valid JSON`); }
}

/** An Italian value to an English code; a value that is not in the map stops the import. */
function code(map: Record<string, string>, what: string) {
  return (v: unknown): string | null => {
    if (v === null || v === undefined || v === "") return null;
    const out = map[String(v)];
    if (!out) throw new Error(`${what}: no English code for "${v}"`);
    return out;
  };
}
const list = (v: unknown): string[] => {
  const parsed = typeof v === "string" ? JSON.parse(v) : v;
  return Array.isArray(parsed) ? parsed.map(String) : [];
};

const kind = code({ "Bando": "grant_call", "Agevolazione fiscale": "tax_incentive" }, "services.kind");
const status = code({ "In arrivo": "upcoming", "Aperto": "open", "Chiuso": "closed" }, "services.status");
const dataType = code({ "Numero": "number", "Testo": "text", "Data": "date", "Sì / No": "yes_no", "Scelta": "choice", "Euro": "money", "Documento": "document", "Scelta multipla": "multi_choice", "Persona": "person" }, "data_requests.data_type");
const lifetime = code({ "Permanente": "permanent", "Temporaneo": "temporary" }, "data_requests.lifetime");
const validity = code({ "Nessuna": "none", "Mesi": "months", "Fino a scadenza": "until_deadline", "Fino al prossimo": "until_next" }, "data_requests.validity");
const fieldType = code({ "data": "date", "scelta": "choice", "multi": "multi_choice", "euro": "money", "testo": "text", "numero": "number" }, "service_fields.field_type");
const obligation = code({ "Obbligatorio": "required", "Opzionale": "optional" }, "service_fields.required_on_*");
const optionKind = code({ "procedura": "procedure", "regimeDiAiuto": "aid_regime", "tipoAgevolazione": "benefit_type" }, "lookup_options.kind");

const rel = (linkTable: string, fromColumn: string, toColumn: string, toStep: string, column: string) => ({ linkTable, fromColumn, toColumn, toStep, column });

export const steps: Step[] = [
  {
    name: "service_categories", source: "Categorie", table: "service_categories",
    map: (r: Row) => ({
      name: text(r.nome) ?? "(no name)", position: num(r.ordine) ?? 0, active: r.attivo === null ? true : bool(r.attivo),
      macro_category: text(r.macroCategoria), standard_terms: text(r["Condizioni standard"]), required_documents: text(r["Documenti richiesti"]),
      deadline_templates: json(r.scadenzeModello, "Categorie.scadenzeModello"), output_template: json(r.outputModello, "Categorie.outputModello"),
      legacy_active_milestones: json(r.milestoneAttive, "Categorie.milestoneAttive"), legacy_active_activities: json(r.attivitaAttive, "Categorie.attivitaAttive"),
    }),
  },
  {
    name: "services", source: "Strumenti", table: "services",
    map: (r: Row) => ({
      name: text(r.nome) ?? "(no name)", short_name: text(r.nomeBreve), kind: kind(r.Tipo), status: status(r.Stato),
      active: r.attivo === null ? true : bool(r.attivo), position: num(r.ordine) ?? 0,
      authority: text(r.Ente), managing_body: text(r["Soggetto gestore"]), info_url: text(r.Link), call_document_url: text(r["Documento bando"]),
      opens_on: date(r.Apertura), closes_on: date(r.Scadenza), procedure: text(r.Procedura), aid_regime: text(r["Regime di aiuto"]),
      benefit_types: list(r["Tipo agevolazione"]), budget_cents: cents(r["Dotazione (€)"]), max_intensity_pct: num(r["Intensità max (%)"]),
      max_contribution_cents: cents(r["Contributo max (€)"]), min_expense_cents: cents(r["Spesa min (€)"]), max_expense_cents: cents(r["Spesa max (€)"]),
      beneficiaries: list(r.Beneficiari), allowed_sizes: list(r["Dimensioni ammesse"]), allowed_regions: list(r["Regioni ammesse"]),
      included_ateco: text(r["ATECO inclusi"]), excluded_ateco: text(r["ATECO esclusi"]), min_company_age_months: num(r["Anzianità minima (mesi)"]),
      special_requirements: list(r["Requisiti speciali"]), funded_expenses: list(r["Spese finanziate"]),
      cases_to_check: text(r["Casi da verificare"]), notes: text(r.Note), standard_terms: text(r["Condizioni standard"]), resources: text(r["Documenti e risorse"]),
      required_documents: text(r["Documenti richiesti"]), lines: text(r.Linee), original_folders: text(r["Cartelle originali"]),
      reviewed: bool(r.Revisionato), reviewed_on: date(r["Revisionato il"]),
      deadline_templates: json(r.scadenzeModello, "Strumenti.scadenzeModello"),
      legacy_active_milestones: json(r.milestoneAttive, "Strumenti.milestoneAttive"), legacy_active_activities: json(r.attivitaAttive, "Strumenti.attivitaAttive"),
    }),
    foreignKeys: [rel("Categorie__Strumenti", "strumentiId", "categorieId", "service_categories", "category_id")],
    totals: ["budget_cents"],
  },
  {
    name: "data_requests", source: "Dati", table: "data_requests",
    map: (r: Row) => ({
      name: text(r.nome) ?? "(no name)", data_type: dataType(r.tipo), lifetime: lifetime(r.genere), feeds: text(r.alimenta),
      save_on_company: bool(r.salvaSuAzienda), save_on_contact: bool(r.salvaSuContatto), save_on_deal: bool(r.salvaSuTrattativa),
      save_on_case: bool(r.salvaSuPratica), save_on_asset: bool(r.salvaSuBene), required_by_default: bool(r.obbligatorioDiPartenza),
      validity: validity(r.validita), validity_months: num(r.validitaMesi), options: text(r.opzioni), help: text(r.aiuto),
      archived: bool(r.archiviato), local_only: bool(r.locale), local_owner: text(r.proprietarioLocale),
      legacy_target_column: text(r.colonna), section: text(r.sezione), signatures_required: num(r.firmeRichieste), signers: text(r.firmatari),
    }),
  },
  {
    name: "service_fields", source: "Campi strumento", table: "service_fields",
    map: (r: Row) => ({
      label: text(r.etichetta) ?? "(no label)", field_type: fieldType(r.tipo), options: text(r.opzioni), required: bool(r.obbligatorio),
      initial_value: text(r.valoreIniziale), help: text(r.aiuto), position: num(r.ordine) ?? 0, active: r.attivo === null ? true : bool(r.attivo),
      feeds: text(r.alimenta), required_on_deal: obligation(r.obbligoTrattativa), required_on_case: obligation(r.obbligoPratica),
      shown_in_deadlines: json(r.inScadenze, "Campi strumento.inScadenze"), asked_in_deadlines: json(r.daChiedereIn, "Campi strumento.daChiedereIn"),
      per_deadline: r.perScadenza === null || r.perScadenza === undefined ? null : bool(r.perScadenza),
      template: text(r.modello), template_version: text(r.versioneModello),
      template_on_every_case: r.modelloSuOgniPratica === null || r.modelloSuOgniPratica === undefined ? null : bool(r.modelloSuOgniPratica),
    }),
    foreignKeys: [
      rel("Campi strumento__Categorie", "campi strumentoId", "categorieId", "service_categories", "category_id"),
      rel("Campi strumento__Strumenti", "campi strumentoId", "strumentiId", "services", "service_id"),
      rel("Campi strumento__Dati", "campi strumentoId", "datiId", "data_requests", "data_request_id"),
    ],
  },
  {
    name: "milestones", source: "Fasi di attivita", table: "milestones",
    map: (r: Row) => ({ name: text(r.nome) ?? "(no name)", position: num(r.ordine) ?? 0, active: r.attivo === null ? true : bool(r.attivo), days: num(r.giorni) }),
    foreignKeys: [rel("Categorie__Fasi di attivita", "fasi di attivitaId", "categorieId", "service_categories", "category_id")],
  },
  {
    name: "activity_templates", source: "Attivita modello", table: "activity_templates",
    map: (r: Row) => ({
      title: text(r.titolo) ?? "(no title)", description: text(r.descrizione), days: num(r.giorni), owner: text(r.responsabile), kind: text(r.tipo),
      position: num(r.ordine) ?? 0, active: r.attivo === null ? true : bool(r.attivo),
    }),
    foreignKeys: [
      rel("Attivita modello__Categorie", "attivita modelloId", "categorieId", "service_categories", "category_id"),
      rel("Attivita modello__Strumenti", "attivita modelloId", "strumentiId", "services", "service_id"),
      rel("Attivita modello__Fasi di attivita", "attivita modelloId", "fasi di attivitaId", "milestones", "milestone_id"),
    ],
  },
  {
    name: "standard_activities", source: "Attivita standard", table: "standard_activities",
    map: (r: Row) => ({
      title: text(r.titolo) ?? "(no title)", description: text(r.descrizione), days: num(r.giorni), owner: text(r.responsabile),
      position: num(r.ordine) ?? 0, active: r.attivo === null ? true : bool(r.attivo),
    }),
    foreignKeys: [rel("Attivita standard__Fasi di attivita", "attivita standardId", "fasi di attivitaId", "milestones", "milestone_id")],
  },
  {
    name: "lookup_options", source: "Opzioni", table: "lookup_options",
    map: (r: Row) => ({ kind: optionKind(r.campo), label: text(r.valore) ?? "(no label)", position: num(r.ordine) ?? 0, active: r.attivo === null ? true : bool(r.attivo) }),
  },
];
