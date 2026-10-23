-- Commissions (Linear PRDDISC-16, milestone M4). One line per invoice and active referral: what a segnalatore earns on one invoice of a company he referred.
-- Rules of PRDDISC-1: commission on the WHOLE net amount (no first-invoice / setup-fee exclusion anywhere); credit notes and cancelled invoices never get a line;
-- percentage and base are frozen on the line when it is created (the base alone may follow a corrected invoice amount while the line is not received);
-- amount in cents, rounded half up (Zite round2 on euros gives the same figure).
-- Stages as in Zite (STADIO_PROVVIGIONE, tassonomia.ts), forward only: Provvigioni teoriche -> maturate (invoice paid) -> fatturate (the segnalatore's own
-- invoice number is recorded) -> ricevute (paid_on set). This issue only stores and shows them: the lines are created by the rebuild function (PRDDISC-20),
-- the stage moves by the mark functions (PRDDISC-21). Staff read only; no partner policy yet (a partner function comes later); writes only through the
-- service role or those functions. Additive only.

create table public.commissions (
  id                     uuid not null primary key default gen_random_uuid(),
  invoice_id             uuid not null references public.qonto_documents(id) on delete restrict,
  referral_id            uuid not null references public.referrals(id) on delete restrict,
  partner_id             uuid not null references public.partners(id) on delete restrict,
  pct                    numeric not null check (pct >= 0 and pct <= 100),
  base_cents             bigint not null check (base_cents >= 0),
  amount_cents           bigint not null,
  partner_invoice_number text check (char_length(partner_invoice_number) <= 100),
  partner_invoiced_on    date,
  paid_on                date,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  organization_id        uuid not null default private.default_organization_id() references public.organizations(id) on delete restrict,
  constraint commissions_invoice_referral_key unique (invoice_id, referral_id),
  -- half up, in exact arithmetic: base x pct / 100, then +0.5 and floor (both are never negative)
  constraint commissions_amount_rounding check (amount_cents = floor(base_cents * pct / 100 + 0.5))
);
create index commissions_referral_id_idx on public.commissions (referral_id);
create index commissions_partner_id_idx on public.commissions (partner_id);
create index commissions_organization_id_idx on public.commissions (organization_id);

comment on table public.commissions is 'Commission lines: one per invoice and referral; pct and base frozen at creation; written only by the service role or the commission functions';
comment on column public.commissions.pct is 'Referral commission_pct at the time the line was created; never changes';
comment on column public.commissions.base_cents is 'Net amount of the invoice (whole net, no exclusions); may follow a corrected invoice while the line is not received';
comment on column public.commissions.amount_cents is 'base x pct / 100 in cents, rounded half up (checked by the table)';
comment on column public.commissions.partner_invoice_number is 'The segnalatore''s own invoice to Gemina; set = stage Provvigioni fatturate';
comment on column public.commissions.paid_on is 'Day Gemina paid the segnalatore; set = stage Provvigioni ricevute';

-- A line is only for a real invoice (not a credit note, not cancelled, not removed in Qonto) of the referral's own partner; who and how much never change afterwards.
create function private.commissions_guard() returns trigger
language plpgsql set search_path = '' as $$
declare
  d record;
  r record;
begin
  if tg_op = 'INSERT' then
    select kind, status, removed_at into d from public.qonto_documents where id = new.invoice_id;
    if d.kind is distinct from 'invoice' then
      raise exception 'a commission line is only for an invoice (not a credit note)' using errcode = '23514';
    end if;
    if d.status = 'Annullata' or d.removed_at is not null then
      raise exception 'a cancelled or removed invoice gets no commission line' using errcode = '23514';
    end if;
    select partner_id into r from public.referrals where id = new.referral_id;
    if r.partner_id is distinct from new.partner_id then
      raise exception 'partner_id must be the partner of the referral' using errcode = '23514';
    end if;
  else
    if new.invoice_id <> old.invoice_id or new.referral_id <> old.referral_id or new.partner_id <> old.partner_id or new.pct <> old.pct then
      raise exception 'invoice, referral, partner and percentage of a commission line are frozen' using errcode = '23514';
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger commissions_guard before insert or update on public.commissions
  for each row execute function private.commissions_guard();
revoke execute on function private.commissions_guard() from public, anon, authenticated;

-- The stage of every line, with the invoice and the segnalatore. Names and order are Zite's (STADIO_PROVVIGIONE); security_invoker: RLS of the base tables applies.
create view public.commission_stages_v with (security_invoker = true) as
select c.id, c.invoice_id, d.number as invoice_number, d.status as invoice_status, d.issue_date as invoice_issue_date, d.paid_at as invoice_paid_at,
       d.company_id, d.pratica_id, c.referral_id, c.partner_id, p.name as partner_name,
       c.pct, c.base_cents, c.amount_cents, c.partner_invoice_number, c.partner_invoiced_on, c.paid_on,
       case when c.paid_on is not null then 'Provvigioni ricevute'
            when nullif(btrim(c.partner_invoice_number), '') is not null then 'Provvigioni fatturate'
            when d.status = 'Incassata' then 'Provvigioni maturate'
            else 'Provvigioni teoriche' end as stage,
       case when c.paid_on is not null then 4
            when nullif(btrim(c.partner_invoice_number), '') is not null then 3
            when d.status = 'Incassata' then 2
            else 1 end as stage_order,
       c.created_at
  from public.commissions c
  join public.qonto_documents d on d.id = c.invoice_id
  join public.partners p on p.id = c.partner_id;
comment on view public.commission_stages_v is 'Stage of each commission line: teoriche (invoice not paid), maturate (invoice paid), fatturate (partner invoice number set), ricevute (paid_on set)';

alter table public.commissions enable row level security;
create policy "commissions: staff read" on public.commissions for select to authenticated using ((select private.is_staff()));
revoke all on public.commissions from public, anon, authenticated;
grant select on public.commissions to authenticated;
grant all on public.commissions to service_role;
revoke all on public.commission_stages_v from public, anon, authenticated;
grant select on public.commission_stages_v to authenticated;
grant all on public.commission_stages_v to service_role;
