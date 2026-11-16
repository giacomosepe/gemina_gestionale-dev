import postgres from "npm:postgres@3.4.5";
import type { Row, Sink } from "./types.ts";

type Tx = postgres.TransactionSql;

/** Inserts inside one transaction: if anything fails, nothing is left in the target. Identifiers come from the code's own steps, never from the data. */
export class PgSink implements Sink {
  constructor(private tx: Tx) {}
  async count(table: string): Promise<number> {
    const [r] = await this.tx`select count(*)::int as n from ${this.tx(table)}`;
    return r.n;
  }
  async insert(table: string, rows: Row[]): Promise<void> {
    if (!rows.length) return;
    const columns = Object.keys(rows[0]);
    for (let i = 0; i < rows.length; i += 500) {
      await this.tx`insert into ${this.tx(table)} ${this.tx(rows.slice(i, i + 500) as postgres.Row[], ...columns)}`;
    }
  }
}

export async function inTransaction<T>(url: string, fn: (sink: PgSink, tx: Tx) => Promise<T>, rollback = false): Promise<T> {
  const sql = postgres(url, { prepare: false, max: 1 });
  const ROLLBACK = Symbol("rollback");
  try {
    let result!: T;
    try {
      await sql.begin(async (tx) => {
        result = await fn(new PgSink(tx), tx);
        if (rollback) throw ROLLBACK;
      });
    } catch (e) { if (e !== ROLLBACK) throw e; }
    return result;
  } finally { await sql.end(); }
}
