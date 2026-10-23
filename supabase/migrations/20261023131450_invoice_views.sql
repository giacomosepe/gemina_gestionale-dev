-- Invoice views over qonto_documents (Linear PRDDISC-6, milestone M1). Views only: no table, no write, nothing stored.
--
-- Rules, as in Zite and as decided in PRDDISC-1 (Giacomo, 2026-10-23):
-- - "Scaduta" is derived, never stored (Zite statoVisibile): status Emessa and due_date before today in Europe/Rome. No due date = not
--   overdue. Incassata, Annullata and credit notes are never Scaduta.
-- - Money is integer cents; credit notes are already negative in qonto_documents, so sums just add up (nothing is subtracted here).
-- - VAT is counted by issue date (Zite cassa: "IVA on issued invoices (by issue date)"), calendar quarters, Annullata documents left out
--   (Zite normalizzaFatture skips them).
-- - Documents Qonto no longer returns (removed_at set by the sync) are shown in invoice_status_v with a flag and left out of the
--   payments and VAT views: they are no longer invoices Qonto knows. This is the sync's marker, not a PRDDISC-1 rule: say if you
--   want them counted.
-- - Left out on purpose: DSO / days to pay (PRDDISC-1 rule 3: the formula stays in the app; invoice_payments_v gives issue_date and
--   paid_at), commission and setup fee (rule 2: no exclusion), and "fully paid" per pratica (rule 4: needs the invoice-to-pratica link,
--   milestone M2). No rule that PRDDISC-1 has not decided is encoded.
-- Every view is security_invoker: the RLS of qonto_documents applies (staff read; partners and clients see zero rows).

-- 1. Every document with its visible status --------------------------------------------------------------------------------------
create view public.invoice_status_v with (security_invoker = true) as
select d.id, d.qonto_id, d.kind, d.number, d.status_qonto, d.status,
       case when d.status = 'Emessa' and d.due_date < (now() at time zone 'Europe/Rome')::date then 'Scaduta' else d.status end as status_visible,
       (d.status = 'Emessa' and d.due_date < (now() at time zone 'Europe/Rome')::date) as is_overdue,
       case when d.status = 'Emessa' and d.due_date < (now() at time zone 'Europe/Rome')::date
            then (now() at time zone 'Europe/Rome')::date - d.due_date end as days_overdue,
       d.issue_date, d.due_date, d.paid_at, d.currency, d.total_cents, d.vat_cents, d.net_cents,
       d.company_id, d.qonto_client_id, d.zite_pratica_id, d.description,
       (d.removed_at is not null) as removed, d.removed_at, d.synced_at
  from public.qonto_documents d;
comment on view public.invoice_status_v is 'Every Qonto document with status_visible (Scaduta derived, as Zite statoVisibile) and days_overdue';

-- 2. Paid invoices and the ones paid without a date ------------------------------------------------------------------------------
create view public.invoice_payments_v with (security_invoker = true) as
select d.id, d.qonto_id, d.number, d.issue_date, d.due_date, d.paid_at, d.currency, d.total_cents, d.vat_cents, d.net_cents,
       d.company_id, d.qonto_client_id, d.zite_pratica_id,
       (d.paid_at is null) as needs_review,
       case when d.paid_at is null then 'Incassata senza data di incasso in Qonto' end as review_reason
  from public.qonto_documents d
 where d.kind = 'invoice' and d.status = 'Incassata' and d.removed_at is null;
comment on view public.invoice_payments_v is 'Paid invoices with issue_date and paid_at (the app computes DSO); needs_review = paid but Qonto gave no payment date';

-- 3. VAT per document, per month and per quarter of issue ------------------------------------------------------------------------
create view public.invoice_vat_v with (security_invoker = true) as
select d.id, d.qonto_id, d.kind, d.number, d.status, d.issue_date,
       date_trunc('month', d.issue_date)::date as issue_month,
       extract(year from d.issue_date)::int as issue_year,
       extract(quarter from d.issue_date)::int as issue_quarter,
       to_char(d.issue_date, 'YYYY-"Q"Q') as issue_quarter_key,
       d.currency, d.net_cents, d.vat_cents, d.total_cents, d.company_id
  from public.qonto_documents d
 where d.status <> 'Annullata' and d.removed_at is null;
comment on view public.invoice_vat_v is 'Net, VAT and total per document by issue date, Annullata and removed left out; credit notes are negative';

create view public.invoice_vat_month_v with (security_invoker = true) as
select v.issue_month, v.currency, count(*)::int as documents,
       sum(v.net_cents)::bigint as net_cents, sum(v.vat_cents)::bigint as vat_cents, sum(v.total_cents)::bigint as total_cents
  from public.invoice_vat_v v
 group by v.issue_month, v.currency;
comment on view public.invoice_vat_month_v is 'invoice_vat_v summed by month of issue (credit notes already net off)';

create view public.invoice_vat_quarter_v with (security_invoker = true) as
select v.issue_year, v.issue_quarter, v.issue_quarter_key, v.currency, count(*)::int as documents,
       sum(v.net_cents)::bigint as net_cents, sum(v.vat_cents)::bigint as vat_cents, sum(v.total_cents)::bigint as total_cents
  from public.invoice_vat_v v
 group by v.issue_year, v.issue_quarter, v.issue_quarter_key, v.currency;
comment on view public.invoice_vat_quarter_v is 'invoice_vat_v summed by calendar quarter of issue (credit notes already net off)';

-- 4. Access: signed-in users only (RLS of qonto_documents decides what they see) -------------------------------------------------------
revoke all on public.invoice_status_v, public.invoice_payments_v, public.invoice_vat_v,
              public.invoice_vat_month_v, public.invoice_vat_quarter_v from public, anon, authenticated;
grant select on public.invoice_status_v, public.invoice_payments_v, public.invoice_vat_v,
                public.invoice_vat_month_v, public.invoice_vat_quarter_v to authenticated;
grant select on public.invoice_status_v, public.invoice_payments_v, public.invoice_vat_v,
                public.invoice_vat_month_v, public.invoice_vat_quarter_v to service_role;
