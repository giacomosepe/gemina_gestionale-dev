-- What a segnalatore sees of their commissions and of the invoiced amount of their pratiche (Linear PRDDISC-32, milestone M5). Additive: two functions, no
-- table, view or policy changes. Same pattern as partner_payments(): security definer, the caller is resolved inside, nothing for anon.
--
-- 1. public.partner_commissions(): the stored commission lines of the calling segnalatore, read from commission_lines_v (which joins commission_stages_v, where
--    the stage rule lives: ricevute if paid_on, fatturate if the segnalatore's own invoice number is set, maturate if the invoice is Incassata, else teoriche).
--    No referral_active_on check: a line exists only because the rebuild found the referral applicable. Lines of invoices with status Annullata and of
--    documents with removed_at set are left out (the views do not filter them; Zite did). Columns are those of commission_lines_v the portal needs, plus the
--    pratica title. NOT returned: partner_id, partner_name, referral_id, invoice_qonto_id, invoice_status, raw, VAT or gross totals.
--    base_cents is the commissionable base; invoice_net_cents the net of the invoice (equal today: commission on the whole net; with the first-invoice franchise
--    of PRDDISC-33 the franchise is invoice_net_cents - base_cents).
-- 2. public.partner_pratica_invoiced(): (pratica_id, invoiced_net_cents) of the open pratiche (is_open, not removed) of the companies where the caller has a
--    referral active today. invoiced_net_cents is the one of pratica_payment_status_v (cancelled left out, credit notes subtracted). Aggregate only: no invoice
--    number, date or status. It feeds the "Provvigioni teoriche" estimate, which stays computed in the app (estimated fee minus invoiced, times the percentage).
--
-- Why a definer function can read the staff views: the tables are owned by postgres, FORCE RLS is off and the views are security_invoker, so a function owned
-- by postgres reads them without the staff policy (test 027 proves it; if the owner or FORCE RLS changes, the function fails loudly, not silently).
-- A segnalatore archived in partners, or removed from partner_members, gets zero rows at once; staff and clients get zero rows.

create function public.partner_commissions()
returns table (
  id uuid, invoice_id uuid, invoice_number text, invoice_issue_date date, invoice_paid_at date, invoice_net_cents bigint,
  pratica_id uuid, pratica_code text, pratica_title text,
  pct numeric, base_cents bigint, amount_cents bigint,
  partner_invoice_number text, partner_invoiced_on date, paid_on date,
  stage text, stage_order int, zite_azienda_id text, company_name text)
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
         l.stage, l.stage_order, l.zite_azienda_id, l.company_name
    from public.commission_lines_v l
    join public.qonto_documents d on d.id = l.invoice_id
    left join public.pratiche pr on pr.id = l.pratica_id
   where l.partner_id in (select partner_id from me)
     and l.invoice_status <> 'Annullata'
     and d.removed_at is null
   order by l.invoice_issue_date desc nulls last, l.id;
$$;
comment on function public.partner_commissions() is 'A segnalatore''s own commission lines (stage from commission_stages_v; cancelled and removed invoices left out): company, pratica, invoice number and date, net, base, percentage, amount, own invoice and payment dates; nothing of other segnalatori';

create function public.partner_pratica_invoiced()
returns table (pratica_id uuid, invoiced_net_cents bigint)
language sql stable security definer set search_path = '' as $$
  with me as (
    select pm.partner_id
      from public.partner_members pm
      join public.partners pa on pa.id = pm.partner_id and not pa.archived
     where pm.profile_id = (select auth.uid()))
  select v.pratica_id, v.invoiced_net_cents
    from public.pratica_payment_status_v v
   where v.is_open
     and exists (select 1 from me
                  join public.referrals r on r.partner_id = me.partner_id and r.company_id = v.company_id
                 where private.referral_active_on(r.id, current_date))
   order by v.pratica_id;
$$;
comment on function public.partner_pratica_invoiced() is 'Invoiced net (cancelled left out, credit notes subtracted) of each open pratica of the clients the caller has an active referral on; aggregate only';

revoke execute on function public.partner_commissions(), public.partner_pratica_invoiced() from public, anon;
grant execute on function public.partner_commissions(), public.partner_pratica_invoiced() to authenticated;
