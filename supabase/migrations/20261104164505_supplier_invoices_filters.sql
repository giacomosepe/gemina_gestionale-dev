-- Recovered on 2026-11-09 from production's migration history (supabase_migrations.schema_migrations, version 20261104164505):
-- applied without a file in the repo (CLAUDE.md rule 2). Text exactly as recorded.

create type private.si_attr as (
  id uuid, supplier_id uuid, supplier_name text, category_id uuid, doc_type text, sign int, issue_date date,
  year text, warnings int, state text, bene_ids text[]
);

create or replace function private.si_attrs(p_pratica uuid) returns setof private.si_attr
language sql stable set search_path = '' as $$
  select i.id, i.supplier_id, i.supplier_name::text, s.category_id, i.doc_type::text, i.sign::int, i.issue_date::date,
         extract(year from i.issue_date)::int::text,
         coalesce(cardinality(i.check_warnings), 0),
         case when coalesce(st.tot, 0) = 0
                then case when exists (select 1 from public.supplier_invoice_lines l join public.supplier_invoice_allocations a on a.line_id = l.id where l.invoice_id = i.id) then 'assegnata' else 'da_assegnare' end
              when st.da_assegnare >= st.tot - 0.005 then 'da_assegnare'
              when st.da_assegnare > 0.005 then 'parziale' else 'assegnata' end,
         coalesce((select array_agg(distinct a.bene_id::text) from public.supplier_invoice_lines l
                     join public.supplier_invoice_allocations a on a.line_id = l.id
                    where l.invoice_id = i.id and not a.not_applicable), '{}')
    from public.supplier_invoices i
    left join public.client_suppliers s on s.id = i.supplier_id
    left join lateral (select sum(abs(x.amount)) as tot, sum(abs(x.amount) * x.to_catalog_pct / 100) as da_assegnare
                         from public.supplier_invoice_lines_status x where x.invoice_id = i.id) st on true
   where i.pratica_id = p_pratica and i.removed_at is null
$$;

-- The filters: {stato:[..], bene:[uuid..], fornitore:[uuid..], categoria:[uuid|'none'..], anno:['2025'..], tipo:['fattura'|'nota_credito'], avvisi:['si']}.
-- p_except leaves one facet out, to count the values of that facet the way the other filters leave them.
create or replace function private.si_filtered(p_pratica uuid, p_filters jsonb, p_except text default null) returns setof private.si_attr
language sql stable set search_path = '' as $$
  select a.* from private.si_attrs(p_pratica) a
   where (p_except = 'stato' or jsonb_array_length(coalesce(p_filters->'stato', '[]')) = 0 or a.state in (select jsonb_array_elements_text(p_filters->'stato')))
     and (p_except = 'bene' or jsonb_array_length(coalesce(p_filters->'bene', '[]')) = 0 or a.bene_ids && array(select jsonb_array_elements_text(p_filters->'bene')))
     and (p_except = 'fornitore' or jsonb_array_length(coalesce(p_filters->'fornitore', '[]')) = 0 or a.supplier_id::text in (select jsonb_array_elements_text(p_filters->'fornitore')))
     and (p_except = 'categoria' or jsonb_array_length(coalesce(p_filters->'categoria', '[]')) = 0 or coalesce(a.category_id::text, 'none') in (select jsonb_array_elements_text(p_filters->'categoria')))
     and (p_except = 'anno' or jsonb_array_length(coalesce(p_filters->'anno', '[]')) = 0 or a.year in (select jsonb_array_elements_text(p_filters->'anno')))
     and (p_except = 'tipo' or jsonb_array_length(coalesce(p_filters->'tipo', '[]')) = 0 or (case when a.sign < 0 then 'nota_credito' else 'fattura' end) in (select jsonb_array_elements_text(p_filters->'tipo')))
     and (p_except = 'avvisi' or jsonb_array_length(coalesce(p_filters->'avvisi', '[]')) = 0 or a.warnings > 0)
$$;

