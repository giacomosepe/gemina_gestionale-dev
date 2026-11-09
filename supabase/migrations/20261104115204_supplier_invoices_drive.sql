-- Recovered on 2026-11-09 from production's migration history (supabase_migrations.schema_migrations, version 20261104115204):
-- applied without a file in the repo (CLAUDE.md rule 2). Text exactly as recorded.

-- Fatture fornitori: import dalla cartella Google Drive della pratica (4/11/2026)
alter table public.supplier_invoices add column drive_file_id text;
create unique index supplier_invoices_drive_key on public.supplier_invoices (organization_id, drive_file_id)
  where drive_file_id is not null;
comment on column public.supplier_invoices.drive_file_id is 'ID del file XML su Google Drive (import dalla cartella della pratica)';
comment on column public.supplier_invoices.pdf_path is 'Dove sta il PDF leggibile: drive:<id file> per i PDF scritti su Google Drive';

alter table public.beni drop constraint beni_zite_bene_id_key;
create unique index beni_pratica_zite_key on public.beni (pratica_id, zite_bene_id) where zite_bene_id is not null;
alter table public.beni add column supplier_hint text;
comment on column public.beni.supplier_hint is 'Fornitore indicato sul bene in Zite: aiuta a proporre il bene per le fatture di quel fornitore';

create or replace function private.sync_pratica_beni(p_pratica uuid, p_beni jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b jsonb; v_zid text; v_nome text; v_forn text; v_id uuid; i int := 0;
  ids text[] := '{}'; v_attivi int;
begin
  if p_beni is null or jsonb_typeof(p_beni) <> 'array' then
    raise exception 'p_beni must be a json array' using errcode = '22023';
  end if;
  for b in select value from jsonb_array_elements(p_beni) loop
    i := i + 1;
    v_zid := nullif(btrim(b->>'id'), '');
    if v_zid is null then continue; end if;
    v_nome := coalesce(nullif(btrim(b->>'nome'), ''), 'Bene ' || i);
    v_forn := nullif(btrim(b->>'fornitore'), '');
    ids := ids || v_zid;
    select id into v_id from public.beni where pratica_id = p_pratica and zite_bene_id = v_zid;
    if v_id is null then
      insert into public.beni (pratica_id, name, zite_bene_id, supplier_hint) values (p_pratica, v_nome, v_zid, v_forn);
    else
      update public.beni set name = v_nome, supplier_hint = v_forn, removed_at = null
       where id = v_id and (name, supplier_hint, removed_at) is distinct from (v_nome, v_forn, null::timestamptz);
    end if;
  end loop;

  update public.beni set removed_at = now()
   where pratica_id = p_pratica and zite_bene_id is not null and removed_at is null and not (zite_bene_id = any (ids));

  select count(*) into v_attivi from public.beni where pratica_id = p_pratica and zite_bene_id is not null and removed_at is null;
  if v_attivi = 0 then
    if not exists (select 1 from public.beni where pratica_id = p_pratica and removed_at is null) then
      insert into public.beni (pratica_id) values (p_pratica);
    end if;
  else
    update public.beni be set removed_at = now()
     where be.pratica_id = p_pratica and be.zite_bene_id is null and be.removed_at is null
       and not exists (select 1 from public.supplier_invoice_allocations a where a.bene_id = be.id);
  end if;
  return jsonb_build_object('beni_attivi', (select count(*) from public.beni where pratica_id = p_pratica and removed_at is null));
end $$;
revoke all on function private.sync_pratica_beni(uuid, jsonb) from public, anon, authenticated;

create or replace function private.supplier_invoices_from_drive(p_ids text[])
returns text[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(drive_file_id), '{}') from public.supplier_invoices where drive_file_id = any (p_ids);
$$;
revoke all on function private.supplier_invoices_from_drive(text[]) from public, anon, authenticated;

create or replace function private.import_pratica_invoices(p_pratica uuid, p_beni jsonb, p_batch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  inv jsonb; arr jsonb := '[]'::jsonb; v_bene uuid; v_n int; v_def uuid; v_res jsonb; v_old record;
  adottate jsonb := '[]'::jsonb;
begin
  if not exists (select 1 from public.pratiche where id = p_pratica and removed_at is null) then
    raise exception 'Pratica non trovata su Supabase: va prima sincronizzata da Zite.' using errcode = '22023';
  end if;
  perform private.sync_pratica_beni(p_pratica, coalesce(p_beni, '[]'::jsonb));

  for inv in select value from jsonb_array_elements(coalesce(p_batch->'invoices', '[]'::jsonb)) loop
    v_bene := null;
    if nullif(btrim(inv->>'bene_name'), '') is not null then
      select count(*), min(id::text)::uuid into v_n, v_def from public.beni
       where pratica_id = p_pratica and removed_at is null and lower(btrim(name)) = lower(btrim(inv->>'bene_name'));
      if v_n = 1 then v_bene := v_def; end if;
    end if;
    if v_bene is null then
      select count(*), min(id::text)::uuid into v_n, v_def from public.beni where pratica_id = p_pratica and removed_at is null;
      if v_n = 1 then
        v_bene := v_def;
      elsif v_n > 1 then
        select count(*), min(id::text)::uuid into v_n, v_def from public.beni
         where pratica_id = p_pratica and removed_at is null and supplier_hint is not null
           and private.name_overlap(supplier_hint, inv->'supplier'->>'name');
        if v_n = 1 then v_bene := v_def; end if;
      end if;
    end if;
    arr := arr || (inv || jsonb_build_object('pratica_id', p_pratica, 'bene_id', v_bene));
  end loop;

  v_res := private.import_supplier_invoices(jsonb_build_object('source', p_batch->>'source', 'invoices', arr));

  update public.supplier_invoices i
     set drive_file_id = coalesce(i.drive_file_id, x.drive), xml_path = coalesce(i.xml_path, x.xml_path), pdf_path = coalesce(x.pdf_path, i.pdf_path)
    from (select e->>'sha256' as sha, nullif(e->>'drive_file_id', '') as drive, nullif(e->>'xml_path', '') as xml_path,
                 nullif(e->>'pdf_path', '') as pdf_path from jsonb_array_elements(arr) e) x
   where i.source_sha256 = x.sha
     and not exists (select 1 from public.supplier_invoices o where o.drive_file_id = x.drive and o.id <> i.id);

  for inv in select value from jsonb_array_elements(arr) loop
    select id, pratica_id into v_old from public.supplier_invoices where source_sha256 = inv->>'sha256';
    continue when v_old.id is null or v_old.pratica_id is not null;
    begin
      update public.supplier_invoices set pratica_id = p_pratica where id = v_old.id;
      if nullif(inv->>'bene_id', '') is not null then
        insert into public.supplier_invoice_allocations (line_id, bene_id, share_pct)
        select l.id, (inv->>'bene_id')::uuid, 100 from public.supplier_invoice_lines l
         where l.invoice_id = v_old.id and not exists (select 1 from public.supplier_invoice_allocations a where a.line_id = l.id);
      end if;
      adottate := adottate || jsonb_build_object('file', inv->>'file_name', 'result', 'già presente: messa su questa pratica');
    exception when others then
      adottate := adottate || jsonb_build_object('file', inv->>'file_name', 'result', 'già presente', 'error', sqlerrm);
    end;
  end loop;

  return v_res || jsonb_build_object('adopted', adottate);
end $$;
revoke all on function private.import_pratica_invoices(uuid, jsonb, jsonb) from public, anon, authenticated;
