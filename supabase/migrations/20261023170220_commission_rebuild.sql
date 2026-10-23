-- Commission rebuild and triggers (Linear PRDDISC-20, milestone M4). Replaces the 14 call sites of Zite's aggiornaProvvigioniFattura (src/lib/provvigioni.ts):
-- commission lines now appear, follow and disappear on their own when an invoice or a referral changes. Additive (a column, a log table, functions, triggers).
--
-- Rules, copied from Zite and PRDDISC-1:
--  * One line per invoice and referral (segnalazione) active on the invoice's issue date (private.referral_active_on = Zite attiva()).
--  * Invoice must be a real invoice (not a credit note), not cancelled, not removed in Qonto, with an issue date and a net amount, linked to a pratica
--    (Zite finds the client through the pratica: an invoice with no pratica gets no lines) and to a company. Whole net amount; NO first-invoice exclusion.
--  * Percentage and base are frozen when the line is created. Afterwards only the base (and the amount) follow a corrected invoice.
--  * Lines already invoiced by the segnalatore (partner_invoice_number) or received (paid_on) are NEVER touched: not updated, not deleted.
--    (Zite's code protects only paid lines; the issue asks for invoiced ones too, which is the safer reading: see the Linear comment.)
--  * matured_at: set on a line the first time its invoice is paid (status Incassata); never cleared, never set again (PRDDISC-22 fires on it).
--    A line created for an invoice that is already paid gets matured_at = created_at, so PRDDISC-22 can tell it from a real transition.
--  * A failing rebuild never breaks the save of an invoice or a referral: the error goes to commission_rebuild_errors and the rest carries on.

-- 1. matured_at and the error log ---------------------------------------------------------------------------------------------------------
alter table public.commissions add column matured_at timestamptz;
comment on column public.commissions.matured_at is 'First time the invoice was paid while this line existed (= created_at when the line was created for an already paid invoice); never cleared';

create table public.commission_rebuild_errors (
  id         uuid not null primary key default gen_random_uuid(),
  invoice_id uuid,
  sqlstate   text,
  message    text,
  created_at timestamptz not null default now()
);
comment on table public.commission_rebuild_errors is 'Errors raised while rebuilding commission lines (the invoice or referral save still went through); staff read only';
alter table public.commission_rebuild_errors enable row level security;
create policy "commission_rebuild_errors: staff read" on public.commission_rebuild_errors for select to authenticated using ((select private.is_staff()));
revoke all on public.commission_rebuild_errors from public, anon, authenticated;
grant select on public.commission_rebuild_errors to authenticated;
grant all on public.commission_rebuild_errors to service_role;

-- 2. The rebuild of one invoice ------------------------------------------------------------------------------------------------------------
create function private.rebuild_commissions(p_invoice uuid) returns jsonb
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

  -- unprotected lines of referrals that no longer apply (or of an invoice that no longer qualifies) go
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
    -- the base follows a corrected invoice (percentage stays frozen) on lines nobody has invoiced or received yet
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

    -- new lines: the percentage is the referral's today
    with created as (
      insert into public.commissions (invoice_id, referral_id, partner_id, pct, base_cents, amount_cents)
      select p_invoice, r.id, r.partner_id, coalesce(r.commission_pct, 0), d.net_cents, floor(d.net_cents * coalesce(r.commission_pct, 0) / 100 + 0.5)::bigint
        from public.referrals r
       where r.company_id = d.company_id and r.partner_id is not null and private.referral_active_on(r.id, d.issue_date)
         and not exists (select 1 from public.commissions c where c.invoice_id = p_invoice and c.referral_id = r.id)
      returning 1)
    select count(*) into ins from created;
  end if;

  -- maturation: the first time the invoice is paid
  if d.status = 'Incassata' then
    with m as (update public.commissions set matured_at = now() where invoice_id = p_invoice and matured_at is null returning 1)
    select count(*) into mat from m;
  end if;
  return jsonb_build_object('inserted', ins, 'updated', upd, 'deleted', del, 'matured', mat);
end $$;
comment on function private.rebuild_commissions(uuid) is 'Zite aggiornaProvvigioniFattura for one invoice: creates, follows and removes the unprotected commission lines; sets matured_at; idempotent';

-- The one the triggers call: an error is logged, the invoice or referral save carries on.
create function private.rebuild_commissions_safe(p_invoice uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.rebuild_commissions(p_invoice);
exception when others then
  insert into public.commission_rebuild_errors (invoice_id, sqlstate, message) values (p_invoice, sqlstate, left(sqlerrm, 500));
end $$;

-- 3. Triggers ------------------------------------------------------------------------------------------------------------------------------
create function private.commissions_after_document() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.rebuild_commissions_safe(new.id);
  return null;
end $$;
create trigger qonto_documents_rebuild_commissions_ins after insert on public.qonto_documents
  for each row execute function private.commissions_after_document();
-- the Qonto sync rewrites every column on every run: only a change that matters rebuilds
create trigger qonto_documents_rebuild_commissions_upd after update on public.qonto_documents
  for each row when (old.kind is distinct from new.kind or old.status is distinct from new.status or old.company_id is distinct from new.company_id
                     or old.pratica_id is distinct from new.pratica_id or old.net_cents is distinct from new.net_cents
                     or old.issue_date is distinct from new.issue_date or old.removed_at is distinct from new.removed_at)
  execute function private.commissions_after_document();

create function private.commissions_after_referral() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  companies uuid[];
  inv uuid;
begin
  if tg_op = 'UPDATE' and old.company_id is not distinct from new.company_id and old.partner_id is not distinct from new.partner_id
     and old.commission_pct is not distinct from new.commission_pct and old.starts_on is not distinct from new.starts_on
     and old.ends_on is not distinct from new.ends_on and old.removed_at is not distinct from new.removed_at then
    return null;
  end if;
  companies := array_remove(array[case when tg_op <> 'INSERT' then old.company_id end, case when tg_op <> 'DELETE' then new.company_id end], null);
  if cardinality(companies) = 0 then return null; end if;
  for inv in select d.id from public.qonto_documents d where d.company_id = any(companies) and d.pratica_id is not null loop
    perform private.rebuild_commissions_safe(inv);
  end loop;
  return null;
end $$;
create trigger referrals_rebuild_commissions after insert or update or delete on public.referrals
  for each row execute function private.commissions_after_referral();

-- 4. Repair for admins ---------------------------------------------------------------------------------------------------------------------
create function private.rebuild_all_commissions() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  inv uuid;
  r jsonb;
  total jsonb := jsonb_build_object('invoices', 0, 'inserted', 0, 'updated', 0, 'deleted', 0, 'matured', 0, 'errors', 0);
begin
  for inv in select id from public.qonto_documents loop
    begin
      r := private.rebuild_commissions(inv);
      total := jsonb_build_object('invoices', (total->>'invoices')::int + 1, 'inserted', (total->>'inserted')::int + (r->>'inserted')::int,
                                  'updated', (total->>'updated')::int + (r->>'updated')::int, 'deleted', (total->>'deleted')::int + (r->>'deleted')::int,
                                  'matured', (total->>'matured')::int + (r->>'matured')::int, 'errors', (total->>'errors')::int);
    exception when others then
      insert into public.commission_rebuild_errors (invoice_id, sqlstate, message) values (inv, sqlstate, left(sqlerrm, 500));
      total := jsonb_set(total, '{errors}', to_jsonb((total->>'errors')::int + 1));
    end;
  end loop;
  return total;
end $$;

create function public.rebuild_all_commissions() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.profiles where id = (select auth.uid()) and role = 'staff' and staff_role = 'admin') then
    raise exception 'only an administrator can rebuild all commissions' using errcode = '42501';
  end if;
  return private.rebuild_all_commissions();
end $$;
comment on function public.rebuild_all_commissions() is 'Repair for administrators: rebuilds the commission lines of every invoice (idempotent); returns the counts';

revoke execute on function private.rebuild_commissions(uuid) from public, anon, authenticated;
revoke execute on function private.rebuild_commissions_safe(uuid) from public, anon, authenticated;
revoke execute on function private.commissions_after_document() from public, anon, authenticated;
revoke execute on function private.commissions_after_referral() from public, anon, authenticated;
revoke execute on function private.rebuild_all_commissions() from public, anon, authenticated;
revoke execute on function public.rebuild_all_commissions() from public, anon;
grant execute on function public.rebuild_all_commissions() to authenticated;

-- 5. First run for what exists today (idempotent) --------------------------------------------------------------------------------------------
select private.rebuild_all_commissions();
