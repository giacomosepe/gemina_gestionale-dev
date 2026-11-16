// The import runner: loads a Zite export into a target project, in dependency order, and reports what it did.
// The export and the report hold real data and stay OUTSIDE this repo (CLAUDE.md rule 6). Only code and made-up fixtures live here.
export type Row = Record<string, unknown>;

/** Reads one Zite table, or one Zite link table (named "A__B"), from the export. */
export interface Source {
  read(table: string): Promise<Row[]>;
}

/** Where the rows go. The real one is a Postgres transaction; tests use an in-memory one. */
export interface Sink {
  count(table: string): Promise<number>;
  insert(table: string, rows: Row[]): Promise<void>;
}

/** A foreign key on the new table that Zite stored in a link table (to-one: the first link wins, more than one is reported). */
export interface ForeignKey {
  linkTable: string;   // e.g. "Aziende__Contatti"
  fromColumn: string;  // column of the link table that holds THIS step's Zite id, e.g. "contattiId"
  toColumn: string;    // column of the link table that holds the other record's Zite id, e.g. "aziendeId"
  toStep: string;      // name of an EARLIER step that imported the other table
  column: string;      // foreign key column on this step's new table
  required?: boolean;  // a missing link is an error, not just a count
}

/** A many-to-many link table of Zite that becomes a junction table in the new schema. */
export interface Junction {
  linkTable: string;
  leftColumn: string; leftStep: string; leftTargetColumn: string;
  rightColumn: string; rightStep: string; rightTargetColumn: string;
  table: string;       // the new junction table
}

export interface Step {
  name: string;                       // unique, used by foreign keys and in the report
  source: string;                     // the Zite table name
  table: string;                      // the new table
  idField?: string;                   // the Zite id column (default "id")
  map: (row: Row) => Row;             // new columns; the engine adds `id` (new uuid) and `legacy_id` (the Zite id)
  foreignKeys?: ForeignKey[];
  junctions?: Junction[];
  totals?: string[];                  // numeric new columns to sum in the report (invoices and commissions later)
}

export interface StepReport {
  name: string; table: string;
  sourceRows: number; inserted: number;
  unresolved: { legacyId: string; link: string; missingId: string }[];
  multipleLinks: number;
  junctionRows: Record<string, number>;
  totals: Record<string, number>;
}

export interface Report { ok: boolean; steps: StepReport[]; problems: string[] }
