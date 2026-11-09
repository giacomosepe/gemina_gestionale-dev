-- Recovered on 2026-11-09 from production's migration history (supabase_migrations.schema_migrations, version 20261104112817):
-- applied without a file in the repo (CLAUDE.md rule 2). Text exactly as recorded.

-- Fatture dei fornitori dei clienti (giustificativi di spesa delle pratiche)
-- Versione 3 (4/11/2026): con l'azienda beneficiaria della pratica.
-- Modello: un XML = una fattura (un fornitore, un cliente). La fattura va su UNA pratica. Le righe si
-- ripartiscono sui beni della pratica, anche in percentuale; una quota può essere "non applicabile".
-- Regole: un bene non si sposta; una pratica con fatture non cambia cliente né beneficiaria; una fattura
-- non cambia cliente; la pratica deve essere aperta e del beneficiario; "chi ha assegnato" lo scrive il
-- database; gli allegati dell'XML non si salvano. Convenzioni del progetto: organization_id, RLS solo staff,
-- funzioni security definer con search_path vuoto, updated_at con moddatetime.

-- 0. PRATICHE: azienda beneficiaria (caso raro: Gemina subfornitore)
alter table public.pratiche add column beneficiary_company_id uuid references public.companies(id);
comment on column public.pratiche.beneficiary_company_id is
  'Azienda beneficiaria se diversa dal cliente (Gemina subfornitore): le fatture dei fornitori sono intestate a lei. Vuota = il cliente. Solo Supabase, impostata da un admin con public.set_pratica_beneficiary.';

-- 1. BENI
create table public.beni (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations(id),
  pratica_id uuid not null references public.pratiche(id),
  name text not null default '',
  zite_bene_id text unique,
  removed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint beni_name_not_blank check (char_length(btrim(name)) > 0)
);
create index beni_pratica_id_idx on public.beni (pratica_id);
comment on table public.beni is 'Beni di una pratica. Il nome parte dal titolo della pratica ed è modificabile. Un bene non cambia pratica.';

create or replace function private.beni_before_write()
returns trigger language plpgsql security definer set search_path = '' as $$
declare p record;
begin
  if tg_op = 'UPDATE' and new.pratica_id is distinct from old.pratica_id then
    raise exception 'un bene non si sposta su un''altra pratica: cancellalo e ricrealo';
  end if;
  select id, title, code, organization_id into p from public.pratiche where id = new.pratica_id;
  if p.id is null then
    raise exception 'pratica non trovata';
  end if;
  new.organization_id := p.organization_id;
  if new.name is null or btrim(new.name) = '' then
    new.name := coalesce(nullif(btrim(p.title), ''), nullif(btrim(p.code), ''), 'Bene');
  end if;
  return new;
end $$;
create trigger beni_before_write before insert or update on public.beni
  for each row execute function private.beni_before_write();
create trigger beni_updated_at before update on public.beni
  for each row execute function moddatetime('updated_at');

insert into public.beni (pratica_id)
select p.id from public.pratiche p
 where p.removed_at is null
   and not exists (select 1 from public.beni b where b.pratica_id = p.id);

-- 2. FORNITORI DEI CLIENTI
create table public.client_suppliers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations(id),
  country text,
  tax_id text,
  fiscal_code text,
  name text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.client_suppliers is 'Fornitori dei clienti (chi emette le fatture). Diversi dai partners (segnalatori) e dai fornitori di Gemina.';
create unique index client_suppliers_tax_key on public.client_suppliers (organization_id, coalesce(country, ''), tax_id)
  where tax_id is not null;
create unique index client_suppliers_cf_key on public.client_suppliers (organization_id, fiscal_code)
  where tax_id is null and fiscal_code is not null;
create unique index client_suppliers_name_key on public.client_suppliers (organization_id, lower(name))
  where tax_id is null and fiscal_code is null;
create trigger client_suppliers_updated_at before update on public.client_suppliers
  for each row execute function moddatetime('updated_at');

-- 3. REGISTRO DELLE IMPORTAZIONI
create table public.supplier_invoice_import_runs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations(id),
  source text,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  files_seen integer not null default 0,
  inserted_count integer not null default 0,
  duplicate_count integer not null default 0,
  unmatched_company_count integer not null default 0,
  error_count integer not null default 0,
  report jsonb not null default '{}'::jsonb
);

