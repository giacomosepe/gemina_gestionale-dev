-- Security guard (revisione provvisoria, 2026-11-10): structural rules that must hold for EVERY object, present and future.
-- New tables and functions in public get grants for anon/authenticated by default (Supabase default privileges), so the
-- protection is RLS: this test fails the day an object is added without it. Read-only; ends with RAISE like 001-031.

do $$
declare
  ok boolean;
  bad text;
  report text := '';
  failures int := 0;
begin
  select string_agg(c.relname, ', ') into bad from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity;
  ok := bad is null; failures := failures + (not ok)::int;
  report := report || format(E'%s every public table has RLS%s\n', case when ok then 'PASS' else 'FAIL' end, coalesce(' (missing: ' || bad || ')', ''));

  select string_agg(c.relname, ', ') into bad from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'v' and not coalesce('security_invoker=true' = any(c.reloptions), false);
  ok := bad is null; failures := failures + (not ok)::int;
  report := report || format(E'%s every public view is security_invoker%s\n', case when ok then 'PASS' else 'FAIL' end, coalesce(' (not: ' || bad || ')', ''));

  select string_agg(c.relname, ', ') into bad from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'm' and has_table_privilege('authenticated', c.oid, 'select');
  ok := bad is null; failures := failures + (not ok)::int;
  report := report || format(E'%s no materialized view readable through the API%s\n', case when ok then 'PASS' else 'FAIL' end, coalesce(' (' || bad || ')', ''));

  select string_agg(p.proname, ', ') into bad from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private') and p.prosecdef and has_function_privilege('anon', p.oid, 'execute');
  ok := bad is null; failures := failures + (not ok)::int;
  report := report || format(E'%s no SECURITY DEFINER function callable without login%s\n', case when ok then 'PASS' else 'FAIL' end, coalesce(' (' || bad || ')', ''));

  select string_agg(p.proname, ', ') into bad from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private') and p.prosecdef
     and not (p.proconfig is not null and exists (select 1 from unnest(p.proconfig) x where x like 'search_path=%'));
  ok := bad is null; failures := failures + (not ok)::int;
  report := report || format(E'%s every SECURITY DEFINER function has a fixed search_path%s\n', case when ok then 'PASS' else 'FAIL' end, coalesce(' (' || bad || ')', ''));

  select string_agg(c.relname, ', ') into bad from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'private' and c.relkind in ('r', 'p', 'v')
     and (has_table_privilege('anon', c.oid, 'select') or has_table_privilege('authenticated', c.oid, 'select'));
  ok := bad is null; failures := failures + (not ok)::int;
  report := report || format(E'%s nothing in schema private readable through the API%s\n', case when ok then 'PASS' else 'FAIL' end, coalesce(' (' || bad || ')', ''));

  select string_agg(id, ', ') into bad from storage.buckets where public or file_size_limit is null;
  ok := bad is null; failures := failures + (not ok)::int;
  report := report || format(E'%s every bucket private and with a size limit%s\n', case when ok then 'PASS' else 'FAIL' end, coalesce(' (' || bad || ')', ''));

  raise exception E'TEST REPORT (read only)\n%FAILURES: %', report, failures;
end $$;
