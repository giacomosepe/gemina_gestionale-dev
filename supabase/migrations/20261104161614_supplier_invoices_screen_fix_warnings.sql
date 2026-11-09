-- Recovered on 2026-11-09 from production's migration history (supabase_migrations.schema_migrations, version 20261104161614):
-- applied without a file in the repo (CLAUDE.md rule 2). Text exactly as recorded.

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
           'warnings', coalesce(cardinality(inv.check_warnings), 0),
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
