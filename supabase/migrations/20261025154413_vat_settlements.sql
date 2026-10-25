-- VAT settlements entered by hand (Linear PRDDISC-17, milestone M4). Zite table "Liquidazioni IVA", written by gestisciLiquidazioniIva and read by flussoCassa:
-- for one quarter, the IVA a credito on other purchases and (Q4 only) the December IVA advance. One row per year and quarter; empty = no figure.
-- Same meaning as Zite, no new fields: period (label "T1 2027"), year, quarter, vat_credit_other_cents (IVA a credito altri acquisti), vat_advance_cents (Acconto IVA),
-- note (Zite has the field; the endpoint never writes it). Money in integer cents. The Zite UUID is the primary key, so the backfill can run again.
-- Who: staff read; insert, update and delete only for administrators (Zite: richiediAdmin in gestisciLiquidazioniIva). No partner or client policy.
-- Additive: no screens, no bridge action, nothing else changes.

create table public.vat_settlements (
  id                     uuid not null primary key default gen_random_uuid(),
  period                 text not null check (char_length(period) <= 20),
  year                   integer not null check (year between 2000 and 2100),
  quarter                smallint not null check (quarter between 1 and 4),
  vat_credit_other_cents bigint check (vat_credit_other_cents >= 0 and vat_credit_other_cents <= 100000000000),
  vat_advance_cents      bigint check (vat_advance_cents >= 0 and vat_advance_cents <= 100000000000),
  note                   text check (char_length(note) <= 5000),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  organization_id        uuid not null default private.default_organization_id() references public.organizations(id) on delete restrict,
  constraint vat_settlements_year_quarter_key unique (year, quarter),
  -- Zite: "L'acconto IVA si inserisce nel quarto trimestre."
  constraint vat_settlements_advance_q4 check (vat_advance_cents is null or quarter = 4),
  constraint vat_settlements_period_label check (period = 'T' || quarter || ' ' || year)
);
create index vat_settlements_organization_id_idx on public.vat_settlements (organization_id);

comment on table public.vat_settlements is 'Manual VAT settlement figures per quarter (Zite Liquidazioni IVA); staff read, administrators write';
comment on column public.vat_settlements.vat_credit_other_cents is 'IVA a credito on other purchases, any quarter; null = nothing entered';
comment on column public.vat_settlements.vat_advance_cents is 'December IVA advance (acconto), quarter 4 only; null = not entered yet';

create function private.vat_settlements_touch() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;
create trigger vat_settlements_touch before update on public.vat_settlements
  for each row execute function private.vat_settlements_touch();
revoke execute on function private.vat_settlements_touch() from public, anon, authenticated;

alter table public.vat_settlements enable row level security;
create policy "vat_settlements: staff read" on public.vat_settlements for select to authenticated using ((select private.is_staff()));
create policy "vat_settlements: admin insert" on public.vat_settlements for insert to authenticated
  with check ((select private.current_staff_role()) = 'admin');
create policy "vat_settlements: admin update" on public.vat_settlements for update to authenticated
  using ((select private.current_staff_role()) = 'admin') with check ((select private.current_staff_role()) = 'admin');
create policy "vat_settlements: admin delete" on public.vat_settlements for delete to authenticated
  using ((select private.current_staff_role()) = 'admin');
revoke all on public.vat_settlements from public, anon, authenticated;
grant select, insert, update, delete on public.vat_settlements to authenticated;
grant all on public.vat_settlements to service_role;
