// A Kysely dialect that runs every query on ONE existing postgres.js transaction (the request's transaction, opened as the signed-in user).
// Kysely never opens its own connection or transaction: what the handler writes with Kysely and with raw SQL lives in the same transaction,
// under the same role and claims, and rolls back together. `db.transaction()` inside a handler becomes a savepoint.
import {
  type CompiledQuery, type DatabaseConnection, type Dialect, type Driver, type QueryResult, PostgresAdapter, PostgresIntrospector, PostgresQueryCompiler,
} from "npm:kysely@0.27.6";
import type postgres from "npm:postgres@3.4.5";

class TxConnection implements DatabaseConnection {
  savepoints = 0;
  constructor(private sql: postgres.TransactionSql) {}
  async executeQuery<R>(q: CompiledQuery): Promise<QueryResult<R>> {
    // deno-lint-ignore no-explicit-any
    const rows = await this.sql.unsafe(q.sql, q.parameters as any[]);
    const n = BigInt(rows.count ?? rows.length);
    return { rows: [...rows] as R[], numAffectedRows: n, numChangedRows: n };
  }
  // deno-lint-ignore require-yield
  async *streamQuery<R>(): AsyncIterableIterator<QueryResult<R>> {
    throw new Error("streaming queries are not supported on a request transaction");
  }
  run(statement: string) { return this.sql.unsafe(statement); }
}

class TxDriver implements Driver {
  private conn: TxConnection;
  constructor(sql: postgres.TransactionSql) { this.conn = new TxConnection(sql); }
  init() { return Promise.resolve(); }
  acquireConnection() { return Promise.resolve(this.conn as DatabaseConnection); }
  async beginTransaction(c: DatabaseConnection) { const t = c as TxConnection; await t.run(`savepoint kysely_${++t.savepoints}`); }
  async commitTransaction(c: DatabaseConnection) { const t = c as TxConnection; await t.run(`release savepoint kysely_${t.savepoints--}`); }
  async rollbackTransaction(c: DatabaseConnection) {
    const t = c as TxConnection;
    await t.run(`rollback to savepoint kysely_${t.savepoints}`);
    await t.run(`release savepoint kysely_${t.savepoints--}`);
  }
  releaseConnection() { return Promise.resolve(); }
  destroy() { return Promise.resolve(); }
}

export function txDialect(sql: postgres.TransactionSql): Dialect {
  return {
    createAdapter: () => new PostgresAdapter(),
    createDriver: () => new TxDriver(sql),
    createIntrospector: (db) => new PostgresIntrospector(db),
    createQueryCompiler: () => new PostgresQueryCompiler(),
  };
}
