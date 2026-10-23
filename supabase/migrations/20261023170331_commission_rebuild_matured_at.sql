-- PRDDISC-20, follow-up: tell a line born on an already paid invoice from a real "invoice just got paid" transition, even inside one transaction.
-- A line created while its invoice is paid gets matured_at = created_at (both now()); a line that matures later gets matured_at = clock_timestamp(),
-- which is after created_at. PRDDISC-22 fires the notice only when matured_at is later than created_at. Replaces private.rebuild_commissions only.

create or replace function private.rebuild_commissions(p_invoice uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  d record;
  eligible boolean;
  ins int := 0; upd int := 0; del int := 0; mat int := 0;
begin
  select id, kind, status, issue_date, net_cents, removed_at, company_id, pratica_id into d from public.qonto_documents where id = p_invoice;
  if not found then
    return jsonb_build_object('inserted', 0, 'updated', 0, 'deleted', 0, 'matured', 0);
  end if;
  eligible := d.kind = 'invoice' and d.status <> 'Annullata' and d.removed_at is null and d.issue_date is not null
              and d.net_cents is not null and d.net_cents >= 0 and d.company_id is not null and d.pratica_id is not null;

  with valid as (
    select r.id as referral_id from public.referrals r
     where eligible and r.company_id = d.company_id and r.partner_id is not null and private.referral_active_on(r.id, d.issue_date)),
  gone as (
    delete from public.commissions c
     where c.invoice_id = p_invoice and c.paid_on is null and nullif(btrim(c.partner_invoice_number), '') is null
       and c.referral_id not in (select referral_id from valid)
    returning 1)
  select count(*) into del from gone;

  if eligible then
    with valid as (
      select r.id as referral_id from public.referrals r
       where r.company_id = d.company_id and r.partner_id is not null and private.referral_active_on(r.id, d.issue_date)),
    changed as (
      update public.commissions c
         set base_cents = d.net_cents, amount_cents = floor(d.net_cents * c.pct / 100 + 0.5)::bigint
        from valid v
       where c.invoice_id = p_invoice and c.referral_id = v.referral_id and c.paid_on is null and nullif(btrim(c.partner_invoice_number), '') is null
         and c.base_cents is distinct from d.net_cents
      returning 1)
    select count(*) into upd from changed;

    with created as (
      insert into public.commissions (invoice_id, referral_id, partner_id, pct, base_cents, amount_cents, matured_at)
      select p_invoice, r.id, r.partner_id, coalesce(r.commission_pct, 0), d.net_cents, floor(d.net_cents * coalesce(r.commission_pct, 0) / 100 + 0.5)::bigint,
             case when d.status = 'Incassata' then now() end
        from public.referrals r
       where r.company_id = d.company_id and r.partner_id is not null and private.referral_active_on(r.id, d.issue_date)
         and not exists (select 1 from public.commissions c where c.invoice_id = p_invoice and c.referral_id = r.id)
      returning 1)
    select count(*) into ins from created;
  end if;

  if d.status = 'Incassata' then
    with m as (update public.commissions set matured_at = clock_timestamp() where invoice_id = p_invoice and matured_at is null returning 1)
    select count(*) into mat from m;
  end if;
  return jsonb_build_object('inserted', ins, 'updated', upd, 'deleted', del, 'matured', mat);
end $$;
