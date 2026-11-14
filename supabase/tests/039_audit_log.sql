-- Audit log (PM-150). One DO block, rolled back by the final RAISE.
-- 1. every business table has the audit trigger; 2. insert, update and delete each leave one row; 3. only admins read, only their organization.

do $$
declare
  org_a uuid := (select id from public.organizations order by created_at limit 1);
  org_b uuid := gen_random_uuid();
  adm uuid := gen_random_uuid(); mgr uuid := gen_random_uuid(); adm_b uuid := gen_random_uuid();
  co uuid := gen_random_uuid();
  n int; t text; r record;
  report text := '';
  failures int := 0;
begin
  -- 1. structure -------------------------------------------------------------------------------------------------------------
  for t in
    select c.relname from pg_class c
     where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and c.relname <> all (private.audit_excluded_tables())
       and not exists (select 1 from pg_trigger g where g.tgrelid = c.oid and g.tgname = 'audit' and not g.tgisinternal)
  loop
    failures := failures + 1; report := report || format(E'\nFAIL table %s has no audit trigger (add it, or list it in private.audit_excluded_tables)', t);
  end loop;

  -- setup: an admin and a manager in A, an admin in B
  insert into public.organizations (id, name) values (org_b, 'Test organization B');
  insert into public.role_permissions (staff_role, permission, scope, organization_id)
    select staff_role, permission, scope, org_b from public.role_permissions where organization_id = org_a;
  insert into auth.users (id, email, aud, role) values
    (adm, 'audit-adm@example.test', 'authenticated', 'authenticated'), (mgr, 'audit-mgr@example.test', 'authenticated', 'authenticated'),
    (adm_b, 'audit-adm-b@example.test', 'authenticated', 'authenticated');
  perform set_config('gemina.staff_role_change', 'on', true);
  update public.profiles set role = 'staff', staff_role = 'admin',   organization_id = org_a, zite_user_id = 'audit-adm' where id = adm;
  update public.profiles set role = 'staff', staff_role = 'manager', organization_id = org_a, zite_user_id = 'audit-mgr' where id = mgr;
  update public.profiles set role = 'staff', staff_role = 'admin',   organization_id = org_b, zite_user_id = 'audit-adm-b' where id = adm_b;
  perform set_config('gemina.staff_role_change', 'off', true);

  -- 2. insert, update, delete as the admin of A --------------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.companies (id, name, zite_azienda_id) values (co, 'Audit Co', 'audit-co');
  update public.companies set name = 'Audit Co renamed' where id = co;
  update public.companies set name = name where id = co;                         -- no change: no row
  delete from public.companies where id = co;

  select count(*) into n from public.audit_log where table_name = 'companies' and row_id = co::text;
  if n <> 3 then failures := failures + 1; report := report || format(E'\nFAIL expected 3 log rows (insert, update, delete), found %s', n);
  else report := report || E'\nok   insert, update and delete leave one row each (a no-change update leaves none)'; end if;

  select * into r from public.audit_log where table_name = 'companies' and row_id = co::text and action = 'update';
  if r.actor_id is distinct from adm or r.old_values ->> 'name' <> 'Audit Co' or r.new_values ->> 'name' <> 'Audit Co renamed'
     or r.new_values ? 'id' or r.organization_id <> org_a then
    failures := failures + 1; report := report || E'\nFAIL update row: actor, changed columns or organization are wrong';
  else report := report || E'\nok   update row holds the actor, the changed columns only, and the organization'; end if;

  begin
    insert into public.audit_log (organization_id, table_name, action) values (org_a, 'x', 'insert');
    failures := failures + 1; report := report || E'\nFAIL the admin wrote to the audit log';
  exception when others then report := report || E'\nok   nobody writes to the audit log through the API'; end;
  begin
    delete from public.audit_log;
    get diagnostics n = row_count;
    if n > 0 then failures := failures + 1; report := report || E'\nFAIL the admin deleted audit rows'; else report := report || E'\nok   nobody deletes audit rows'; end if;
  exception when others then report := report || E'\nok   nobody deletes audit rows'; end;
  reset role;

  -- 3. who reads --------------------------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.audit_log;
  if n <> 0 then failures := failures + 1; report := report || format(E'\nFAIL a manager reads %s audit rows', n);
  else report := report || E'\nok   a manager reads nothing'; end if;
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', adm_b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.audit_log where table_name = 'companies';
  if n <> 0 then failures := failures + 1; report := report || format(E'\nFAIL the admin of another organization reads %s rows', n);
  else report := report || E'\nok   the admin of another organization reads nothing of A'; end if;
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.audit_log where table_name = 'companies';
  if n <> 3 then failures := failures + 1; report := report || format(E'\nFAIL the admin reads %s rows of 3', n);
  else report := report || E'\nok   the admin reads the rows of the organization'; end if;
  reset role;

  raise exception 'TEST REPORT 039 audit log: % failure(s)%', failures, report;
end $$;
