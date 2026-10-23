-- Hardening of the commissions guard (Linear PRDDISC-16, two findings of the code review on PR #6). Replaces private.commissions_guard() only:
--  1. a line must be for the company of its referral (the referral's company is the invoice's company), not just for the referral's own partner;
--  2. once a line is received (paid_on set) its base and amount never change (Zite: "Paid lines are never touched").
-- Additive: no table or column changes.

create or replace function private.commissions_guard() returns trigger
language plpgsql set search_path = '' as $$
declare
  d record;
  r record;
begin
  if tg_op = 'INSERT' then
    select kind, status, removed_at, company_id into d from public.qonto_documents where id = new.invoice_id;
    if d.kind is distinct from 'invoice' then
      raise exception 'a commission line is only for an invoice (not a credit note)' using errcode = '23514';
    end if;
    if d.status = 'Annullata' or d.removed_at is not null then
      raise exception 'a cancelled or removed invoice gets no commission line' using errcode = '23514';
    end if;
    select partner_id, company_id into r from public.referrals where id = new.referral_id;
    if r.partner_id is distinct from new.partner_id then
      raise exception 'partner_id must be the partner of the referral' using errcode = '23514';
    end if;
    if d.company_id is null or r.company_id is distinct from d.company_id then
      raise exception 'the referral must be for the company of the invoice' using errcode = '23514';
    end if;
  else
    if new.invoice_id <> old.invoice_id or new.referral_id <> old.referral_id or new.partner_id <> old.partner_id or new.pct <> old.pct then
      raise exception 'invoice, referral, partner and percentage of a commission line are frozen' using errcode = '23514';
    end if;
    if old.paid_on is not null and (new.base_cents <> old.base_cents or new.amount_cents <> old.amount_cents) then
      raise exception 'a received commission line (paid_on set) keeps its base and amount' using errcode = '23514';
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
