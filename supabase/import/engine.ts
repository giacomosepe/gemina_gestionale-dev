import type { Report, Row, Sink, Source, Step, StepReport } from "./types.ts";

const str = (v: unknown) => (v === null || v === undefined ? "" : String(v));

export async function runImport(steps: Step[], source: Source, sink: Sink, newId: () => string = () => crypto.randomUUID()): Promise<Report> {
  const problems: string[] = [];
  const names = new Set<string>();
  for (const s of steps) {
    if (names.has(s.name)) problems.push(`duplicate step name: ${s.name}`);
    names.add(s.name);
  }
  for (const s of steps) for (const f of s.foreignKeys ?? []) {
    if (!steps.slice(0, steps.indexOf(s)).some((p) => p.name === f.toStep)) problems.push(`${s.name}: foreign key to "${f.toStep}", which does not run before it`);
  }
  if (problems.length) return { ok: false, steps: [], problems };

  // The target must be empty: the runner is for the rehearsal and the cutover, never a merge into live data.
  for (const s of steps) {
    const n = await sink.count(s.table);
    if (n > 0) problems.push(`target table ${s.table} is not empty (${n} rows)`);
  }
  if (problems.length) return { ok: false, steps: [], problems };

  const idMap = new Map<string, Map<string, string>>();   // step name -> Zite id -> new id (the one place that maps ids)
  const reports: StepReport[] = [];

  for (const s of steps) {
    const rows = await source.read(s.source);
    const idField = s.idField ?? "id";
    const map = new Map<string, string>();
    idMap.set(s.name, map);
    const report: StepReport = { name: s.name, table: s.table, sourceRows: rows.length, inserted: 0, unresolved: [], multipleLinks: 0, junctionRows: {}, totals: {} };

    // Foreign keys from link tables: Zite id of this record -> list of Zite ids it points to.
    const fkLinks = new Map<number, Map<string, string[]>>();
    for (const [i, f] of (s.foreignKeys ?? []).entries()) {
      const byFrom = new Map<string, string[]>();
      for (const l of await source.read(f.linkTable)) {
        const from = str(l[f.fromColumn]), to = str(l[f.toColumn]);
        if (!from || !to) continue;
        byFrom.set(from, [...(byFrom.get(from) ?? []), to]);
      }
      fkLinks.set(i, byFrom);
    }

    const out: Row[] = [];
    for (const row of rows) {
      const legacyId = str(row[idField]);
      if (!legacyId) { problems.push(`${s.name}: a row has no ${idField}`); continue; }
      if (map.has(legacyId)) { problems.push(`${s.name}: duplicate id ${legacyId}`); continue; }
      const id = newId();
      map.set(legacyId, id);
      const mapped: Row = { ...s.map(row), id, legacy_id: legacyId };
      for (const [i, f] of (s.foreignKeys ?? []).entries()) {
        const targets = fkLinks.get(i)!.get(legacyId) ?? [];
        if (targets.length > 1) report.multipleLinks++;
        if (!targets.length) {
          mapped[f.column] = null;
          if (f.required) report.unresolved.push({ legacyId, link: f.linkTable, missingId: "(no link)" });
          continue;
        }
        const resolved = idMap.get(f.toStep)?.get(targets[0]);
        if (!resolved) { mapped[f.column] = null; report.unresolved.push({ legacyId, link: f.linkTable, missingId: targets[0] }); }
        else mapped[f.column] = resolved;
      }
      out.push(mapped);
    }
    await sink.insert(s.table, out);
    report.inserted = out.length;
    for (const col of s.totals ?? []) report.totals[col] = Math.round(out.reduce((a, r) => a + (Number(r[col]) || 0), 0) * 100) / 100;
    reports.push(report);
  }

  // Junction tables run after all steps, so both sides are known.
  for (const s of steps) for (const j of s.junctions ?? []) {
    const report = reports.find((r) => r.name === s.name)!;
    const out: Row[] = [];
    const seen = new Set<string>();
    for (const l of await source.read(j.linkTable)) {
      const left = str(l[j.leftColumn]), right = str(l[j.rightColumn]);
      const leftId = idMap.get(j.leftStep)?.get(left), rightId = idMap.get(j.rightStep)?.get(right);
      if (!leftId || !rightId) { report.unresolved.push({ legacyId: `${left}|${right}`, link: j.linkTable, missingId: !leftId ? left : right }); continue; }
      const key = `${leftId}|${rightId}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({ [j.leftTargetColumn]: leftId, [j.rightTargetColumn]: rightId });
    }
    await sink.insert(j.table, out);
    report.junctionRows[j.table] = out.length;
  }

  const unresolved = reports.reduce((a, r) => a + r.unresolved.length, 0);
  const lost = reports.filter((r) => r.sourceRows !== r.inserted);
  for (const r of lost) problems.push(`${r.name}: ${r.sourceRows} source rows, ${r.inserted} inserted`);
  if (unresolved) problems.push(`${unresolved} unresolved link(s): see the report`);
  return { ok: problems.length === 0, steps: reports, problems };
}

/** The report as text. It holds counts and Zite ids only (no names, no amounts per person), and nothing that changes between two runs. */
export function formatReport(r: Report): string {
  const lines = [`# Import report: ${r.ok ? "OK" : "PROBLEMS"}`, ""];
  if (r.problems.length) lines.push("## Problems", ...r.problems.map((p) => `- ${p}`), "");
  lines.push("| step | table | source rows | inserted | unresolved | multiple links | junction rows | totals |", "|---|---|---|---|---|---|---|---|");
  for (const s of r.steps) {
    lines.push(`| ${s.name} | ${s.table} | ${s.sourceRows} | ${s.inserted} | ${s.unresolved.length} | ${s.multipleLinks} | ${JSON.stringify(s.junctionRows)} | ${JSON.stringify(s.totals)} |`);
  }
  for (const s of r.steps) if (s.unresolved.length) {
    lines.push("", `## Unresolved links: ${s.name}`, ...s.unresolved.map((u) => `- ${u.legacyId} -> ${u.link}: ${u.missingId}`));
  }
  return lines.join("\n") + "\n";
}
