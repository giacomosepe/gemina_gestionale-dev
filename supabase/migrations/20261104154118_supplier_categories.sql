-- Recovered on 2026-11-09 from production's migration history (supabase_migrations.schema_migrations, version 20261104154118):
-- applied without a file in the repo (CLAUDE.md rule 2). Text exactly as recorded.

-- Category of whoever issues a supplier invoice (Fornitore, Consulente, Collaboratore): ONE per supplier, valid on every pratica and servizio.
-- A table, not an enum: a new category is a new row (the app reads the list), no code change.
create table public.supplier_categories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id(),
  name text not null check (btrim(name) <> ''),
  position int not null default 0,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, name)
);
create trigger supplier_categories_updated_at before update on public.supplier_categories
  for each row execute procedure extensions.moddatetime(updated_at);
alter table public.supplier_categories enable row level security;
create policy "supplier_categories: staff read" on public.supplier_categories for select to authenticated using ((select private.is_staff()));
revoke all on public.supplier_categories from anon;

insert into public.supplier_categories (name, position) values ('Fornitore', 1), ('Consulente', 2), ('Collaboratore', 3);

-- Empty = not classified yet (shown as «Da classificare»): never guessed silently.
alter table public.client_suppliers add column category_id uuid references public.supplier_categories(id) on delete restrict;
create index on public.client_suppliers (category_id);

-- Sets the category of one or more suppliers (the pill, single or in bulk). Staff only; null = back to «Da classificare».
create or replace function public.set_supplier_category(p_supplier_ids uuid[], p_category_id uuid)
 returns int language plpgsql security definer set search_path to ''
as $$
declare n int;
begin
  if not (select private.is_staff()) then raise exception 'Non autorizzato' using errcode = '42501'; end if;
  if p_category_id is not null and not exists (select 1 from public.supplier_categories where id = p_category_id and archived_at is null) then
    raise exception 'Categoria non valida' using errcode = '22023';
  end if;
  update public.client_suppliers set category_id = p_category_id where id = any (p_supplier_ids);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.set_supplier_category(uuid[], uuid) from public, anon;
grant execute on function public.set_supplier_category(uuid[], uuid) to authenticated;
