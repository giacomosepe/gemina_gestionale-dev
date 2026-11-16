// deno run --allow-net --allow-env --allow-read --allow-write run.ts --export <folder> --out <folder> [--reset] [--dry-run]
//   IMPORT_DB_URL  the target database (staging for the rehearsal). The password goes in PGPASSWORD, not in the URL.
//   --reset        empties the tables of the steps first; allowed only if the URL contains the ref in IMPORT_RESET_ALLOWED_REF (staging).
//   --dry-run      runs everything and rolls the transaction back (to see the report without keeping data).
// The export and the report folders must be outside this repository: they hold real data.
import { parseArgs } from "node:util";
import { formatReport, runImport } from "./engine.ts";
import { inTransaction } from "./pg_sink.ts";
import { insideRepo } from "./paths.ts";
import { DirectorySource } from "./source.ts";
import { steps } from "./steps.ts";

const { values } = parseArgs({ options: { export: { type: "string" }, out: { type: "string" }, reset: { type: "boolean" }, "dry-run": { type: "boolean" } } });
const url = Deno.env.get("IMPORT_DB_URL");
if (!values.export || !values.out || !url) { console.error("usage: see the header of run.ts (--export, --out and IMPORT_DB_URL are required)"); Deno.exit(2); }
for (const p of [values.export, values.out]) if (await insideRepo(p)) { console.error(`refused: ${p} is inside the repository; real data must stay outside it`); Deno.exit(2); }
if (values.reset) {
  const ref = Deno.env.get("IMPORT_RESET_ALLOWED_REF");
  if (!ref || !url.includes(ref)) { console.error("refused: --reset only runs against the project named in IMPORT_RESET_ALLOWED_REF"); Deno.exit(2); }
}

const report = await inTransaction(url, async (sink, tx) => {
  if (values.reset) for (const s of [...steps].reverse()) {
    for (const j of s.junctions ?? []) await tx`truncate table ${tx(j.table)} restart identity cascade`;
    await tx`truncate table ${tx(s.table)} restart identity cascade`;
  }
  const r = await runImport(steps, new DirectorySource(values.export!), sink);
  if (!r.ok) throw Object.assign(new Error("import has problems; rolled back"), { report: r });
  return r;
}, Boolean(values["dry-run"])).catch((e) => {
  if (e.report) return e.report as Awaited<ReturnType<typeof runImport>>;
  throw e;
});

await Deno.mkdir(values.out, { recursive: true });
const text = formatReport(report);
await Deno.writeTextFile(`${values.out}/import-report.md`, text);
await Deno.writeTextFile(`${values.out}/import-report.json`, JSON.stringify(report, null, 2));
console.log(text);
Deno.exit(report.ok ? 0 : 1);
