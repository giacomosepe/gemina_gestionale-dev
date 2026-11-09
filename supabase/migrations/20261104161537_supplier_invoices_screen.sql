-- Recovered on 2026-11-09 from production's migration history (supabase_migrations.schema_migrations, version 20261104161537):
-- applied without a file in the repo (CLAUDE.md rule 2). Text exactly as recorded.

-- The Gestionale's «Fatture fornitori» screen (2026-11-04). Every function runs AS the colleague (security invoker, called by the
-- fatture-import Edge Function with the colleague's identity): RLS decides, auth.uid() is who assigned.

-- Lines of some invoices with their current allocations (amounts already signed: credit notes negative).
create or replace function public.supplier_invoice_lines_json(p_invoice_ids uuid[])
 returns jsonb language sql stable security invoker set search_path to ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', l.id, 'invoice_id', l.invoice_id, 'position', l.position, 'description', l.description,
           'quantity', l.quantity, 'unit', l.unit, 'unit_price', l.unit_price, 'amount', l.amount * i.sign,
           'vat_rate', l.vat_rate, 'vat_nature', l.vat_nature, 'period_from', l.period_from, 'period_to', l.period_to,
           'allocations', coalesce((select jsonb_agg(jsonb_build_object('bene_id', a.bene_id, 'not_applicable', a.not_applicable, 'pct', a.share_pct)
                                                     order by a.not_applicable, a.share_pct desc)
                                      from public.supplier_invoice_allocations a where a.line_id = l.id), '[]'::jsonb))
           order by l.invoice_id, l.position), '[]'::jsonb)
    from public.supplier_invoice_lines l
    join public.supplier_invoices i on i.id = l.invoice_id
   where l.invoice_id = any (p_invoice_ids) and i.removed_at is null;
$$;

-- One page of a pratica's invoices (newest first) with: totals of the pratica, its beni, the supplier categories, and for each invoice
-- its assignment state; lines are included for invoices with at most p_max_lines lines (the others are read on expand).
create or replace function public.supplier_invoices_page(p_pratica uuid, p_offset int default 0, p_limit int default 50, p_max_lines int default 30)
 returns jsonb language plpgsql stable security invoker set search_path to ''
as $$
declare
  v_lim int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_off int := greatest(coalesce(p_offset, 0), 0);
  v_page jsonb; v_ids uuid[]; v_small uuid[];
begin
  if not (select private.is_staff()) then raise exception 'Non autorizzato' using errcode = '42501'; end if;

  with inv as (
    select i.*, s.category_id,
           (select count(*) from public.supplier_invoice_lines l where l.invoice_id = i.id) as n_lines
      from public.supplier_invoices i
      left join public.client_suppliers s on s.id = i.supplier_id
     where i.pratica_id = p_pratica and i.removed_at is null
     order by i.issue_date desc, i.supplier_name, i.number, i.id
     offset v_off limit v_lim
  ), st as (
    select s.invoice_id, sum(abs(s.amount)) as tot,
           sum(abs(s.amount) * s.to_catalog_pct / 100) as da_assegnare
      from public.supplier_invoice_lines_status s where s.invoice_id in (select id from inv) group by s.invoice_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', inv.id, 'supplier_id', inv.supplier_id, 'supplier_name', inv.supplier_name, 'category_id', inv.category_id,
           'doc_type', inv.doc_type, 'sign', inv.sign, 'number', inv.number, 'issue_date', inv.issue_date,
           'total', inv.total_amount * inv.sign, 'net', inv.net_amount * inv.sign, 'vat', inv.vat_amount * inv.sign,
           'pdf_drive_id', case when inv.pdf_path like 'drive:%' then substr(inv.pdf_path, 7) end,
           'warnings', coalesce(jsonb_array_length(case when jsonb_typeof(inv.check_warnings) = 'array' then inv.check_warnings end), 0),
           'n_lines', inv.n_lines,
           'state', case when coalesce(st.tot, 0) = 0 then case when exists (select 1 from public.supplier_invoice_lines l join public.supplier_invoice_allocations a on a.line_id = l.id where l.invoice_id = inv.id) then 'assegnata' else 'da_assegnare' end
                         when st.da_assegnare >= st.tot - 0.005 then 'da_assegnare'
                         when st.da_assegnare > 0.005 then 'parziale' else 'assegnata' end,
           'beni', coalesce((select jsonb_agg(distinct a.bene_id) from public.supplier_invoice_lines l
                               join public.supplier_invoice_allocations a on a.line_id = l.id
                              where l.invoice_id = inv.id and not a.not_applicable), '[]'::jsonb),
           'not_applicable', exists (select 1 from public.supplier_invoice_lines l join public.supplier_invoice_allocations a on a.line_id = l.id
                                      where l.invoice_id = inv.id and a.not_applicable)
         ) order by inv.issue_date desc, inv.supplier_name, inv.number, inv.id), '[]'::jsonb),
         coalesce(array_agg(inv.id), '{}'), coalesce(array_agg(inv.id) filter (where inv.n_lines <= greatest(coalesce(p_max_lines, 30), 0)), '{}')
    into v_page, v_ids, v_small
    from inv left join st on st.invoice_id = inv.id;

  return jsonb_build_object(
    'page', v_page,
    'lines', public.supplier_invoice_lines_json(v_small),
    'count', (select count(*) from public.supplier_invoices where pratica_id = p_pratica and removed_at is null),
    'totals', (select jsonb_build_object('total', coalesce(sum(i.total_amount * i.sign), 0), 'net', coalesce(sum(i.net_amount * i.sign), 0))
                 from public.supplier_invoices i where i.pratica_id = p_pratica and i.removed_at is null),
    'catalog', (select jsonb_build_object('on_beni', coalesce(sum(on_beni_amount), 0), 'not_applicable', coalesce(sum(not_applicable_amount), 0),
                                          'to_catalog', coalesce(sum(to_catalog_amount), 0))
                  from public.supplier_invoice_pratica_summary where pratica_id = p_pratica),
    'beni', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name) order by b.name), '[]'::jsonb)
               from public.beni b where b.pratica_id = p_pratica and b.removed_at is null),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.position, c.name), '[]'::jsonb)
                     from public.supplier_categories c where c.archived_at is null)
  );
