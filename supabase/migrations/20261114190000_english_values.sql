-- English values (Linear PM-191, second part). After the names (20261114160000), the values our own code defines: invoice statuses, commission stage
-- names, signature states, notification event names, supplier invoice states, the keys of the JSON that functions read and return, and the permission keys.
--
-- Rewrites, word for word between quotes ('old' becomes 'new', never inside a longer text):
--   * function bodies and view definitions (a few replacements are limited to the functions listed, because the same word means something else elsewhere),
--   * the stored rows that hold these values, and the check constraint on qonto_documents.status,
--   * the permission keys (role_permissions follows by on update cascade) and the policies that name them.
-- NOT touched: texts the user reads (messages, labels, the area names of the permissions, 'Bene 1' as a default asset name), the stop words of
-- private.name_tokens (they are Italian company-name words on purpose), local variable and alias names inside function bodies, and the data that comes
-- from Zite (cases.status and similar): the import runner maps those values (M1).

-- the functions are rewritten one by one, and some read columns that another function returns: check the bodies when the transaction is done, not at each step
set local check_function_bodies = off;

create temporary table vmap (scope text not null, old_value text not null, new_value text not null) on commit drop;

insert into vmap (scope, old_value, new_value) values
  -- invoice statuses
  ('*', 'Emessa', 'issued'), ('*', 'Incassata', 'paid'), ('*', 'Annullata', 'cancelled'), ('*', 'Scaduta', 'overdue'),
  -- commission stages
  ('*', 'Provvigioni teoriche', 'theoretical'), ('*', 'Provvigioni fatturate', 'invoiced'),
  ('*', 'Provvigioni maturate', 'matured'), ('*', 'Provvigioni ricevute', 'received'),
  -- notification event names
  ('*', 'messaggi', 'messages'), ('*', 'documenti', 'documents'), ('*', 'promemoria', 'reminders'),
  -- supplier invoice states and the log of allocations
  ('*', 'da_verificare', 'to_check'), ('*', 'da_assegnare', 'to_assign'), ('*', 'parziale', 'partial'), ('*', 'assegnata', 'assigned'),
  ('*', 'modificata', 'changed'), ('*', 'rimossa', 'removed'),
  -- signature states
  ('*', 'da_preparare', 'to_prepare'), ('*', 'pronto', 'ready'), ('*', 'inviato', 'sent'), ('*', 'firmato_in_parte', 'partly_signed'),
  ('*', 'firmato', 'signed'), ('*', 'archiviato', 'archived'),
  -- review reason
  ('*', 'no_pratica', 'no_case'),
  -- permission keys
  ('*', 'pratiche.set_beneficiary', 'cases.set_beneficiary'), ('*', 'scadenze.manage', 'deadlines.manage'),
  ('*', 'beni.manage', 'assets.manage'), ('*', 'invoices.link_pratica', 'invoices.link_case'),
  -- supplier invoice filters and facets
  ('si_facets,si_filtered,si_attrs', 'stato', 'status'), ('si_facets,si_filtered,si_attrs', 'bene', 'asset'),
  ('si_facets,si_filtered,si_attrs', 'fornitore', 'supplier'), ('si_facets,si_filtered,si_attrs', 'categoria', 'category'),
  ('si_facets,si_filtered,si_attrs', 'anno', 'year'), ('si_facets,si_filtered,si_attrs', 'tipo', 'type'),
  ('si_facets,si_filtered,si_attrs', 'avvisi', 'alerts'), ('si_facets,si_filtered,si_attrs', 'si', 'yes'),
  ('si_facets,si_filtered,si_attrs', 'fattura', 'invoice'), ('si_facets,si_filtered,si_attrs', 'nota_credito', 'credit_note'),
  -- JSON that the supplier invoice screens read
  ('supplier_invoices_page,supplier_invoices_summary', 'beni', 'assets'), ('supplier_invoices_page,supplier_invoices_summary', 'on_beni', 'on_assets'),
  ('supplier_invoices_page,supplier_invoices_summary', 'altro', 'other'), ('supplier_invoices_page,supplier_invoices_summary', 'non_applicabile', 'not_applicable'),
  ('supplier_invoices_page,supplier_invoices_summary', 'fornitori', 'suppliers'), ('supplier_invoices_page,supplier_invoices_summary', 'categorie', 'categories'),
  ('supplier_invoice_proposal', 'pratiche', 'cases'),
  ('set_case_beneficiary', 'cliente', 'company'), ('set_case_beneficiary', 'beneficiaria', 'beneficiary_company'),
  ('set_case_beneficiary', 'diversa_dal_cliente', 'differs_from_company'),
  ('import_supplier_invoices', 'duplicato', 'duplicate'), ('import_supplier_invoices', 'inserita', 'inserted'),
  ('import_supplier_invoices', 'errore', 'error'), ('import_supplier_invoices', 'cliente_trovato', 'company_found'),
  ('sync_case_assets', 'nome', 'name'), ('sync_case_assets', 'fornitore', 'supplier'), ('sync_case_assets', 'beni_attivi', 'active_assets'),
  ('sync_companies', 'pratiche_linked', 'cases_linked');

do $$
declare
  r record; m record;
  old_def text; new_def text;
  fn_sig text; acl record;
  d text;
  ident_rules text[][] := array[['\mbene_ids\M', 'asset_ids']];
  rule text[];
  opts text;
