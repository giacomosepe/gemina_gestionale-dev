-- partner_commissions(): show the lines the segnalatore has already invoiced or been paid, even when the invoice was cancelled or removed in Qonto
-- (Linear PRDDISC-32, decision of Giacomo 2026-10-29: option A). Replaces public.partner_commissions() (new column, so drop and create; the function is new and
-- nothing calls it yet). Before: every line of a cancelled or removed invoice was left out, so a line the segnalatore had already invoiced vanished from
-- the portal while staff still saw it. Now: lines of cancelled or removed invoices are returned only at stage fatturate or ricevute (stage_order >= 3), with
-- invoice_cancelled = true so the screen can say so. Teoriche and maturate lines of such invoices stay out (the rebuild deletes them anyway).
-- Everything else is unchanged: same columns plus the last one, same caller resolution, same grants (authenticated only).

drop function public.partner_commissions();

create function public.partner_commissions()
returns table (
  id uuid, invoice_id uuid, invoice_number text, invoice_issue_date date, invoice_paid_at date, invoice_net_cents bigint,
  pratica_id uuid, pratica_code text, pratica_title text,
  pct numeric, base_cents bigint, amount_cents bigint,
  partner_invoice_number text, partner_invoiced_on date, paid_on date,
  stage text, stage_order int, zite_azienda_id text, company_name text, invoice_cancelled boolean)
language sql stable security definer set search_path = '' as $$
  with me as (
    select pm.partner_id
      from public.partner_members pm
      join public.partners pa on pa.id = pm.partner_id and not pa.archived
     where pm.profile_id = (select auth.uid()))
  select l.id, l.invoice_id, l.invoice_number, l.invoice_issue_date, l.invoice_paid_at, l.invoice_net_cents,
         l.pratica_id, l.pratica_code, pr.title,
         l.pct, l.base_cents, l.amount_cents,
         l.partner_invoice_number, l.partner_invoiced_on, l.paid_on,
         l.stage, l.stage_order, l.zite_azienda_id, l.company_name,
         (l.invoice_status = 'Annullata' or d.removed_at is not null) as invoice_cancelled
    from public.commission_lines_v l
    join public.qonto_documents d on d.id = l.invoice_id
    left join public.pratiche pr on pr.id = l.pratica_id
   where l.partner_id in (select partner_id from me)
     and ((l.invoice_status <> 'Annullata' and d.removed_at is null) or l.stage_order >= 3)
   order by l.invoice_issue_date desc nulls last, l.id;
$$;
comment on function public.partner_commissions() is 'A segnalatore''s own commission lines (stage from commission_stages_v): company, pratica, invoice number and date, net, base, percentage, amount, own invoice and payment dates; lines of cancelled or removed invoices only when already invoiced or paid, flagged invoice_cancelled; nothing of other segnalatori';

revoke execute on function public.partner_commissions() from public, anon;
grant execute on function public.partner_commissions() to authenticated;