-- 4. FATTURE
create table public.supplier_invoices (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations(id),
  company_id uuid references public.companies(id),
  pratica_id uuid references public.pratiche(id),
  recipient_vat text,
  recipient_name text,
  supplier_id uuid not null references public.client_suppliers(id),
  supplier_name text not null,
  doc_type text not null,
  sign smallint generated always as (case when doc_type in ('TD04', 'TD08') then -1 else 1 end) stored,
  number text not null,
  issue_date date not null,
  currency text not null default 'EUR',
  total_amount numeric(20, 2),
  net_amount numeric(20, 2),
  vat_amount numeric(20, 2),
  rounding_amount numeric(20, 2),
  source_file_name text,
  source_sha256 text not null,
  was_signed boolean not null default false,
  xml_path text,
  pdf_path text,
  check_warnings text[] not null default '{}',
  data jsonb not null default '{}'::jsonb,
  import_run_id uuid references public.supplier_invoice_import_runs(id),
  removed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on column public.supplier_invoices.sign is '-1 per le note di credito (TD04, TD08): nell''XML gli importi sono positivi';
comment on column public.supplier_invoices.data is 'Contenuto letto dall''XML, senza allegati';
create unique index supplier_invoices_sha_key on public.supplier_invoices (organization_id, source_sha256);
create unique index supplier_invoices_doc_key on public.supplier_invoices (organization_id, supplier_id, doc_type, number, issue_date)
  where removed_at is null;
create index supplier_invoices_company_idx on public.supplier_invoices (company_id);
create index supplier_invoices_pratica_idx on public.supplier_invoices (pratica_id);
create index supplier_invoices_supplier_idx on public.supplier_invoices (supplier_id);
create index supplier_invoices_date_idx on public.supplier_invoices (issue_date);
create index supplier_invoices_run_idx on public.supplier_invoices (import_run_id);
create trigger supplier_invoices_updated_at before update on public.supplier_invoices
  for each row execute function moddatetime('updated_at');

create or replace function private.supplier_invoices_before_write()
returns trigger language plpgsql security definer set search_path = '' as $$
declare n int; cid uuid; v_prat record;
begin
  if tg_op = 'UPDATE' and old.company_id is not null and new.company_id is distinct from old.company_id then
    raise exception 'il cliente di una fattura non si cambia: cancellala e ricaricala';
  end if;
  if new.company_id is null and private.vat_key(new.recipient_vat) is not null then
    select count(*), min(id::text)::uuid into n, cid
      from public.companies where vat_number = private.vat_key(new.recipient_vat);
    if n = 1 then new.company_id := cid; end if;
  end if;
  if new.company_id is not null then
    select organization_id into new.organization_id from public.companies where id = new.company_id;
  end if;
  if new.pratica_id is not null and (tg_op = 'INSERT' or new.pratica_id is distinct from old.pratica_id) then
    if new.company_id is null then
      raise exception 'la fattura non è abbinata a nessun cliente: abbinala prima di sceglierne la pratica';
    end if;
    select coalesce(beneficiary_company_id, company_id) as beneficiaria, is_open, removed_at into v_prat
      from public.pratiche where id = new.pratica_id;
    if v_prat.beneficiaria is distinct from new.company_id then
      raise exception 'la fattura è intestata a un''altra azienda rispetto al beneficiario della pratica';
    end if;
    if not v_prat.is_open or v_prat.removed_at is not null then
      raise exception 'la pratica è chiusa: riaprila prima di assegnare fatture';
    end if;
  end if;
  if tg_op = 'UPDATE' and old.pratica_id is not null and new.pratica_id is distinct from old.pratica_id
     and exists (select 1 from public.supplier_invoice_allocations a
                   join public.supplier_invoice_lines l on l.id = a.line_id
                  where l.invoice_id = old.id) then
    raise exception 'la fattura ha già righe assegnate: rimuovi prima le assegnazioni';
  end if;
  return new;
end $$;

-- 5. RIGHE (position = nostra numerazione; line_no = NumeroLinea dell'XML, solo informativo)
create table public.supplier_invoice_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations(id),
  invoice_id uuid not null references public.supplier_invoices(id) on delete cascade,
  position integer not null,
  line_no integer,
  description text,
  quantity numeric,
  unit text,
  period_from date,
  period_to date,
  unit_price numeric(24, 8),
  amount numeric(24, 8) not null,
  total_cents bigint generated always as (round(amount * 100)::bigint) stored,
  vat_rate numeric(6, 2),
  vat_nature text,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (invoice_id, position)
);
create trigger supplier_invoice_lines_updated_at before update on public.supplier_invoice_lines
  for each row execute function moddatetime('updated_at');

create or replace function private.supplier_invoice_lines_before_write()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  select organization_id into new.organization_id from public.supplier_invoices where id = new.invoice_id;
  return new;
end $$;
create trigger supplier_invoice_lines_before_write before insert on public.supplier_invoice_lines
  for each row execute function private.supplier_invoice_lines_before_write();

create trigger supplier_invoices_before_write before insert or update on public.supplier_invoices
  for each row execute function private.supplier_invoices_before_write();

-- 6. RIPARTIZIONE delle righe: sui beni della pratica, oppure "non applicabile"
create table public.supplier_invoice_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations(id),
  line_id uuid not null references public.supplier_invoice_lines(id) on delete cascade,
  bene_id uuid references public.beni(id),
  not_applicable boolean not null default false,
  note text,
  share_pct numeric(7, 4) not null default 100 check (share_pct > 0 and share_pct <= 100),
  assigned_by uuid references public.profiles(id),
  assigned_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint allocation_target check ((bene_id is null) = not_applicable),
  unique (line_id, bene_id)
);
comment on column public.supplier_invoice_allocations.not_applicable is 'Quota della riga che non entra nel calcolo della pratica (bene_id vuoto)';
create unique index supplier_invoice_allocations_na_key on public.supplier_invoice_allocations (line_id) where not_applicable;
create index supplier_invoice_allocations_bene_idx on public.supplier_invoice_allocations (bene_id);
create trigger supplier_invoice_allocations_updated_at before update on public.supplier_invoice_allocations
  for each row execute function moddatetime('updated_at');

