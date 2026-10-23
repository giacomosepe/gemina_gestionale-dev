-- Referrals mirror (Linear PRDDISC-13, milestone M3). A read-only copy of each Zite Segnalazione (segnalatore x azienda, with the commission percentage and
-- the validity period), kept in step by Zite through the portal-bridge (actions sync_referral and resync_referrals), the way segnalatori and pratiche are.
-- Zite stays the source of truth; nothing is recomputed here (ends_on is the Scadenza Zite stores: calcolaScadenza). The free-text Note is not mirrored.
-- Built so a later fuller migration only ADDS columns: same table, same key (id = the Zite record UUID).
-- Staff read only; no partner or client policy here (PRDDISC-14 adds what a segnalatore may see); writes only through the bridge (private.sync_referrals).
-- Additive only.

create table public.referrals (
  id                  uuid not null primary key,
  partner_id          uuid references public.partners(id) on delete set null,
  company_id          uuid references public.companies(id) on delete set null,
  zite_segnalatore_id text check (char_length(zite_segnalatore_id) <= 100),
  zite_azienda_id     text check (char_length(zite_azienda_id) <= 100),
  commission_pct      numeric,
  starts_on           date,
  duration_years      numeric,
  ends_on             date,
  removed_at          timestamptz,
  synced_at           timestamptz not null default now(),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  organization_id     uuid not null default private.default_organization_id() references public.organizations(id) on delete restrict
);
create index referrals_partner_id_idx on public.referrals (partner_id) where partner_id is not null;
create index referrals_company_id_idx on public.referrals (company_id) where company_id is not null;
create index referrals_zite_segnalatore_id_idx on public.referrals (zite_segnalatore_id) where zite_segnalatore_id is not null;
create index referrals_zite_azienda_id_idx on public.referrals (zite_azienda_id) where zite_azienda_id is not null;
create index referrals_organization_id_idx on public.referrals (organization_id);

comment on table public.referrals is 'Read-only mirror of the Zite Segnalazioni (segnalatore x azienda; id = Zite UUID); written only by the portal-bridge; later migrations only add columns';
comment on column public.referrals.partner_id is 'Resolved from zite_segnalatore_id through partners.zite_segnalatore_id (null until that partner exists in Supabase)';
comment on column public.referrals.company_id is 'Resolved from zite_azienda_id through companies.zite_azienda_id (null until that azienda exists in Supabase)';
comment on column public.referrals.commission_pct is 'Zite Provvigione (%), as sent';
comment on column public.referrals.starts_on is 'Zite Dal';
comment on column public.referrals.duration_years is 'Zite Durata (anni), empty = no end';
comment on column public.referrals.ends_on is 'Zite Scadenza (computed by Zite from Dal and the duration: 31 December of the last year); null = no end';
comment on column public.referrals.removed_at is 'Set when the segnalazione no longer exists in Zite (kept, never deleted)';

create function private.referrals_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.partner_id := (select p.id from public.partners p where p.zite_segnalatore_id = new.zite_segnalatore_id);
  new.company_id := (select c.id from public.companies c where c.zite_azienda_id = new.zite_azienda_id);
  new.updated_at := now();
  return new;
end $$;
create trigger referrals_before_write before insert or update on public.referrals
  for each row execute function private.referrals_before_write();

-- The one writer: p_rows = json array of {id, zite_segnalatore_id, zite_azienda_id, commission_pct, starts_on, duration_years, ends_on, removed}.
-- With p_mark_missing every other referral (not already removed) gets removed_at (repair after a delete whose sync was lost).
create function private.sync_referrals(p_rows jsonb, p_mark_missing boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  ins  int := 0;
  upd  int := 0;
  gone int := 0;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows must be a json array' using errcode = '22023';
  end if;
  with up as (
    insert into public.referrals as t (id, zite_segnalatore_id, zite_azienda_id, commission_pct, starts_on, duration_years, ends_on, removed_at, synced_at)
    select r.id, r.zite_segnalatore_id, r.zite_azienda_id, r.commission_pct, r.starts_on, r.duration_years, r.ends_on,
           case when r.removed then now() end, now()
      from jsonb_to_recordset(p_rows) as r(id uuid, zite_segnalatore_id text, zite_azienda_id text, commission_pct numeric, starts_on date,
                                           duration_years numeric, ends_on date, removed boolean)
    on conflict (id) do update set
      zite_segnalatore_id = excluded.zite_segnalatore_id, zite_azienda_id = excluded.zite_azienda_id, commission_pct = excluded.commission_pct,
      starts_on = excluded.starts_on, duration_years = excluded.duration_years, ends_on = excluded.ends_on,
      removed_at = case when excluded.removed_at is null then null else coalesce(t.removed_at, excluded.removed_at) end,
      synced_at = now()
    returning (xmax = 0) as inserted)
  select count(*) filter (where inserted), count(*) filter (where not inserted) into ins, upd from up;

  if p_mark_missing and jsonb_array_length(p_rows) > 0 then
    update public.referrals set removed_at = now()
     where removed_at is null and id not in (select (e->>'id')::uuid from jsonb_array_elements(p_rows) e);
    get diagnostics gone = row_count;
  end if;
  return jsonb_build_object('inserted', ins, 'updated', upd, 'marked_removed', gone);
end $$;

-- Is a referral active on a date? The rule Zite uses to pick the segnalazioni of an invoice (provvigioni.ts, attiva): not before Dal, not after Scadenza;
-- an empty Dal or Scadenza is open on that side. A removed referral (or one that does not exist) is never active.
create function private.referral_active_on(p_referral uuid, p_date date) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select r.removed_at is null
                          and (r.starts_on is null or p_date >= r.starts_on)
                          and (r.ends_on is null or p_date <= r.ends_on)
                     from public.referrals r where r.id = p_referral), false);
$$;
comment on function private.referral_active_on(uuid, date) is 'Zite rule attiva(): Dal <= date <= Scadenza (empty = open); removed or unknown = false';

revoke execute on function private.referrals_before_write() from public, anon, authenticated;
revoke execute on function private.sync_referrals(jsonb, boolean) from public, anon, authenticated;
revoke execute on function private.referral_active_on(uuid, date) from public, anon;
grant execute on function private.referral_active_on(uuid, date) to authenticated, service_role;

alter table public.referrals enable row level security;
create policy "referrals: staff read" on public.referrals for select to authenticated using ((select private.is_staff()));
revoke all on public.referrals from public, anon, authenticated;
grant select on public.referrals to authenticated;
grant all on public.referrals to service_role;