begin
  -- 1. function bodies ------------------------------------------------------------------------------------------------------------
  for r in
    select p.oid, p.proname, p.proacl, p.proowner from pg_proc p
     where p.pronamespace in ('public'::regnamespace, 'private'::regnamespace) and p.prokind = 'f'
  loop
    old_def := pg_get_functiondef(r.oid);
    new_def := old_def;
    for m in select old_value, new_value from vmap where scope = '*' or r.proname = any (string_to_array(scope, ',')) loop
      new_def := replace(new_def, quote_literal(m.old_value), quote_literal(m.new_value));
    end loop;
    foreach rule slice 1 in array ident_rules loop
      new_def := regexp_replace(new_def, rule[1], rule[2], 'g');
    end loop;
    if r.proname = 'supplier_invoice_proposal' then
      new_def := regexp_replace(regexp_replace(new_def, '\mbeni_count\M', 'assets_count', 'g'), '\monly_bene\M', 'only_asset', 'g');
    end if;
    continue when new_def = old_def;

    begin
      execute new_def;
    exception when invalid_function_definition then
      fn_sig := r.oid::regprocedure::text;
      create temporary table if not exists acl_keep (grantee text, priv text) on commit drop;
      truncate acl_keep;
      insert into acl_keep
        select case when x.grantee = 0 then 'public' else x.grantee::regrole::text end, x.privilege_type
          from aclexplode(coalesce(r.proacl, acldefault('f', r.proowner))) x
         where x.grantee <> r.proowner;
      execute format('drop function %s', fn_sig);
      execute new_def;
      execute format('revoke all on function %s from public, anon, authenticated, service_role', fn_sig);
      for acl in select * from acl_keep loop
        execute format('grant %s on function %s to %s', acl.priv, fn_sig, case when acl.grantee = 'public' then 'public' else quote_ident(acl.grantee) end);
      end loop;
    end;
  end loop;

  -- 2. views (same columns, so create or replace; the options such as security_invoker are put back) ---------------------------
  for r in
    select c.oid, c.oid::regclass::text as rel, c.reloptions from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'v'
  loop
    old_def := rtrim(pg_get_viewdef(r.oid), E'; \n');
    new_def := old_def;
    for m in select old_value, new_value from vmap where scope = '*' loop
      new_def := replace(new_def, quote_literal(m.old_value), quote_literal(m.new_value));
    end loop;
    continue when new_def = old_def;
    opts := case when r.reloptions is null then '' else ' with (' || array_to_string(r.reloptions, ', ') || ')' end;
    execute format('create or replace view %s%s as %s', r.rel, opts, new_def);
  end loop;

  -- 3. stored rows and the check constraint -------------------------------------------------------------------------------------
  alter table public.qonto_documents drop constraint qonto_documents_status_check;
  alter table public.qonto_documents disable trigger user;
  update public.qonto_documents set status = case status when 'Emessa' then 'issued' when 'Incassata' then 'paid' when 'Annullata' then 'cancelled' else status end
   where status in ('Emessa', 'Incassata', 'Annullata');
  alter table public.qonto_documents enable trigger user;
  alter table public.qonto_documents add constraint qonto_documents_status_check check (status in ('issued', 'paid', 'cancelled'));
  select column_default into d from information_schema.columns where table_schema = 'public' and table_name = 'qonto_documents' and column_name = 'status';
  if d like '%Emessa%' then alter table public.qonto_documents alter column status set default 'issued'; end if;

  update public.notifications set event = case event when 'messaggi' then 'messages' when 'documenti' then 'documents' when 'promemoria' then 'reminders' end
   where event in ('messaggi', 'documenti', 'promemoria');
  update public.commission_corrections set
         old_stage = coalesce((select new_value from vmap where old_value = old_stage and scope = '*'), old_stage),
         new_stage = coalesce((select new_value from vmap where old_value = new_stage and scope = '*'), new_stage)
   where old_stage like 'Provvigioni %' or new_stage like 'Provvigioni %';
  update public.supplier_invoice_allocation_log set action = case action when 'assegnata' then 'assigned' when 'modificata' then 'changed' when 'rimossa' then 'removed' end
   where action in ('assegnata', 'modificata', 'rimossa');

  update public.signature_attachments set signers = array_replace(signers, 'cliente', 'client') where 'cliente' = any (signers);

  -- 4. permission keys: role_permissions follows by on update cascade; the policies that name them are written again ---------------------
  update public.permissions p set key = vm.new_value from vmap vm
   where vm.scope = '*' and vm.old_value = p.key and vm.old_value ~ '^(pratiche|scadenze|beni|invoices)\.';
  for r in
    select pol.schemaname, pol.tablename, pol.policyname, pol.qual, pol.with_check from pg_policies pol where pol.schemaname = 'public'
  loop
    old_def := coalesce(r.qual, '');
    new_def := old_def;
    d := coalesce(r.with_check, '');
    opts := d;
    for m in select old_value, new_value from vmap where scope = '*' and old_value ~ '^(pratiche|scadenze|beni|invoices)\.' loop
      new_def := replace(new_def, quote_literal(m.old_value), quote_literal(m.new_value));
      opts := replace(opts, quote_literal(m.old_value), quote_literal(m.new_value));
    end loop;
    if r.qual is not null and new_def <> old_def then
      execute format('alter policy %I on %I.%I using (%s)', r.policyname, r.schemaname, r.tablename, new_def);
    end if;
    if r.with_check is not null and opts <> d then
      execute format('alter policy %I on %I.%I with check (%s)', r.policyname, r.schemaname, r.tablename, opts);
    end if;
  end loop;
end $$;
