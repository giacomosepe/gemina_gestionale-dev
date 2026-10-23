-- Pratiche mirror (Linear PRDDISC-11, milestone M2). A read-only copy of each Zite pratica, kept in step by Zite through the
-- portal-bridge (actions sync_pratica and resync_pratiche), the way segnalatori are. Zite stays the source of truth; Supabase never
-- recomputes anything it is sent. Built so the later full migration of Pratiche only ADDS columns to this table: same table, same key.
--
-- - id = the Zite record UUID (repo convention).
-- - status = Zite's Stato label as is. is_open = NOT praticaChiusa in Zite (closed = Fatturazione completata or Interrotta,
--   Zite src/lib/regole.ts), computed by Zite.
-- - total_fee_cents = "Commissioni totali" = valorePratica in Zite (fixed fee + variable fee, net of VAT), in cents, computed by Zite
--   (src/lib/pratiche/situazioneEconomica.ts). Null when Zite sent none.
-- - company_id is resolved here from zite_azienda_id through companies.zite_azienda_id (null when the azienda is not in Supabase yet;
--   the next sync fills it).
-- - A pratica deleted in Zite is never deleted here: removed_at is set (and cleared if it comes back).
-- - Staff read only; partners and clients nothing; writes only through the bridge (database owner), i.e. private.sync_pratiche.
-- Additive only.

create table public.pratiche (
  id              uuid not null primary key,
  code            text check (char_length(code) <= 100),
  company_id      uuid references public.companies(id) on delete set null,
  zite_azienda_id text check (char_length(zite_azienda_id) <= 100),
  status          text check (char_length(status) <= 100),
  is_open         boolean not null default true,
  total_fee_cents bigint,
  removed_at      timestamptz,
  synced_at       timestamptz not null default now(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  organization_id uuid not null default private.default_organization_id() references public.organizations(id) on delete restrict
);
create index pratiche_company_id_idx on public.pratiche (company_id) where company_id is not null;
create index pratiche_zite_azienda_id_idx on public.pratiche (zite_azienda_id) where zite_azienda_id is not null;
create index pratiche_open_idx on public.pratiche (company_id) where is_open and removed_at is null;
create index pratiche_organization_id_idx on public.pratiche (organization_id);

comment on table public.pratiche is 'Read-only mirror of the Zite Pratiche (id = Zite UUID); written only by the portal-bridge; the full migration will add columns here';
comment on column public.pratiche.code is 'Zite Codice pratica';
comment on column public.pratiche.status is 'Zite Stato label as is';
comment on column public.pratiche.is_open is 'Computed by Zite: not Fatturazione completata and not Interrotta (regole.ts praticaChiusa)';
comment on column public.pratiche.total_fee_cents is 'Commissioni totali (Zite valorePratica: fixed + variable fee, net of VAT), integer cents, computed by Zite';
comment on column public.pratiche.removed_at is 'Set when the pratica no longer exists in Zite (kept, never deleted)';
comment on column public.pratiche.synced_at is 'Last time Zite sent this pratica';

create function private.pratiche_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.company_id := (select c.id from public.companies c where c.zite_azienda_id = new.zite_azienda_id);
  new.updated_at := now();
  return new;
end $$;
create trigger pratiche_before_write before insert or update on public.pratiche
  for each row execute function private.pratiche_before_write();

-- The one writer: p_rows = json array of {id, code, zite_azienda_id, status, is_open, total_fee_cents, removed}. With p_mark_missing,
-- every other pratica (not already removed) gets removed_at (the repair after a delete whose sync was lost).
create function private.sync_pratiche(p_rows jsonb, p_mark_missing boolean default false) returns jsonb
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
    insert into public.pratiche as t (id, code, zite_azienda_id, status, is_open, total_fee_cents, removed_at, synced_at)
    select r.id, r.code, r.zite_azienda_id, r.status, r.is_open, r.total_fee_cents, case when r.removed then now() end, now()
      from jsonb_to_recordset(p_rows) as r(id uuid, code text, zite_azienda_id text, status text, is_open boolean,
                                           total_fee_cents bigint, removed boolean)
    on conflict (id) do update set
      code = excluded.code, zite_azienda_id = excluded.zite_azienda_id, status = excluded.status, is_open = excluded.is_open,
      total_fee_cents = excluded.total_fee_cents,
      removed_at = case when excluded.removed_at is null then null else coalesce(t.removed_at, excluded.removed_at) end,
      synced_at = now()
    returning (xmax = 0) as inserted)
  select count(*) filter (where inserted), count(*) filter (where not inserted) into ins, upd from up;

  if p_mark_missing and jsonb_array_length(p_rows) > 0 then
    update public.pratiche set removed_at = now()
     where removed_at is null and id not in (select (e->>'id')::uuid from jsonb_array_elements(p_rows) e);
    get diagnostics gone = row_count;
  end if;
  return jsonb_build_object('inserted', ins, 'updated', upd, 'marked_removed', gone);
end $$;

revoke execute on function private.pratiche_before_write() from public, anon, authenticated;
revoke execute on function private.sync_pratiche(jsonb, boolean) from public, anon, authenticated;

alter table public.pratiche enable row level security;
create policy "pratiche: staff read" on public.pratiche for select to authenticated using ((select private.is_staff()));
revoke all on public.pratiche from public, anon, authenticated;
grant select on public.pratiche to authenticated;
grant all on public.pratiche to service_role;
