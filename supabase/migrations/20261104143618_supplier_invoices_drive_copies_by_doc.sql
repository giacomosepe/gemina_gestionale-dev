-- Recovered on 2026-11-09 from production's migration history (supabase_migrations.schema_migrations, version 20261104143618):
-- applied without a file in the repo (CLAUDE.md rule 2). Text exactly as recorded.

-- A Drive file that is the same invoice as one already imported is remembered (and skipped next time) also when its bytes differ
-- (e.g. the .xml and the .xml.p7m of one invoice): matched by sha256, or by supplier + document type + number + date.
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

  -- Copies of an invoice already imported (same bytes, or same supplier/type/number/date in another file): remembered, so they are skipped next time.
  insert into public.supplier_invoice_drive_copies (drive_file_id, invoice_id, file_name)
  select x.drive, m.id, x.fname
    from (select nullif(e->>'drive_file_id', '') as drive, e->>'sha256' as sha, e->>'file_name' as fname,
                 e->>'doc_type' as doc_type, btrim(e->>'number') as number, nullif(e->>'issue_date', '')::date as issue_date,
                 upper(btrim(e->'supplier'->>'country')) as country, upper(btrim(nullif(e->'supplier'->>'tax_id', ''))) as tax_id,
                 upper(btrim(nullif(e->'supplier'->>'fiscal_code', ''))) as cf
            from jsonb_array_elements(arr) e) x
    cross join lateral (
      select i.id, i.drive_file_id from (
        select i.id, i.drive_file_id, 1 as ord from public.supplier_invoices i where i.source_sha256 = x.sha
        union all
        select i.id, i.drive_file_id, 2 from public.supplier_invoices i join public.client_suppliers s on s.id = i.supplier_id
         where i.removed_at is null and i.doc_type = x.doc_type and btrim(i.number) = x.number and i.issue_date = x.issue_date
           and upper(btrim(s.country)) is not distinct from x.country
           and ((x.tax_id is not null and upper(btrim(s.tax_id)) = x.tax_id) or (x.tax_id is null and x.cf is not null and upper(btrim(s.fiscal_code)) = x.cf))
      ) i order by ord limit 1
    ) m
   where x.drive is not null and m.drive_file_id is distinct from x.drive
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