create or replace function private.si_facets(p_pratica uuid, p_filters jsonb) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'stato', (select coalesce(jsonb_agg(jsonb_build_object('value', v.k, 'label', v.l, 'n', (select count(*) from private.si_filtered(p_pratica, p_filters, 'stato') f where f.state = v.k)) order by v.o), '[]')
                from (values ('da_assegnare', 'Da assegnare', 1), ('parziale', 'In parte', 2), ('assegnata', 'Assegnate', 3)) v(k, l, o)),
    'bene', (select coalesce(jsonb_agg(jsonb_build_object('value', b.id, 'label', b.name, 'n', (select count(*) from private.si_filtered(p_pratica, p_filters, 'bene') f where f.bene_ids @> array[b.id::text])) order by b.name), '[]')
               from public.beni b where b.pratica_id = p_pratica and b.removed_at is null),
    'fornitore', (select coalesce(jsonb_agg(jsonb_build_object('value', g.sid, 'label', g.nm, 'n', g.n) order by g.nm), '[]')
                    from (select f.supplier_id::text as sid, min(f.supplier_name) as nm, count(*) as n from private.si_filtered(p_pratica, p_filters, 'fornitore') f group by f.supplier_id) g),
    'categoria', (select coalesce(jsonb_agg(jsonb_build_object('value', g.cid, 'label', g.nm, 'n', g.n) order by g.o, g.nm), '[]')
                    from (select coalesce(f.category_id::text, 'none') as cid, coalesce(min(c.name), 'Da classificare') as nm, coalesce(min(c.position), 999) as o, count(*) as n
                            from private.si_filtered(p_pratica, p_filters, 'categoria') f left join public.supplier_categories c on c.id = f.category_id group by 1) g),
    'anno', (select coalesce(jsonb_agg(jsonb_build_object('value', g.y, 'label', g.y, 'n', g.n) order by g.y desc), '[]')
               from (select f.year as y, count(*) as n from private.si_filtered(p_pratica, p_filters, 'anno') f group by f.year) g),
    'tipo', (select coalesce(jsonb_agg(jsonb_build_object('value', g.t, 'label', case g.t when 'fattura' then 'Fatture' else 'Note di credito' end, 'n', g.n) order by g.t), '[]')
               from (select case when f.sign < 0 then 'nota_credito' else 'fattura' end as t, count(*) as n from private.si_filtered(p_pratica, p_filters, 'tipo') f group by 1) g),
    'avvisi', (select jsonb_build_array(jsonb_build_object('value', 'si', 'label', 'Con avvisi', 'n', (select count(*) from private.si_filtered(p_pratica, p_filters, 'avvisi') f where f.warnings > 0))))
  )
$$;

drop function public.supplier_invoices_page(uuid, integer, integer, integer);

create or replace function public.supplier_invoices_page(p_pratica uuid, p_offset integer default 0, p_limit integer default 50, p_max_lines integer default 30, p_filters jsonb default '{}')
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  v_lim int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_off int := greatest(coalesce(p_offset, 0), 0);
  v_f jsonb := coalesce(p_filters, '{}'::jsonb);
  v_page jsonb; v_small uuid[];
begin
  if not (select private.is_staff()) then raise exception 'Non autorizzato' using errcode = '42501'; end if;

  with fil as (select * from private.si_filtered(p_pratica, v_f, null)),
  inv as (
    select i.*, f.category_id, f.state, f.bene_ids,
           (select count(*) from public.supplier_invoice_lines l where l.invoice_id = i.id) as n_lines
      from fil f join public.supplier_invoices i on i.id = f.id
     order by i.issue_date desc, i.supplier_name, i.number, i.id
     offset v_off limit v_lim
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', inv.id, 'supplier_id', inv.supplier_id, 'supplier_name', inv.supplier_name, 'category_id', inv.category_id,
           'doc_type', inv.doc_type, 'sign', inv.sign, 'number', inv.number, 'issue_date', inv.issue_date,
           'total', inv.total_amount * inv.sign, 'net', inv.net_amount * inv.sign, 'vat', inv.vat_amount * inv.sign,
           'pdf_drive_id', case when inv.pdf_path like 'drive:%' then substr(inv.pdf_path, 7) end,
           'warnings', coalesce(cardinality(inv.check_warnings), 0),
           'n_lines', inv.n_lines, 'state', inv.state,
           'beni', to_jsonb(inv.bene_ids),
           'not_applicable', exists (select 1 from public.supplier_invoice_lines l join public.supplier_invoice_allocations a on a.line_id = l.id
                                      where l.invoice_id = inv.id and a.not_applicable)
         ) order by inv.issue_date desc, inv.supplier_name, inv.number, inv.id), '[]'::jsonb),
         coalesce(array_agg(inv.id) filter (where inv.n_lines <= greatest(coalesce(p_max_lines, 30), 0)), '{}')
    into v_page, v_small
    from inv;

  return jsonb_build_object(
    'page', v_page,
    'lines', public.supplier_invoice_lines_json(v_small),
    'count', (select count(*) from private.si_filtered(p_pratica, v_f, null)),
    'count_all', (select count(*) from public.supplier_invoices where pratica_id = p_pratica and removed_at is null),
    'totals', (select jsonb_build_object('total', coalesce(sum(i.total_amount * i.sign), 0), 'net', coalesce(sum(i.net_amount * i.sign), 0))
                 from public.supplier_invoices i where i.id in (select id from private.si_filtered(p_pratica, v_f, null))),
    'catalog', (select jsonb_build_object(
                  'on_beni', coalesce(round(sum(s.amount * s.on_beni_pct / 100), 2), 0),
                  'not_applicable', coalesce(round(sum(s.amount * s.not_applicable_pct / 100), 2), 0),
                  'to_catalog', coalesce(round(sum(s.amount * s.to_catalog_pct / 100), 2), 0))
                  from public.supplier_invoice_lines_status s where s.invoice_id in (select id from private.si_filtered(p_pratica, v_f, null))),
    'beni', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name) order by b.name), '[]'::jsonb)
               from public.beni b where b.pratica_id = p_pratica and b.removed_at is null),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.position, c.name), '[]'::jsonb)
                     from public.supplier_categories c where c.archived_at is null),
    'facets', private.si_facets(p_pratica, v_f)
  );
end $$;

grant execute on function public.supplier_invoices_page(uuid, integer, integer, integer, jsonb) to authenticated;
grant execute on function private.si_attrs(uuid), private.si_filtered(uuid, jsonb, text), private.si_facets(uuid, jsonb) to authenticated;
