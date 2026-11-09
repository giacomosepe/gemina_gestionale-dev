-- Recovered on 2026-11-09 from production's migration history (supabase_migrations.schema_migrations, version 20261104142002):
-- applied without a file in the repo (CLAUDE.md rule 2). Text exactly as recorded.

-- Drive files that are byte-identical copies of an invoice already imported: remembered so the next "Importa da Drive" skips them.
create table public.supplier_invoice_drive_copies (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id(),
  drive_file_id text not null,
  invoice_id uuid not null references public.supplier_invoices(id) on delete cascade,
  file_name text,
  created_at timestamptz not null default now(),
  unique (organization_id, drive_file_id)
);
create index on public.supplier_invoice_drive_copies (invoice_id);
alter table public.supplier_invoice_drive_copies enable row level security;
create policy "supplier_invoice_drive_copies: staff read" on public.supplier_invoice_drive_copies
  for select to authenticated using ((select private.is_staff()));
revoke all on public.supplier_invoice_drive_copies from anon;

create or replace function private.supplier_invoices_from_drive(p_ids text[])
 returns text[] language sql stable security definer set search_path to ''
as $$
  select coalesce(array_agg(d), '{}') from (
    select drive_file_id d from public.supplier_invoices where drive_file_id = any (p_ids)
    union
    select drive_file_id from public.supplier_invoice_drive_copies where drive_file_id = any (p_ids)
  ) s;
$$;

create or replace function private.import_pratica_invoices(p_pratica uuid, p_beni jsonb, p_batch jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
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

  -- Identical copies (same bytes, another Drive file): remembered, so they are not read again at the next click.
  insert into public.supplier_invoice_drive_copies (drive_file_id, invoice_id, file_name)
  select x.drive, i.id, x.fname
    from (select nullif(e->>'drive_file_id', '') as drive, e->>'sha256' as sha, e->>'file_name' as fname from jsonb_array_elements(arr) e) x
    join public.supplier_invoices i on i.source_sha256 = x.sha
   where x.drive is not null and i.drive_file_id is distinct from x.drive
  on conflict (organization_id, drive_file_id) do nothing;

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
end $function$;
