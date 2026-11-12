-- Recovered on 2026-11-09 from production's migration history (supabase_migrations.schema_migrations, version 20261106152226):
-- applied without a file in the repo (CLAUDE.md rule 2). Text exactly as recorded.

-- Portale di caricamento fatture: un link per cliente (azienda), i file passano da un bucket privato e poi vanno su Drive.

create table public.upload_portals (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations(id),
  company_id      uuid not null references public.companies(id),
  token_hash      text not null unique check (char_length(token_hash) = 64),
  label           text check (char_length(label) <= 200),
  created_by      uuid default auth.uid() references public.profiles(id),
  created_at      timestamptz not null default now(),
  expires_at      timestamptz not null,
  revoked_at      timestamptz,
  last_used_at    timestamptz
);
comment on table public.upload_portals is 'Link del portale di caricamento fatture: uno per cliente. Si salva solo l''impronta (sha256) del codice; il codice in chiaro si vede una volta sola alla creazione.';
create index upload_portals_company_idx on public.upload_portals(company_id);

create table public.upload_portal_files (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations(id),
  portal_id       uuid not null references public.upload_portals(id),
  company_id      uuid not null references public.companies(id),
  pratica_id      uuid not null references public.pratiche(id),
  file_name       text not null check (char_length(file_name) between 1 and 255),
  storage_path    text not null unique,
  size_bytes      bigint check (size_bytes >= 0),
  status          text not null default 'pending' check (status in ('pending','uploaded','transferred','failed')),
  created_at      timestamptz not null default now(),
  uploaded_at     timestamptz,
  transferred_at  timestamptz,
  drive_file_id   text,
  error           text check (char_length(error) <= 1000)
);
comment on table public.upload_portal_files is 'File caricati dal cliente dal portale. pending = URL firmato dato, uploaded = nel bucket portal-uploads, transferred = copiato su Drive (e tolto dal bucket), failed = errore (vedi error).';
create index upload_portal_files_pratica_idx on public.upload_portal_files(pratica_id, status);
create index upload_portal_files_portal_idx on public.upload_portal_files(portal_id, created_at);

alter table public.upload_portals enable row level security;
alter table public.upload_portal_files enable row level security;

-- Solo lo staff legge (la scrittura passa dalle funzioni e dalla Edge Function con chiave di servizio).
create policy upload_portals_staff_read on public.upload_portals for select to authenticated
  using (private.is_staff() and organization_id = (select p.organization_id from public.profiles p where p.id = (select auth.uid())));
create policy upload_portal_files_staff_read on public.upload_portal_files for select to authenticated
  using (private.is_staff() and organization_id = (select p.organization_id from public.profiles p where p.id = (select auth.uid())));
revoke all on public.upload_portals, public.upload_portal_files from anon, authenticated;
grant select on public.upload_portals, public.upload_portal_files to authenticated;

-- Bucket privato: niente policy, si entra solo con URL firmati dati dalla Edge Function.
insert into storage.buckets (id, name, public, file_size_limit)
values ('portal-uploads', 'portal-uploads', false, 524288000)
on conflict (id) do nothing;

-- Crea un link per un cliente: restituisce il codice in chiaro (una sola volta).
create or replace function public.create_upload_portal(p_company uuid, p_label text default null, p_days int default 90)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare v_token text; v_id uuid; v_org uuid; v_exp timestamptz;
begin
  if not private.is_staff() then
    raise exception 'Solo lo staff può creare un link di caricamento.' using errcode = '42501';
  end if;
  if p_days is null or p_days < 1 or p_days > 365 then
    raise exception 'La durata del link deve essere tra 1 e 365 giorni.' using errcode = '22023';
  end if;
  select organization_id into v_org from public.companies where id = p_company;
  if v_org is null then
    raise exception 'Azienda non trovata.' using errcode = '22023';
  end if;
  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  v_exp := now() + make_interval(days => p_days);
  insert into public.upload_portals (organization_id, company_id, token_hash, label, expires_at)
  values (v_org, p_company, encode(sha256(convert_to(v_token, 'utf8')), 'hex'), nullif(btrim(p_label), ''), v_exp)
  returning id into v_id;
  return jsonb_build_object('portal_id', v_id, 'token', v_token, 'expires_at', v_exp);
end $$;

create or replace function public.revoke_upload_portal(p_portal uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
begin
  if not private.is_staff() then
    raise exception 'Solo lo staff può revocare un link di caricamento.' using errcode = '42501';
  end if;
  update public.upload_portals set revoked_at = coalesce(revoked_at, now()) where id = p_portal;
end $$;

revoke all on function public.create_upload_portal(uuid, text, int) from public, anon;
revoke all on function public.revoke_upload_portal(uuid) from public, anon;
grant execute on function public.create_upload_portal(uuid, text, int) to authenticated;
grant execute on function public.revoke_upload_portal(uuid) to authenticated;
