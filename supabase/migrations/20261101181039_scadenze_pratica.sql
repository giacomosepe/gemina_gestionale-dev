-- Recovered on 2026-11-09 from production's migration history (supabase_migrations.schema_migrations, version 20261101181039):
-- applied without a file in the repo (CLAUDE.md rule 2). Text exactly as recorded.

-- The scadenze (deliverables: Domanda, Rendicontazioni, Fascicolo…) of each pratica (2026-11-01, Output / Scadenze, step 2a).
-- Created from the categoria's / servizio's model (Zite) the first time a pratica's Scadenze tab opens; «+ Aggiungi scadenza» adds one more of an
-- existing type. Values are never stored here (they stay in Zite); a scadenza is archived, never deleted.
create table public.scadenze (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations(id) on delete restrict,
  pratica_id uuid not null references public.pratiche(id) on delete restrict,
  tipo text not null check (tipo ~ '^[a-z0-9_-]{1,40}$'),
  numero smallint not null check (numero between 1 and 50),
  nome text not null check (char_length(btrim(nome)) between 1 and 120),
  ordine smallint not null default 0 check (ordine between 0 and 500),
  data date,
  consegnata_il date,
  ricevuta text check (ricevuta is null or (char_length(ricevuta) <= 1000 and ricevuta ~ '^https://')),
  archiviata boolean not null default false,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- one row per pratica × type × number: two colleagues opening the tab together cannot create the same scadenze twice
  constraint scadenze_pratica_tipo_numero_key unique (pratica_id, tipo, numero)
);

comment on table public.scadenze is 'Scadenze (consegne) di ogni pratica: Domanda, Rendicontazioni, Fascicolo… Tipi dal modello della categoria/servizio in Zite. Si archiviano, non si cancellano.';

create index scadenze_organization_id_idx on public.scadenze (organization_id);
create index scadenze_created_by_idx on public.scadenze (created_by);

create or replace function private.scadenze_before_write()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  new.updated_at := now();
  new.nome := btrim(new.nome);
  if tg_op = 'INSERT' then
    -- only on a pratica of the mirror that is still there
    if not exists (select 1 from public.pratiche p where p.id = new.pratica_id and p.removed_at is null) then
      raise exception 'pratica non trovata' using errcode = '23503';
    end if;
    new.created_by := coalesce((select auth.uid()), new.created_by);
    new.organization_id := private.default_organization_id();
    new.created_at := now();
  else
    -- what identifies a scadenza never changes
    new.id := old.id;
    new.organization_id := old.organization_id;
    new.pratica_id := old.pratica_id;
    new.tipo := old.tipo;
    new.numero := old.numero;
    new.created_by := old.created_by;
    new.created_at := old.created_at;
  end if;
  return new;
end $$;

create trigger scadenze_a_before_write
  before insert or update on public.scadenze
  for each row execute function private.scadenze_before_write();

alter table public.scadenze enable row level security;

create policy "scadenze: staff read" on public.scadenze
  for select to authenticated using ((select private.is_staff()));
create policy "scadenze: staff insert" on public.scadenze
  for insert to authenticated with check ((select private.is_staff()));
create policy "scadenze: staff update" on public.scadenze
  for update to authenticated using ((select private.is_staff())) with check ((select private.is_staff()));
-- no delete policy: a scadenza is archived (archiviata = true), never deleted

revoke all on public.scadenze from anon, authenticated;
grant select, insert, update on public.scadenze to authenticated;