end $$;

-- Sets how lines are split, in one go: the lines of p_invoice_ids plus p_line_ids, all of pratica p_pratica.
-- p_shares: [] = remove the assignment; else [{bene_id, pct} | {not_applicable: true, pct}] summing to 100 (one bene at 100 = the usual case).
-- Replaces what those lines had. The allocation guard checks open pratica and bene of the pratica; who/when is set by the database.
create or replace function public.set_supplier_allocation(p_pratica uuid, p_invoice_ids uuid[], p_line_ids uuid[], p_shares jsonb)
 returns int language plpgsql security invoker set search_path to ''
as $$
declare v_lines uuid[]; v_sum numeric; s jsonb;
begin
  if not (select private.is_staff()) then raise exception 'Non autorizzato' using errcode = '42501'; end if;
  if jsonb_typeof(coalesce(p_shares, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_shares, '[]'::jsonb)) > 50 then
    raise exception 'Ripartizione non valida' using errcode = '22023';
  end if;
  select coalesce(sum((x->>'pct')::numeric), 0) into v_sum from jsonb_array_elements(coalesce(p_shares, '[]'::jsonb)) x;
  if jsonb_array_length(coalesce(p_shares, '[]'::jsonb)) > 0 and abs(v_sum - 100) > 0.0001 then
    raise exception 'Le quote devono fare 100%% (ora %)', v_sum using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p_shares, '[]'::jsonb)) x
              where (x->>'pct')::numeric <= 0 or ((x->>'not_applicable')::boolean is not true and nullif(x->>'bene_id', '') is null)) then
    raise exception 'Ripartizione non valida' using errcode = '22023';
  end if;

  select array_agg(l.id) into v_lines
    from public.supplier_invoice_lines l join public.supplier_invoices i on i.id = l.invoice_id
   where i.pratica_id = p_pratica and i.removed_at is null
     and (l.invoice_id = any (coalesce(p_invoice_ids, '{}')) or l.id = any (coalesce(p_line_ids, '{}')));
  if v_lines is null then return 0; end if;

  delete from public.supplier_invoice_allocations where line_id = any (v_lines);
  for s in select value from jsonb_array_elements(coalesce(p_shares, '[]'::jsonb)) loop
    insert into public.supplier_invoice_allocations (line_id, bene_id, not_applicable, share_pct)
    select x, case when (s->>'not_applicable')::boolean then null else (s->>'bene_id')::uuid end,
           coalesce((s->>'not_applicable')::boolean, false), (s->>'pct')::numeric
      from unnest(v_lines) x;
  end loop;
  return array_length(v_lines, 1);
end $$;

-- Deletes invoices of a pratica (the colleagues delete them: decided 2026-11-04). Lines, allocations and Drive-copy records go with them;
-- the Drive files stay, and can be imported again.
create or replace function public.delete_supplier_invoices(p_pratica uuid, p_invoice_ids uuid[])
 returns int language plpgsql security invoker set search_path to ''
as $$
declare n int;
begin
  if not (select private.is_staff()) then raise exception 'Non autorizzato' using errcode = '42501'; end if;
  delete from public.supplier_invoices where pratica_id = p_pratica and id = any (p_invoice_ids);
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.supplier_invoice_lines_json(uuid[]) from public, anon;
revoke all on function public.supplier_invoices_page(uuid, int, int, int) from public, anon;
revoke all on function public.set_supplier_allocation(uuid, uuid[], uuid[], jsonb) from public, anon;
revoke all on function public.delete_supplier_invoices(uuid, uuid[]) from public, anon;
grant execute on function public.supplier_invoice_lines_json(uuid[]) to authenticated;
grant execute on function public.supplier_invoices_page(uuid, int, int, int) to authenticated;
grant execute on function public.set_supplier_allocation(uuid, uuid[], uuid[], jsonb) to authenticated;
grant execute on function public.delete_supplier_invoices(uuid, uuid[]) to authenticated;
