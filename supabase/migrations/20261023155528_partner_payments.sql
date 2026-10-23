-- What a segnalatore may see of the payments (Linear PRDDISC-14, milestone M3): a narrow window, a function, nothing else. Additive: one function.
--
-- public.partner_payments(): one row per invoice that Gemina has been PAID for (status Incassata, with a payment date), of a client the calling segnalatore
-- referred, where the referral was active on the invoice's issue date (private.referral_active_on = Zite's attiva() rule, PRDDISC-13). Columns: invoice number
-- and id (stable reference), company name, pratica code (null if the invoice is not linked, PRDDISC-12), paid_at. NO amount, no VAT, no status of anything else.
-- Never shown: unpaid or overdue invoices, cancelled ones, credit notes, documents Qonto no longer returns, an invoice paid without a date (it appears when
-- it has one), a referral that was removed in Zite, other segnalatori's clients.
-- The caller is checked inside (same pattern as partner_documents): only a current member of a non-archived segnalatore; staff, clients and anyone else get
-- zero rows; anonymous has no execute right. A segnalatore archived in partners, or removed from partner_members, gets zero rows at once.
-- Nothing else changes: qonto_documents, referrals and the views keep their staff-only policies; this function is the only segnalatore path.
-- Defaults to confirm in review (Giacomo may change them): no amount; the payment date is Qonto's paid_at.

create function public.partner_payments()
returns table (invoice_id uuid, invoice_number text, company_name text, pratica_code text, paid_at date)
language sql stable security definer set search_path = '' as $$
  with me as (
    select pm.partner_id
      from public.partner_members pm
      join public.partners pa on pa.id = pm.partner_id and not pa.archived
     where pm.profile_id = (select auth.uid()))
  select d.id, d.number, co.name, pr.code, d.paid_at
    from public.qonto_documents d
    join public.companies co on co.id = d.company_id
    left join public.pratiche pr on pr.id = d.pratica_id and pr.removed_at is null
   where d.kind = 'invoice' and d.status = 'Incassata' and d.removed_at is null and d.paid_at is not null
     and exists (select 1 from me
                  join public.referrals r on r.partner_id = me.partner_id and r.company_id = d.company_id
                 where private.referral_active_on(r.id, d.issue_date))
   order by d.paid_at desc, d.id;
$$;
comment on function public.partner_payments() is 'A segnalatore''s window on paid invoices of the clients they referred (referral active on the issue date): number, company, pratica code, payment date; no amounts';

revoke execute on function public.partner_payments() from public, anon;
grant execute on function public.partner_payments() to authenticated;