create or replace function private.supplier_allocation_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_inv record;
  v_prat record;
  v_bene_pratica uuid;
  v_total numeric;
begin
  select i.pratica_id, i.company_id into v_inv
    from public.supplier_invoice_lines l
    join public.supplier_invoices i on i.id = l.invoice_id
   where l.id = new.line_id
     for update of l;
  if v_inv.pratica_id is null then
    raise exception 'assegna prima la fattura a una pratica';
  end if;

  if tg_op = 'INSERT' or new.bene_id is distinct from old.bene_id
     or new.not_applicable is distinct from old.not_applicable or new.share_pct is distinct from old.share_pct then
    select is_open, removed_at, organization_id into v_prat from public.pratiche where id = v_inv.pratica_id;
    if not v_prat.is_open or v_prat.removed_at is not null then
      raise exception 'la pratica è chiusa: riaprila prima di modificare le assegnazioni';
    end if;
    if not new.not_applicable then
      select b.pratica_id into v_bene_pratica from public.beni b where b.id = new.bene_id and b.removed_at is null;
      if v_bene_pratica is distinct from v_inv.pratica_id then
        raise exception 'il bene non appartiene alla pratica della fattura';
      end if;
    end if;
    new.assigned_by := auth.uid();
    new.assigned_at := now();
    new.organization_id := v_prat.organization_id;
  else
    new.assigned_by := old.assigned_by;
    new.assigned_at := old.assigned_at;
  end if;

  select coalesce(sum(share_pct), 0) into v_total
    from public.supplier_invoice_allocations
   where line_id = new.line_id and id <> new.id;
  if v_total + new.share_pct > 100.0001 then
    raise exception 'la riga è già ripartita per % %%: il totale non può superare il 100 %%', v_total;
  end if;
  return new;
end $$;
create trigger supplier_allocation_guard before insert or update on public.supplier_invoice_allocations
  for each row execute function private.supplier_allocation_guard();

