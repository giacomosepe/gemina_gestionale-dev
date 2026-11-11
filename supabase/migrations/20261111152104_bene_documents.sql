-- Documenti del singolo bene (piano 11 nov 2026, parte A; decisione Giacomo: il file sta su Drive, qui solo il riferimento).
-- Un dato del catalogo di tipo Documento e «Uno per ogni bene» (preventivo, certificazione, conferma d'ordine…) ha, per ogni bene, zero o più file:
-- il file è su Drive nella sottocartella «Beni/<nome del bene>» della pratica (beni.drive_folder), o un link Drive incollato.
-- Solo staff, come beni e bene_values; si scrive dalla Edge Function «beni» a nome del collega. Un documento tolto resta (removed_at).

alter table public.beni add column drive_folder text check (drive_folder ~ '^[A-Za-z0-9_-]{10,200}$');
comment on column public.beni.drive_folder is 'Cartella Drive del bene («Beni/<nome>» dentro la cartella della pratica), creata al primo documento caricato.';

create table public.bene_documents (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations(id),
  bene_id         uuid not null references public.beni(id) on delete cascade,
  dato_id         text not null check (char_length(dato_id) between 1 and 100),
  name            text not null check (char_length(btrim(name)) between 1 and 255),
  drive_file_id   text check (drive_file_id ~ '^[A-Za-z0-9_-]{10,200}$'),
  link            text check (char_length(link) <= 1000 and link ~ '^https://'),
  valid_until     date,
  removed_at      timestamptz,
  created_by      uuid default auth.uid() references public.profiles(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint bene_documents_file_o_link check (drive_file_id is not null or link is not null)
);
create index bene_documents_bene_idx on public.bene_documents (bene_id) where removed_at is null;
comment on table public.bene_documents is 'Documenti di un bene (dato del catalogo di tipo Documento, «Uno per ogni bene»): riferimento al file su Drive. Il file non sta su Supabase.';

create or replace function private.bene_documents_before_write()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.bene_id is distinct from old.bene_id then
    raise exception 'un documento non passa a un altro bene';
  end if;
  select organization_id into new.organization_id from public.beni where id = new.bene_id;
  new.updated_at := now();
  if tg_op = 'INSERT' then new.created_by := coalesce((select auth.uid()), new.created_by); end if;
  return new;
end $$;
revoke execute on function private.bene_documents_before_write() from public, anon, authenticated;
create trigger bene_documents_before_write before insert or update on public.bene_documents for each row execute function private.bene_documents_before_write();

alter table public.bene_documents enable row level security;
create policy "bene_documents: staff manage" on public.bene_documents for all to authenticated
  using ((select private.is_staff())) with check ((select private.is_staff()));
revoke all on public.bene_documents from anon, authenticated;
grant select, insert, update on public.bene_documents to authenticated;
