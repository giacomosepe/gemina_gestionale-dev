-- Beni: la lista principale passa su Supabase (decisione Giacomo 10 nov 2026: i dati sensibili per i clienti — beni, brevetti, fornitori,
-- dipendenti — stanno nel progetto europeo, non su Zite). Prima la lista stava in un testo JSON su Zite (Pratiche.beni, Trattative.beni)
-- e qui arrivava solo una copia all'import delle fatture fornitori.
--
-- 1) Un bene può nascere su una TRATTATIVA (record Zite, che su Supabase non ha copia): trattativa_zite_id. Quando c'è la pratica il bene
--    vi passa (pratica_id da vuoto a valorizzato); poi non cambia più pratica (regola di prima).
-- 2) Campi fissi del bene: name (c'era), supplier_hint (c'era: il fornitore indicato), order_date, ordered, position.
--    Un bene creato dal Gestionale ha zite_bene_id = il proprio id: così l'import delle fatture (private.sync_pratica_beni) lo riconosce
--    come bene «gestito» e mette da parte il segnaposto col nome della pratica se non ha fatture assegnate. Nessun cambio all'import.
-- 3) bene_values: il valore di un dato del catalogo (Zite, tabella Dati, «si salva su Bene») per un bene. Uno per bene e dato.
-- Accesso: solo staff, come beni. Si scrive dalla Edge Function «beni» a nome del collega.

alter table public.beni
  alter column pratica_id drop not null,
  add column trattativa_zite_id text check (char_length(trattativa_zite_id) between 1 and 100),
  add column order_date date,
  add column ordered boolean not null default false,
  add column position smallint not null default 0,
  add constraint beni_pratica_o_trattativa check (pratica_id is not null or trattativa_zite_id is not null);
create index beni_trattativa_idx on public.beni (trattativa_zite_id) where trattativa_zite_id is not null;
comment on column public.beni.trattativa_zite_id is 'Trattativa Zite su cui il bene è nato (anche dopo il passaggio alla pratica).';
comment on column public.beni.zite_bene_id is 'Bene «gestito»: id del vecchio elenco Zite o, per i beni creati dal Gestionale dal 10 nov, il proprio id. Vuoto = segnaposto creato dall''import delle fatture.';
comment on table public.beni is 'Beni dell''investimento: lista principale (dal 10 nov 2026). Nascono su una trattativa o su una pratica; passano dalla trattativa alla pratica, poi non cambiano pratica.';

create or replace function private.beni_before_write()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_title text; v_code text; v_org uuid;
begin
  if tg_op = 'UPDATE' and old.pratica_id is not null and new.pratica_id is distinct from old.pratica_id then
    raise exception 'un bene non si sposta su un''altra pratica: cancellalo e ricrealo';
  end if;
  if new.pratica_id is not null then
    select id, title, code, organization_id into v_id, v_title, v_code, v_org from public.pratiche where id = new.pratica_id;
    if v_id is null then
      raise exception 'pratica non trovata';
    end if;
    new.organization_id := v_org;
  end if;
  if new.name is null or btrim(new.name) = '' then
    new.name := coalesce(nullif(btrim(v_title), ''), nullif(btrim(v_code), ''), 'Bene');
  end if;
  return new;
end $$;

create table public.bene_values (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations(id),
  bene_id         uuid not null references public.beni(id) on delete cascade,
  dato_id         text not null check (char_length(dato_id) between 1 and 100),
  value           text check (char_length(value) <= 20000),
  updated_by      uuid default auth.uid() references public.profiles(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (bene_id, dato_id)
);
comment on table public.bene_values is 'Valore di un dato del catalogo (Zite: Dati, «si salva su Bene») per un bene. Testo, come Valori campi su Zite.';

create or replace function private.bene_values_before_write()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  select organization_id into new.organization_id from public.beni where id = new.bene_id;
  new.updated_at := now();
  new.updated_by := coalesce((select auth.uid()), new.updated_by);
  return new;
end $$;
revoke execute on function private.bene_values_before_write() from public, anon, authenticated;
create trigger bene_values_before_write before insert or update on public.bene_values for each row execute function private.bene_values_before_write();

alter table public.bene_values enable row level security;
create policy "bene_values: staff manage" on public.bene_values for all to authenticated
  using ((select private.is_staff())) with check ((select private.is_staff()));
revoke all on public.bene_values from anon, authenticated;
grant select, insert, update, delete on public.bene_values to authenticated;