create table public.supplier_invoice_allocation_log (
  id bigint generated always as identity primary key,
  organization_id uuid not null,
  allocation_id uuid,
  line_id uuid,
  action text not null,
  old_bene_id uuid,
  old_not_applicable boolean,
  old_share_pct numeric(7, 4),
  new_bene_id uuid,
  new_not_applicable boolean,
  new_share_pct numeric(7, 4),
  done_by uuid,
  done_at timestamptz not null default now()
);
create index supplier_invoice_allocation_log_line_idx on public.supplier_invoice_allocation_log (line_id);

create or replace function private.supplier_allocation_log()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    insert into public.supplier_invoice_allocation_log
      (organization_id, allocation_id, line_id, action, new_bene_id, new_not_applicable, new_share_pct, done_by)
    values (new.organization_id, new.id, new.line_id, 'assegnata', new.bene_id, new.not_applicable, new.share_pct, auth.uid());
    return new;
  elsif tg_op = 'UPDATE' then
    if (old.bene_id, old.not_applicable, old.share_pct) is distinct from (new.bene_id, new.not_applicable, new.share_pct) then
      insert into public.supplier_invoice_allocation_log
        (organization_id, allocation_id, line_id, action,
         old_bene_id, old_not_applicable, old_share_pct, new_bene_id, new_not_applicable, new_share_pct, done_by)
      values (new.organization_id, new.id, new.line_id, 'modificata',
              old.bene_id, old.not_applicable, old.share_pct, new.bene_id, new.not_applicable, new.share_pct, auth.uid());
    end if;
    return new;
  else
    insert into public.supplier_invoice_allocation_log
      (organization_id, allocation_id, line_id, action, old_bene_id, old_not_applicable, old_share_pct, done_by)
    values (old.organization_id, old.id, old.line_id, 'rimossa', old.bene_id, old.not_applicable, old.share_pct, auth.uid());
    return old;
  end if;
end $$;
create trigger supplier_allocation_log after insert or update or delete on public.supplier_invoice_allocations
  for each row execute function private.supplier_allocation_log();

-- 7. PRATICHE: con fatture non cambiano cliente né beneficiaria (scatta dopo pratiche_before_write)
create or replace function private.pratiche_lock_company()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if ((old.company_id is not null and new.company_id is distinct from old.company_id)
      or new.beneficiary_company_id is distinct from old.beneficiary_company_id)
     and exists (select 1 from public.supplier_invoices i where i.pratica_id = old.id) then
    raise exception 'la pratica % ha fatture di fornitori: non può cambiare cliente né beneficiaria', coalesce(old.code, old.id::text);
  end if;
  return new;
end $$;
create trigger pratiche_lock_company before update on public.pratiche
  for each row execute function private.pratiche_lock_company();

-- 8. VISTE (security_invoker)
create view public.supplier_invoice_lines_status with (security_invoker = true) as
select l.id as line_id, l.invoice_id, i.company_id, i.pratica_id,
       l.amount * i.sign as amount,
       coalesce(sum(a.share_pct) filter (where not a.not_applicable), 0) as on_beni_pct,
       coalesce(sum(a.share_pct) filter (where a.not_applicable), 0) as not_applicable_pct,
       100 - coalesce(sum(a.share_pct), 0) as to_catalog_pct
  from public.supplier_invoice_lines l
  join public.supplier_invoices i on i.id = l.invoice_id
  left join public.supplier_invoice_allocations a on a.line_id = l.id
 where i.removed_at is null
 group by l.id, l.invoice_id, i.company_id, i.pratica_id, l.amount, i.sign;

create view public.supplier_invoice_by_bene with (security_invoker = true) as
select i.pratica_id, p.code as pratica_code, p.title as pratica_title,
       a.bene_id, b.name as bene_name,
       i.company_id, i.supplier_id, i.supplier_name,
       i.id as invoice_id, i.number, i.issue_date, i.doc_type,
       l.id as line_id, l.position, l.description, l.period_from, l.period_to,
       l.vat_rate, a.share_pct,
       round(l.amount * a.share_pct / 100, 2) * i.sign as amount
  from public.supplier_invoice_allocations a
  join public.supplier_invoice_lines l on l.id = a.line_id
  join public.supplier_invoices i on i.id = l.invoice_id
  join public.pratiche p on p.id = i.pratica_id
  join public.beni b on b.id = a.bene_id
 where i.removed_at is null and not a.not_applicable;

