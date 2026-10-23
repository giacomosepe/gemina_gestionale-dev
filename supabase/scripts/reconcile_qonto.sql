-- Reconciliation of Zite Fatture against public.qonto_documents (Linear PRDDISC-7, milestone M1). READ-ONLY: one select, nothing is written.
-- The Zite table is "Fatture" (workspace "Gemina Revenue System"; the issue says Documenti). To repeat the comparison:
--   1. Run this in Zite (execute_sql on the workspace) and replace the rows of the CTE `zite` below with its result:
--        select "Qonto ID", "Numero", "Tipo documento", "Origine", "Stato", "Data emissione", "Scadenza", "Data incasso",
--               "Imponibile (€)", "Totale (€)", (azienda link id) from "Fatture" order by "Data emissione", "Numero"
--      (the last column is the Zite id of the linked Azienda, null if none; no names are needed).
--   2. Run the whole statement on the Supabase project (SQL editor or MCP). The answer is one json row, `report`.
-- Zite has no VAT field: VAT = Totale - Imponibile. Amounts are compared in cents (Zite euro * 100, rounded).
-- Zite rules reproduced: Annullata documents leave revenue/VAT/DSO (cassa normalizzaFatture, efficaciaFinanziaria); a credit note is
-- negative; revenue and VAT by issue date; "overdue" = Emessa and due date before today in Rome (statoVisibile); DSO = average days
-- from issue to payment of Incassata invoices whose payment is not before the issue (efficaciaFinanziaria), here by month of payment,
-- rounded to 1 decimal (DSO itself is computed in the app; here it is only compared).
-- Cause labels: mapping, rounding, date fallback, unmatched client, manual invoice not in Qonto, only in one system.

with zite (qonto_id, numero, tipo, origine, stato, emissione, scadenza, incasso, imponibile, totale, azienda_zite_id) as (
  values
    ('01a05d1d-5d67-7858-8b68-47effc941db6', 'GA001', 'Fattura', 'Qonto', 'Incassata', date '2026-09-01', date '2026-09-01', date '2026-10-15', 2000::numeric, 2440::numeric, '056877bd-9a23-4566-96b4-359bf75286f4'),
    ('01a080f6-61f2-7c1b-a5ea-754e2ce64eba', 'GA002', 'Fattura', 'Qonto', 'Emessa',    date '2026-09-08', date '2026-11-07', null::date,        2400::numeric, 2928::numeric, null),
    ('01a0ce5e-908d-7d23-badb-192ac1b870a1', 'GA003', 'Fattura', 'Qonto', 'Incassata', date '2026-09-23', date '2026-09-23', date '2026-10-07', 1800::numeric, 2196::numeric, null),
    ('01a0f715-9da9-7a85-bd85-b7d0729501a0', 'GA004', 'Fattura', 'Qonto', 'Incassata', date '2026-10-06', date '2026-10-06', date '2026-10-13', 2600::numeric, 3172::numeric, 'a2f8385f-a21b-4bf4-8711-09581f4d7b41')
),
today as (select (now() at time zone 'Europe/Rome')::date as d),
z as (  -- Zite, in cents, credit notes negative
  select qonto_id, numero, tipo, origine, stato, emissione, scadenza, incasso, azienda_zite_id,
         (case when tipo = 'Nota di credito' then -1 else 1 end) * round(abs(imponibile) * 100)::bigint as net_cents,
         (case when tipo = 'Nota di credito' then -1 else 1 end) * round(abs(totale - imponibile) * 100)::bigint as vat_cents,
         (case when tipo = 'Nota di credito' then -1 else 1 end) * round(abs(totale) * 100)::bigint as total_cents
    from zite
),
s as (  -- Supabase, with the azienda it resolves to
  select d.qonto_id, d.number, d.kind, d.status, d.issue_date, d.due_date, d.paid_at, d.net_cents, d.vat_cents, d.total_cents,
         d.removed_at, c.zite_azienda_id as azienda_zite_id
    from public.qonto_documents d left join public.companies c on c.id = d.company_id
),
-- 1. presence by qonto_id (manual invoices, without a Qonto id, are listed apart)
zq as (select * from z where qonto_id is not null and origine = 'Qonto'),
zm as (select * from z where qonto_id is null or origine <> 'Qonto'),
only_zite as (select zq.numero, zq.qonto_id from zq where not exists (select 1 from s where s.qonto_id = zq.qonto_id)),
only_supabase as (select s.number, s.qonto_id from s where not exists (select 1 from zq where zq.qonto_id = s.qonto_id)),
pair as (select zq.qonto_id, zq.numero, zq.tipo, zq.stato as z_status, s.status as s_status, zq.emissione as z_issue, s.issue_date as s_issue,
                zq.scadenza as z_due, s.due_date as s_due, zq.incasso as z_paid, s.paid_at as s_paid,
                zq.net_cents as z_net, s.net_cents as s_net, zq.vat_cents as z_vat, s.vat_cents as s_vat, zq.total_cents as z_total, s.total_cents as s_total,
                zq.azienda_zite_id as z_az, s.azienda_zite_id as s_az
           from zq join s using (qonto_id)),
