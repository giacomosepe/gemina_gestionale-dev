// The data layer (PM-148): typed queries on the request's transaction, as the signed-in user.
//   * `DB` is built from the generated types (database.types.ts), so table and column names are checked when the code is compiled;
//   * `makeDb(sql)` gives a Kysely bound to a transaction (see kysely.ts); `asUser` sets the role and claims so row-level security applies;
//   * `allRows`, `byId`, `mustById` are the small helpers for the common reads (what tutti() and perId() were in Zite).
// Raw SQL stays available as ctx.tx.sql (a tagged template) for what Kysely does not express well, on the same transaction.
import { type ColumnType, Kysely, type Selectable } from "npm:kysely@0.27.6";
import type postgres from "npm:postgres@3.4.5";
import type { Database } from "./database.types.ts";
import { AppError } from "./errors.ts";
import { txDialect } from "./kysely.ts";

type Pub = Database["public"];
type Cols<T> = T extends { Row: infer R; Insert: infer I; Update: infer U }
  ? { [C in keyof R]: ColumnType<R[C], C extends keyof I ? I[C] : never, C extends keyof U ? U[C] : never> }
  : never;

/** Every table (readable, insertable, updatable) and every view (read only) of the public schema. */
export type DB =
  & { [T in keyof Pub["Tables"]]: Cols<Pub["Tables"][T]> }
  & { [V in keyof Pub["Views"]]: Pub["Views"][V] extends { Row: infer R } ? { [C in keyof R]: R[C] } : never };

export type TableName = keyof Pub["Tables"];
export type RowOf<T extends TableName> = Selectable<DB[T]>;

export function makeDb(sql: postgres.TransactionSql): Kysely<DB> {
  return new Kysely<DB>({ dialect: txDialect(sql) });
}

/** Run the rest of the transaction as this user: role `authenticated` and the claims that row-level security reads. */
export async function asUser(sql: postgres.TransactionSql, user: { id: string; email: string | null }) {
  await sql`select set_config('request.jwt.claims', ${JSON.stringify({ sub: user.id, role: "authenticated", email: user.email })}, true)`;
  await sql`set local role authenticated`;
}

export interface ListOptions<T extends TableName> {
  where?: Partial<RowOf<T>>;
  orderBy?: keyof RowOf<T> & string;
  descending?: boolean;
  limit?: number;
  offset?: number;
}

/** All rows of a table the user may see (row-level security decides), optionally filtered by equality, ordered and paged. */
export async function allRows<T extends TableName>(db: Kysely<DB>, table: T, opts: ListOptions<T> = {}): Promise<RowOf<T>[]> {
  // deno-lint-ignore no-explicit-any
  let q: any = db.selectFrom(table as any).selectAll();
  for (const [col, value] of Object.entries(opts.where ?? {})) q = value === null ? q.where(col, "is", null) : q.where(col, "=", value);
  if (opts.orderBy) q = q.orderBy(opts.orderBy, opts.descending ? "desc" : "asc");
  if (opts.limit !== undefined) q = q.limit(opts.limit);
  if (opts.offset) q = q.offset(opts.offset);
  return await q.execute();
}

/** One row by its id, or undefined when it does not exist or the user may not see it. */
export async function byId<T extends TableName>(db: Kysely<DB>, table: T, id: string): Promise<RowOf<T> | undefined> {
  // deno-lint-ignore no-explicit-any
  return await (db.selectFrom(table as any).selectAll().where("id" as any, "=", id as any) as any).executeTakeFirst();
}

/** As byId, but a missing row is a not_found error (404 with the Italian message). */
export async function mustById<T extends TableName>(db: Kysely<DB>, table: T, id: string): Promise<RowOf<T>> {
  const row = await byId(db, table, id);
  if (!row) throw new AppError("not_found");
  return row;
}