create view public.supplier_invoice_pratica_summary with (security_invoker = true) as
select s.pratica_id, p.code as pratica_code, p.title as pratica_title, s.company_id,
       count(distinct s.invoice_id) as invoices,
       round(sum(s.amount * s.on_beni_pct / 100), 2) as on_beni_amount,
       round(sum(s.amount * s.not_applicable_pct / 100), 2) as not_applicable_amount,
       round(sum(s.amount * s.to_catalog_pct / 100), 2) as to_catalog_amount
  from public.supplier_invoice_lines_status s
  join public.pratiche p on p.id = s.pratica_id
 group by s.pratica_id, p.code, p.title, s.company_id;

-- 9. FUNZIONI PER LA SCHERMATA (solo staff)
create or replace function public.supplier_invoice_proposal(p_company uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  if not private.is_staff() then
    raise exception 'not allowed';
  end if;
  with pr as (
    select p.id, p.code, p.title,
           (select count(*) from public.beni b where b.pratica_id = p.id and b.removed_at is null) as beni_count,
           (select min(b.id::text)::uuid from public.beni b where b.pratica_id = p.id and b.removed_at is null) as only_bene
      from public.pratiche p
     where coalesce(p.beneficiary_company_id, p.company_id) = p_company and p.is_open and p.removed_at is null
  )
  select jsonb_build_object(
    'pratica_id', case when (select count(*) from pr) = 1 then (select id from pr) end,
    'bene_id', case when (select count(*) from pr) = 1
                    then (select case when beni_count = 1 then only_bene end from pr) end,
    'pratiche', coalesce((select jsonb_agg(jsonb_build_object(
                  'id', id, 'code', code, 'title', title, 'beni_count', beni_count) order by code) from pr), '[]'::jsonb)
  ) into v;
  return v;
end $$;

create or replace function public.pratica_beni(p_pratica uuid)
returns table (id uuid, name text) language sql stable security definer set search_path = '' as $$
  select b.id, b.name from public.beni b
   where private.is_staff() and b.pratica_id = p_pratica and b.removed_at is null
   order by b.name;
$$;

create or replace function public.assign_supplier_invoices(p_invoice_ids uuid[], p_pratica uuid, p_bene uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_inv int; v_lines int := 0;
begin
  if not private.is_staff() then
    raise exception 'not allowed';
  end if;
  update public.supplier_invoices set pratica_id = p_pratica
   where id = any (p_invoice_ids) and pratica_id is distinct from p_pratica;
  get diagnostics v_inv = row_count;
  if p_bene is not null then
    insert into public.supplier_invoice_allocations (line_id, bene_id, share_pct)
    select l.id, p_bene, 100
      from public.supplier_invoice_lines l
     where l.invoice_id = any (p_invoice_ids)
       and not exists (select 1 from public.supplier_invoice_allocations a where a.line_id = l.id);
    get diagnostics v_lines = row_count;
  end if;
  return jsonb_build_object('invoices_assigned', v_inv, 'lines_assigned', v_lines);
end $$;

create or replace function public.set_pratica_beneficiary(p_pratica uuid, p_company uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_prat record; v_new uuid;
begin
  if not private.is_staff() or private.current_staff_role() is distinct from 'admin' then
    raise exception 'Solo un amministratore può impostare l''azienda beneficiaria.' using errcode = '42501';
  end if;
  select id, company_id, beneficiary_company_id into v_prat from public.pratiche where id = p_pratica and removed_at is null for update;
  if v_prat.id is null then
    raise exception 'Pratica non trovata.' using errcode = '22023';
  end if;
  if p_company is not null and not exists (select 1 from public.companies where id = p_company) then
    raise exception 'Azienda non trovata.' using errcode = '22023';
  end if;
  v_new := case when p_company is distinct from v_prat.company_id then p_company end;
  update public.pratiche set beneficiary_company_id = v_new where id = p_pratica;
  return jsonb_build_object('pratica_id', p_pratica, 'cliente', v_prat.company_id,
                            'beneficiaria', coalesce(v_new, v_prat.company_id), 'diversa_dal_cliente', v_new is not null);
end $$;
revoke all on function public.set_pratica_beneficiary(uuid, uuid) from public, anon;
grant execute on function public.set_pratica_beneficiary(uuid, uuid) to authenticated;

revoke all on function public.supplier_invoice_proposal(uuid) from public, anon;
revoke all on function public.pratica_beni(uuid) from public, anon;
revoke all on function public.assign_supplier_invoices(uuid[], uuid, uuid) from public, anon;
grant execute on function public.supplier_invoice_proposal(uuid) to authenticated;
grant execute on function public.pratica_beni(uuid) to authenticated;
grant execute on function public.assign_supplier_invoices(uuid[], uuid, uuid) to authenticated;

-- 10. IMPORTAZIONE (solo importatore, mai dal browser)
create or replace function private.import_supplier_invoices(p_batch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_run uuid;
  inv jsonb;
  s jsonb;
  v_sup uuid;
  v_inv uuid;
  v_company uuid;
  n_seen int := 0; n_ins int := 0; n_dup int := 0; n_unm int := 0; n_err int := 0;
  results jsonb := '[]'::jsonb;
begin
  insert into public.supplier_invoice_import_runs (source) values (p_batch->>'source') returning id into v_run;

  for inv in select * from jsonb_array_elements(coalesce(p_batch->'invoices', '[]'::jsonb)) loop
    n_seen := n_seen + 1;
    begin
      s := inv->'supplier';
      v_sup := null;
      if nullif(s->>'tax_id', '') is not null then
        select id into v_sup from public.client_suppliers
         where tax_id = s->>'tax_id' and coalesce(country, '') = coalesce(s->>'country', '');
      elsif nullif(s->>'fiscal_code', '') is not null then
        select id into v_sup from public.client_suppliers
         where tax_id is null and fiscal_code = s->>'fiscal_code';
      else
        select id into v_sup from public.client_suppliers
         where tax_id is null and fiscal_code is null and lower(name) = lower(s->>'name');
      end if;
      if v_sup is null then
        insert into public.client_suppliers (country, tax_id, fiscal_code, name)
        values (nullif(s->>'country', ''), nullif(s->>'tax_id', ''), nullif(s->>'fiscal_code', ''), s->>'name')
        returning id into v_sup;
      end if;

      insert into public.supplier_invoices
        (recipient_vat, recipient_name, supplier_id, supplier_name, doc_type, number, issue_date, currency,
         total_amount, net_amount, vat_amount, rounding_amount, source_file_name, source_sha256, was_signed,
         xml_path, pdf_path, check_warnings, data, import_run_id)
      values
        (inv->>'recipient_vat', inv->>'recipient_name', v_sup, s->>'name', inv->>'doc_type', inv->>'number',
         (inv->>'issue_date')::date, coalesce(nullif(inv->>'currency', ''), 'EUR'),
         (inv->>'total_amount')::numeric, (inv->>'net_amount')::numeric, (inv->>'vat_amount')::numeric,
         (inv->>'rounding_amount')::numeric, inv->>'file_name', inv->>'sha256',
         coalesce((inv->>'was_signed')::boolean, false), inv->>'xml_path', inv->>'pdf_path',
         coalesce(array(select jsonb_array_elements_text(inv->'warnings')), '{}'),
         coalesce(inv->'data', '{}'::jsonb), v_run)
      on conflict do nothing
      returning id, company_id into v_inv, v_company;

      if v_inv is null then
        n_dup := n_dup + 1;
        results := results || jsonb_build_object('file', inv->>'file_name', 'result', 'duplicato');
        continue;
      end if;

      insert into public.supplier_invoice_lines
        (invoice_id, position, line_no, description, quantity, unit, period_from, period_to,
         unit_price, amount, vat_rate, vat_nature, data)
      select v_inv, r.position, r.line_no, r.description, r.quantity, r.unit, r.period_from, r.period_to,
             r.unit_price, r.amount, r.vat_rate, r.vat_nature, coalesce(r.data, '{}'::jsonb)
        from jsonb_to_recordset(coalesce(inv->'lines', '[]'::jsonb)) as r(
               position int, line_no int, description text, quantity numeric, unit text,
               period_from date, period_to date, unit_price numeric, amount numeric,
               vat_rate numeric, vat_nature text, data jsonb);

      if v_company is null then
        n_unm := n_unm + 1;
      end if;
      if nullif(inv->>'pratica_id', '') is not null then
        update public.supplier_invoices set pratica_id = (inv->>'pratica_id')::uuid where id = v_inv;
        if nullif(inv->>'bene_id', '') is not null then
          insert into public.supplier_invoice_allocations (line_id, bene_id, share_pct)
          select l.id, (inv->>'bene_id')::uuid, 100 from public.supplier_invoice_lines l where l.invoice_id = v_inv;
        end if;
      end if;

      n_ins := n_ins + 1;
      results := results || jsonb_build_object('file', inv->>'file_name', 'result', 'inserita', 'invoice_id', v_inv,
                                               'cliente_trovato', v_company is not null);
    exception when others then
      n_err := n_err + 1;
      results := results || jsonb_build_object('file', inv->>'file_name', 'result', 'errore', 'error', sqlerrm);
    end;
  end loop;

  update public.supplier_invoice_import_runs
     set finished_at = now(), files_seen = n_seen, inserted_count = n_ins, duplicate_count = n_dup,
         unmatched_company_count = n_unm, error_count = n_err, report = jsonb_build_object('results', results)
   where id = v_run;
  return jsonb_build_object('run_id', v_run, 'seen', n_seen, 'inserted', n_ins, 'duplicates', n_dup,
                            'unmatched_company', n_unm, 'errors', n_err, 'results', results);
end $$;
revoke all on function private.import_supplier_invoices(jsonb) from public, anon, authenticated;

-- 11. REGOLE DI ACCESSO (RLS): solo staff
alter table public.beni enable row level security;
alter table public.client_suppliers enable row level security;
alter table public.supplier_invoice_import_runs enable row level security;
alter table public.supplier_invoices enable row level security;
alter table public.supplier_invoice_lines enable row level security;
alter table public.supplier_invoice_allocations enable row level security;
alter table public.supplier_invoice_allocation_log enable row level security;

create policy "beni: staff manage" on public.beni for all to authenticated
  using ((select private.is_staff())) with check ((select private.is_staff()));
create policy "supplier_invoice_allocations: staff manage" on public.supplier_invoice_allocations for all to authenticated
  using ((select private.is_staff())) with check ((select private.is_staff()));
create policy "supplier_invoices: staff read" on public.supplier_invoices for select to authenticated
  using ((select private.is_staff()));
create policy "supplier_invoices: staff delete" on public.supplier_invoices for delete to authenticated
  using ((select private.is_staff()));
create policy "supplier_invoice_lines: staff read" on public.supplier_invoice_lines for select to authenticated
  using ((select private.is_staff()));
create policy "client_suppliers: staff read" on public.client_suppliers for select to authenticated
  using ((select private.is_staff()));
create policy "supplier_invoice_import_runs: staff read" on public.supplier_invoice_import_runs for select to authenticated
  using ((select private.is_staff()));
create policy "supplier_invoice_allocation_log: staff read" on public.supplier_invoice_allocation_log for select to authenticated
  using ((select private.is_staff()));

revoke all on public.beni, public.client_suppliers, public.supplier_invoice_import_runs,
  public.supplier_invoices, public.supplier_invoice_lines, public.supplier_invoice_allocations,
  public.supplier_invoice_allocation_log, public.supplier_invoice_lines_status,
  public.supplier_invoice_by_bene, public.supplier_invoice_pratica_summary from anon;

-- 12. ARCHIVIO FILE (bucket privato, solo staff). Percorso: <organization_id>/<sha256>.xml (e .pdf)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('supplier-invoices', 'supplier-invoices', false, 52428800,
        array['application/xml', 'text/xml', 'application/pkcs7-mime', 'application/x-pkcs7-mime', 'application/pdf'])
on conflict (id) do nothing;

create policy "supplier-invoices bucket: staff read" on storage.objects for select to authenticated
  using (bucket_id = 'supplier-invoices' and (select private.is_staff()));
create policy "supplier-invoices bucket: staff upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'supplier-invoices' and (select private.is_staff()));
create policy "supplier-invoices bucket: staff delete" on storage.objects for delete to authenticated
  using (bucket_id = 'supplier-invoices' and (select private.is_staff()));