-- 2. differences per document, each with a cause
diff as (
  select numero, 'status' as field, z_status as zite, s_status as supabase, 'mapping' as cause from pair where z_status is distinct from s_status
  union all select numero, 'issue_date', z_issue::text, s_issue::text, 'mapping' from pair where z_issue is distinct from s_issue
  union all select numero, 'due_date', z_due::text, s_due::text,
            case when s_due is null or z_due = z_issue then 'date fallback' else 'mapping' end from pair where z_due is distinct from s_due
  union all select numero, 'paid_at', z_paid::text, s_paid::text,
            case when s_paid is null and z_paid is not null then 'date fallback' else 'mapping' end from pair where z_paid is distinct from s_paid
  union all select numero, 'net', z_net::text, s_net::text, case when abs(z_net - s_net) <= 1 then 'rounding' else 'mapping' end from pair where z_net <> s_net
  union all select numero, 'vat', z_vat::text, s_vat::text, case when abs(z_vat - s_vat) <= 1 then 'rounding' else 'mapping' end from pair where z_vat <> s_vat
  union all select numero, 'total', z_total::text, s_total::text, case when abs(z_total - s_total) <= 1 then 'rounding' else 'mapping' end from pair where z_total <> s_total
  union all select numero, 'azienda (client)', coalesce(z_az, '(none)'), coalesce(s_az, '(none)'),
            case when z_az is null or s_az is null then 'unmatched client' else 'mapping' end from pair where z_az is distinct from s_az
),
-- 3. aggregates (Zite rules on both sides)
zv as (select * from z where stato <> 'Annullata' and emissione is not null),
sv as (select * from s where status <> 'Annullata' and removed_at is null),
rev as (
  select m, sum(zr) as zite_net, sum(sr) as supabase_net from (
    select date_trunc('month', emissione)::date as m, net_cents as zr, 0::bigint as sr from zv
    union all select date_trunc('month', issue_date)::date, 0, net_cents from sv) x group by m),
vatq as (
  select q, sum(zr) as zite_vat, sum(sr) as supabase_vat from (
    select to_char(emissione, 'YYYY-"Q"Q') as q, vat_cents as zr, 0::bigint as sr from zv
    union all select to_char(issue_date, 'YYYY-"Q"Q'), 0, vat_cents from sv) x group by q),
overdue as (
  select (select count(*) from z, today where stato = 'Emessa' and scadenza < today.d) as zite,
         (select count(*) from s, today where status = 'Emessa' and removed_at is null and due_date < today.d) as supabase),
dso as (
  select m, max(zd) as zite_dso, max(sd) as supabase_dso, max(zn) as zite_n, max(sn) as supabase_n from (
    select date_trunc('month', incasso)::date as m, round(avg(incasso - emissione), 1) as zd, null::numeric as sd, count(*) as zn, null::bigint as sn
      from zv where stato = 'Incassata' and tipo <> 'Nota di credito' and incasso is not null and incasso >= emissione group by 1
    union all
    select date_trunc('month', paid_at)::date, null, round(avg(paid_at - issue_date), 1), null, count(*)
      from sv where status = 'Incassata' and kind = 'invoice' and paid_at is not null and paid_at >= issue_date group by 1) x group by m)
select jsonb_build_object(
  'run_at', now(),
  'date_range', jsonb_build_object('from', (select min(d) from (select emissione as d from z union all select issue_date from s) x),
                                   'to',   (select max(d) from (select emissione as d from z union all select issue_date from s) x)),
  'counts', jsonb_build_object('zite_total', (select count(*) from z), 'zite_with_qonto_id', (select count(*) from zq),
                               'zite_manual', (select count(*) from zm), 'supabase_total', (select count(*) from s),
                               'in_both', (select count(*) from pair)),
  'only_in_zite', (select coalesce(jsonb_agg(to_jsonb(o)), '[]') from only_zite o),
  'only_in_supabase', (select coalesce(jsonb_agg(to_jsonb(o)), '[]') from only_supabase o),
  'manual_zite_invoices', (select coalesce(jsonb_agg(jsonb_build_object('numero', numero, 'net_cents', net_cents, 'stato', stato)), '[]') from zm),
  'differences', (select coalesce(jsonb_agg(to_jsonb(x) order by numero, field), '[]') from diff x),
  'monthly_revenue_net_cents', (select coalesce(jsonb_agg(jsonb_build_object('month', m, 'zite', zite_net, 'supabase', supabase_net, 'equal', zite_net = supabase_net) order by m), '[]') from rev),
  'quarterly_vat_cents', (select coalesce(jsonb_agg(jsonb_build_object('quarter', q, 'zite', zite_vat, 'supabase', supabase_vat, 'equal', zite_vat = supabase_vat) order by q), '[]') from vatq),
  'overdue_count', (select to_jsonb(overdue) from overdue),
  'dso_by_payment_month_days', (select coalesce(jsonb_agg(jsonb_build_object('month', m, 'zite', zite_dso, 'supabase', supabase_dso, 'zite_invoices', zite_n, 'supabase_invoices', supabase_n, 'equal', zite_dso is not distinct from supabase_dso) order by m), '[]') from dso)
) as report;
