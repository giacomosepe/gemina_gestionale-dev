-- English names (Linear PM-191, glossary in docs/migrazione/glossary.md, inventory in rename-inventory.md).
--
-- Renames tables, views, columns, functions, constraints, indexes, policies, triggers and the record_type enum values that were still
-- Italian. NOT touched here, on purpose (each has its own later step, see rename-inventory.md):
--   * the zite_* / record_zite_id / trattativa_zite_id columns (they become one legacy_id column when the import runner is built),
--   * the permission keys (beni.manage, scadenze.manage, pratiche.set_beneficiary, invoices.link_pratica): they are data, not names,
--   * text values such as invoice statuses, user-visible messages and the JSON keys that functions return,
--   * the Edge Function folder names, and the one-off scripts in supabase/scripts.
-- Function bodies are rewritten by identifier only (word-bounded), never inside messages. The guard test 036 keeps the names English.

create function pg_temp.en_name(n text) returns text language plpgsql as $f$
declare
  s text := n; prev text; m text[];
begin
  if n like '%zite%' then return n; end if;
  foreach m slice 1 in array array[
    ['pratiche','cases'], ['pratica','case'], ['beni','assets'], ['bene','asset'], ['scadenze','deadlines'], ['scadenza','deadline'],
    ['ricevuta','receipt'], ['ordine','sort_order'], ['nome','name'], ['numero','number'], ['tipo','type'], ['dato','data_request'],
    ['trattativa','deal'], ['azienda','company'], ['archiviata','archived']] loop
    loop
      prev := s;
      s := regexp_replace(s, '(^|[^a-z0-9])' || m[1] || '([^a-z0-9]|$)', '\1' || m[2] || '\2', 'g');
      exit when s = prev;
    end loop;
  end loop;
  return replace(s, '_o_', '_or_');
end $f$;

do $$
declare
  r record;
  new_name text;
  old_def text; new_def text;
  rule text[];
  col_map jsonb := jsonb_build_object(
    'pratica_id', 'case_id', 'pratica_code', 'case_code', 'pratica_title', 'case_title', 'pratica_link_source', 'case_link_source',
    'bene_id', 'asset_id', 'new_bene_id', 'new_asset_id', 'old_bene_id', 'old_asset_id', 'bene_name', 'asset_name',
    'on_beni_pct', 'on_assets_pct', 'on_beni_amount', 'on_assets_amount', 'scadenza_id', 'deadline_id', 'dato_id', 'data_request_id');
  deadline_cols jsonb := jsonb_build_object(
    'tipo', 'type', 'numero', 'number', 'nome', 'name', 'ordine', 'sort_order', 'data', 'due_on', 'consegnata_il', 'delivered_on',
    'ricevuta', 'receipt', 'archiviata', 'archived');
  fn_map jsonb := '{}'::jsonb;
  acl record;
  fn_sig text;
  rules text[][];
