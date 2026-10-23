-- Review list for invoices Qonto left incomplete (Linear PRDDISC-6 follow-up, sign-off of 2026-10-23). View only.
--
-- Decided by Giacomo on 2026-10-23 (reconciliation sign-off):
-- - A paid invoice without a payment date keeps paid_at null (no fallback to the issue date: it would make a late payer look fast in DSO);
--   the app shows "paid, date missing". It was already flagged in invoice_payments_v; here it also enters the review list.
-- - An invoice without a due date could never become Scaduta, so it appears in the review list instead of being silently ignored.
-- - A credit note is not paid: paid_at null is normal for it and is NOT a review case.
-- One row per document and reason. Documents Qonto no longer returns are left out. security_invoker: staff read; partners and clients nothing.

create view public.invoice_review_v with (security_invoker = true) as
select d.id, d.qonto_id, d.kind, d.number, d.status, d.issue_date, d.due_date, d.paid_at, d.currency, d.total_cents,
       d.company_id, d.qonto_client_id, d.zite_pratica_id,
       'due_date_missing'::text as reason_code,
       'Scadenza mancante in Qonto: la fattura non può diventare scaduta'::text as reason
  from public.qonto_documents d
 where d.kind = 'invoice' and d.status = 'Emessa' and d.due_date is null and d.removed_at is null
union all
select d.id, d.qonto_id, d.kind, d.number, d.status, d.issue_date, d.due_date, d.paid_at, d.currency, d.total_cents,
       d.company_id, d.qonto_client_id, d.zite_pratica_id,
       'paid_at_missing',
       'Incassata senza data di incasso in Qonto'
  from public.qonto_documents d
 where d.kind = 'invoice' and d.status = 'Incassata' and d.paid_at is null and d.removed_at is null;
comment on view public.invoice_review_v is 'Invoices to check: Emessa without due date (never Scaduta) and Incassata without payment date; credit notes are not review cases';

revoke all on public.invoice_review_v from public, anon, authenticated;
grant select on public.invoice_review_v to authenticated;
grant select on public.invoice_review_v to service_role;
