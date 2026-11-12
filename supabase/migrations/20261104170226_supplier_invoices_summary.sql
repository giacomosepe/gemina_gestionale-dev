-- Recovered on 2026-11-09 from production's migration history (supabase_migrations.schema_migrations, version 20261104170226):
-- applied without a file in the repo (CLAUDE.md rule 2). Text exactly as recorded.

-- Riepiloghi della pratica per bene, per fornitore e per categoria, sulle fatture che passano i filtri (stessi filtri dell'elenco).
-- Gli importi sono imponibili di riga con il segno (le note di credito tolgono); su un bene, la quota di ogni riga.
create or replace function public.supplier_invoices_summary(p_pratica uuid, p_filters jsonb default '{}')
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  v_f jsonb := coalesce(p_filters, '{}'::jsonb);
  v_ids uuid[];
begin
  if not (select private.is_staff()) then raise exception 'Non autorizzato' using errcode = '42501'; end if;
  select coalesce(array_agg(id), '{}') into v_ids from private.si_filtered(p_pratica, v_f, null);

  return jsonb_build_object(
    'beni', (
      select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'invoices', coalesce(x.n, 0), 'amount', coalesce(x.amt, 0),
                                                   'by_year', coalesce(x.yrs, '[]'::jsonb)) order by b.name), '[]'::jsonb)
        from public.beni b
        left join lateral (
          select count(distinct ls.invoice_id) as n, round(sum(ls.amount * a.share_pct / 100), 2) as amt,
                 (select jsonb_agg(jsonb_build_object('year', y.yr, 'amount', y.amt) order by y.yr desc)
                    from (select extract(year from i.issue_date)::int::text as yr, round(sum(l2.amount * a2.share_pct / 100), 2) as amt
                            from public.supplier_invoice_allocations a2
                            join public.supplier_invoice_lines_status l2 on l2.line_id = a2.line_id
                            join public.supplier_invoices i on i.id = l2.invoice_id
                           where a2.bene_id = b.id and not a2.not_applicable and l2.invoice_id = any(v_ids) group by 1) y) as yrs
            from public.supplier_invoice_allocations a
            join public.supplier_invoice_lines_status ls on ls.line_id = a.line_id
           where a.bene_id = b.id and not a.not_applicable and ls.invoice_id = any(v_ids)
        ) x on true
       where b.pratica_id = p_pratica and b.removed_at is null),
    'altro', (select jsonb_build_object(
                'non_applicabile', coalesce(round(sum(s.amount * s.not_applicable_pct / 100), 2), 0),
                'da_assegnare', coalesce(round(sum(s.amount * s.to_catalog_pct / 100), 2), 0))
                from public.supplier_invoice_lines_status s where s.invoice_id = any(v_ids)),
    'fornitori', (
      select coalesce(jsonb_agg(jsonb_build_object('id', g.sid, 'name', g.nm, 'category_id', g.cid, 'invoices', g.n, 'net', g.net, 'total', g.tot)
                                order by g.nm), '[]'::jsonb)
        from (select i.supplier_id as sid, min(i.supplier_name) as nm, min(s.category_id::text) as cid, count(*) as n,
                     round(sum(i.net_amount * i.sign), 2) as net, round(sum(i.total_amount * i.sign), 2) as tot
                from public.supplier_invoices i left join public.client_suppliers s on s.id = i.supplier_id
               where i.id = any(v_ids) group by i.supplier_id) g),
    'categorie', (
      select coalesce(jsonb_agg(jsonb_build_object('id', g.cid, 'name', g.nm, 'suppliers', g.ns, 'invoices', g.n, 'net', g.net) order by g.o, g.nm), '[]'::jsonb)
        from (select coalesce(c.id::text, 'none') as cid, coalesce(min(c.name), 'Da classificare') as nm, coalesce(min(c.position), 999) as o,
                     count(distinct i.supplier_id) as ns, count(*) as n, round(sum(i.net_amount * i.sign), 2) as net
                from public.supplier_invoices i
                left join public.client_suppliers s on s.id = i.supplier_id
                left join public.supplier_categories c on c.id = s.category_id
               where i.id = any(v_ids) group by coalesce(c.id::text, 'none')) g)
  );
end $$;

grant execute on function public.supplier_invoices_summary(uuid, jsonb) to authenticated;