begin
  -- 1. tables and views ----------------------------------------------------------------------------------------------------------
  alter table public.pratiche rename to cases;
  alter table public.scadenze rename to deadlines;
  alter table public.beni rename to assets;
  alter table public.bene_values rename to asset_values;
  alter table public.bene_documents rename to asset_documents;
  alter view public.pratica_payment_status_v rename to case_payment_status_v;
  alter view public.supplier_invoice_by_bene rename to supplier_invoice_by_asset;
  alter view public.supplier_invoice_pratica_summary rename to supplier_invoice_case_summary;

  -- 2. columns (tables and views) -------------------------------------------------------------------------------------------------
  for r in
    select c.oid::regclass::text as rel, c.relname, c.relkind, a.attname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
      join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
     where c.relkind in ('r', 'p', 'v')
  loop
    new_name := col_map ->> r.attname;
    if r.relname = 'deadlines' and deadline_cols ? r.attname then new_name := deadline_cols ->> r.attname; end if;
    if new_name is not null then
      if r.relkind = 'v' then
        execute format('alter view %s rename column %I to %I', r.rel, r.attname, new_name);
      else
        execute format('alter table %s rename column %I to %I', r.rel, r.attname, new_name);
      end if;
    end if;
  end loop;

  -- 3. function names (keeps grants, comments and the triggers that use them) ---------------------------------------------------
  for r in
    select p.oid, p.proname from pg_proc p
     where p.pronamespace in ('public'::regnamespace, 'private'::regnamespace) and p.prokind = 'f' and pg_temp.en_name(p.proname) <> p.proname
  loop
    new_name := pg_temp.en_name(r.proname);
    fn_map := fn_map || jsonb_build_object(r.proname, new_name);
    execute format('alter function %s rename to %I', r.oid::regprocedure, new_name);
  end loop;

  -- 4. function bodies: identifiers only -------------------------------------------------------------------------------------------
  rules := array[
    ['\mpublic\.pratiche\M', 'public.cases'], ['\mpublic\.scadenze\M', 'public.deadlines'], ['\mpublic\.beni\M', 'public.assets'],
    ['\mpublic\.bene_values\M', 'public.asset_values'], ['\mpublic\.bene_documents\M', 'public.asset_documents'],
    ['\mpublic\.pratica_payment_status_v\M', 'public.case_payment_status_v'],
    ['\mpublic\.supplier_invoice_by_bene\M', 'public.supplier_invoice_by_asset'],
    ['\mpublic\.supplier_invoice_pratica_summary\M', 'public.supplier_invoice_case_summary'],
    ['\mp_pratica\M', 'p_case'], ['\mp_bene\M', 'p_asset'], ['\mp_beni\M', 'p_assets']];
  for r in select key, value from jsonb_each_text(col_map) loop
    rules := rules || array[array['\m' || r.key || '\M', r.value]];
  end loop;
  for r in select key, value from jsonb_each_text(fn_map) loop
    rules := rules || array[array['\m' || r.key || '\M', r.value]];
  end loop;

  for r in
    select p.oid, p.proname, p.pronamespace::regnamespace::text as ns, p.proargnames, p.proacl, p.proowner
      from pg_proc p
     where p.pronamespace in ('public'::regnamespace, 'private'::regnamespace) and p.prokind = 'f'
  loop
    old_def := pg_get_functiondef(r.oid);
    new_def := old_def;
    foreach rule slice 1 in array rules loop
      new_def := regexp_replace(new_def, rule[1], rule[2], 'g');
    end loop;
    -- the deadline columns, only where the functions use them
    if r.proname in ('deadlines_before_write', 'signature_attachments_before_write') then
      for rule in select array[k, v] from jsonb_each_text(deadline_cols) as t(k, v) loop
        new_def := regexp_replace(new_def, '\m(new|old|s)\.' || rule[1] || '\M', '\1.' || rule[2], 'g');
      end loop;
    end if;
    continue when new_def = old_def;

    begin
      execute new_def;   -- create or replace: same signature, grants stay
    exception when invalid_function_definition then
      -- an argument or an OUT column of the function is renamed: drop and create again, with the same grants
      fn_sig := r.oid::regprocedure::text;
      create temporary table if not exists pg_temp.acl_keep (grantee text, priv text) on commit drop;
      truncate pg_temp.acl_keep;
      insert into pg_temp.acl_keep
        select case when x.grantee = 0 then 'public' else x.grantee::regrole::text end, x.privilege_type
          from aclexplode(coalesce(r.proacl, acldefault('f', r.proowner))) x
         where x.grantee <> r.proowner;
      execute format('drop function %s', fn_sig);
      execute new_def;   -- same argument types, so the same signature text points at the new function
      execute format('revoke all on function %s from public, anon, authenticated, service_role', fn_sig);
      for acl in select * from pg_temp.acl_keep loop
        execute format('grant %s on function %s to %s', acl.priv, fn_sig, case when acl.grantee = 'public' then 'public' else quote_ident(acl.grantee) end);
      end loop;
    end;
  end loop;

  -- 5. constraints, indexes, policies, triggers -----------------------------------------------------------------------------------
  for r in
    select c.conrelid::regclass::text as rel, c.conname from pg_constraint c
     where c.connamespace = 'public'::regnamespace and c.conrelid <> 0 and pg_temp.en_name(c.conname) <> c.conname
  loop
    execute format('alter table %s rename constraint %I to %I', r.rel, r.conname, pg_temp.en_name(r.conname));
  end loop;
  for r in
    select i.indexname from pg_indexes i where i.schemaname = 'public' and pg_temp.en_name(i.indexname) <> i.indexname
  loop
    execute format('alter index public.%I rename to %I', r.indexname, pg_temp.en_name(r.indexname));
  end loop;
  for r in
    select p.schemaname, p.tablename, p.policyname from pg_policies p
     where p.schemaname = 'public' and pg_temp.en_name(p.policyname) <> p.policyname
  loop
    execute format('alter policy %I on %I.%I rename to %I', r.policyname, r.schemaname, r.tablename, pg_temp.en_name(r.policyname));
  end loop;
  for r in
    select t.tgname, t.tgrelid::regclass::text as rel from pg_trigger t
     where not t.tgisinternal and t.tgrelid in (select oid from pg_class where relnamespace = 'public'::regnamespace)
       and pg_temp.en_name(t.tgname) <> t.tgname
  loop
    execute format('alter trigger %I on %s rename to %I', r.tgname, r.rel, pg_temp.en_name(r.tgname));
  end loop;

  -- 6. enum values ----------------------------------------------------------------------------------------------------------------
  alter type public.record_type rename value 'azienda' to 'company';
  alter type public.record_type rename value 'contatto' to 'contact';
  alter type public.record_type rename value 'trattativa' to 'deal';
  alter type public.record_type rename value 'pratica' to 'case';
  alter type public.record_type rename value 'segnalatore' to 'referrer';
  alter type public.record_type rename value 'attivita' to 'activity';
  alter type public.record_type rename value 'servizio' to 'service';
end $$;
