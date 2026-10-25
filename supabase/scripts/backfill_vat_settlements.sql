-- Backfill of the Zite "Liquidazioni IVA" into public.vat_settlements (Linear PRDDISC-17, milestone M4). IDEMPOTENT: a row with the same Zite id is overwritten with
-- the Zite values, so the script can be run again (the Zite table is the source until the cutover). One statement; the answer is one json row, `report`.
-- On 2026-10-25 the Zite table had 0 rows, so the first run inserts nothing; the script is here for the day it has rows (before the cutover, PRDDISC-28).
--   1. In Zite (execute_sql on the workspace): select id, "Anno", "Trimestre", "IVA a credito altri acquisti (€)", "Acconto IVA (€)", "Note" from "Liquidazioni IVA"
--      and replace the rows of the CTE `zite` below with its result (euros as written in Zite; they become cents here).
--   2. Run the whole statement on the Supabase project (SQL editor or MCP).
-- The period label is rebuilt from year and quarter ("T1 2027"). A row the table would refuse (advance outside Q4, quarter outside 1-4, a duplicate quarter,
-- a negative amount) is skipped and listed in report.skipped, never half written. Check afterwards: report.rows_in_supabase = rows in Zite, and the two sums.

with zite (zite_id, anno, trimestre, iva_credito_altri, acconto, note) as (
  select * from (values
    (null::uuid, null::int, null::int, null::numeric, null::numeric, null::text)
  ) v where false   -- replace with the Zite rows: ('<id>'::uuid, 2027, 1, 120.50, null, null), ...
),
checked as (
  select z.*,
         case when z.anno not between 2000 and 2100 or z.trimestre not between 1 and 4 then 'year or quarter out of range'
              when z.acconto is not null and z.trimestre <> 4 then 'advance outside the fourth quarter'
              when coalesce(z.iva_credito_altri, 0) < 0 or coalesce(z.acconto, 0) < 0 then 'negative amount'
              when count(*) over (partition by z.anno, z.trimestre) > 1 then 'two Zite rows for the same quarter'
              else null end as problem
    from zite z
),
up as (
  insert into public.vat_settlements as t (id, period, year, quarter, vat_credit_other_cents, vat_advance_cents, note)
  select c.zite_id, 'T' || c.trimestre || ' ' || c.anno, c.anno, c.trimestre::smallint,
         round(c.iva_credito_altri * 100)::bigint, round(c.acconto * 100)::bigint, nullif(btrim(c.note), '')
    from checked c where c.problem is null
  on conflict (id) do update set
    period = excluded.period, year = excluded.year, quarter = excluded.quarter,
    vat_credit_other_cents = excluded.vat_credit_other_cents, vat_advance_cents = excluded.vat_advance_cents, note = excluded.note
  returning (xmax = 0) as inserted
)
select jsonb_build_object(
  'zite_rows', (select count(*) from zite),
  'inserted', (select count(*) filter (where inserted) from up),
  'updated', (select count(*) filter (where not inserted) from up),
  'skipped', coalesce((select jsonb_agg(jsonb_build_object('zite_id', zite_id, 'problem', problem)) from checked where problem is not null), '[]'::jsonb),
  'rows_in_supabase', (select count(*) from public.vat_settlements),
  'sum_credit_other_eur', (select coalesce(sum(vat_credit_other_cents), 0) / 100.0 from public.vat_settlements),
  'sum_advance_eur', (select coalesce(sum(vat_advance_cents), 0) / 100.0 from public.vat_settlements)
) as report;
