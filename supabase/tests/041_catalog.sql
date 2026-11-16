-- Catalogue (PM-153). One DO block, rolled back by the final RAISE.
-- 1. the eight tables exist with RLS; 2. staff read; only administrators (catalog.manage) write; 3. another organization sees and writes nothing;
-- 4. legacy_id is unique per organization; 5. a change leaves an audit row; 6. the constraints refuse values outside the codes.
do $$
declare
  org_a uuid := (select id from public.organizations order by created_at limit 1);
  org_b uuid := gen_random_uuid();
  adm uuid := gen_random_uuid(); mgr uuid := gen_random_uuid(); adm_b uuid := gen_random_uuid();
  cat uuid := gen_random_uuid(); svc uuid := gen_random_uuid();
  n int; t text; ok boolean;
  report text := ''; failures int := 0;
begin
  -- 1. structure
  foreach t in array array['service_categories', 'services', 'data_requests', 'service_fields', 'milestones', 'activity_templates', 'standard_activities', 'lookup_options'] loop
    if not exists (select 1 from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname = t and c.relrowsecurity) then
      failures := failures + 1; report := report || format(E'\nFAIL %s is missing or has no row-level security', t);
    end if;
  end loop;
  if not exists (select 1 from public.role_permissions where organization_id = org_a and staff_role = 'admin' and permission = 'catalog.manage')
     or exists (select 1 from public.role_permissions where organization_id = org_a and staff_role <> 'admin' and permission = 'catalog.manage') then
    failures := failures + 1; report := report || E'\nFAIL catalog.manage is not held by exactly the administrators';
  end if;

  -- setup
  insert into public.organizations (id, name) values (org_b, 'Test organization B');
  insert into public.role_permissions (staff_role, permission, scope, organization_id)
    select staff_role, permission, scope, org_b from public.role_permissions where organization_id = org_a;
  insert into auth.users (id, email, aud, role) values
    (adm, 'cat-adm@example.test', 'authenticated', 'authenticated'), (mgr, 'cat-mgr@example.test', 'authenticated', 'authenticated'),
    (adm_b, 'cat-adm-b@example.test', 'authenticated', 'authenticated');
  perform set_config('gemina.staff_role_change', 'on', true);
  update public.profiles set role = 'staff', staff_role = 'admin',   organization_id = org_a, zite_user_id = 'cat-adm' where id = adm;
  update public.profiles set role = 'staff', staff_role = 'manager', organization_id = org_a, zite_user_id = 'cat-mgr' where id = mgr;
  update public.profiles set role = 'staff', staff_role = 'admin',   organization_id = org_b, zite_user_id = 'cat-adm-b' where id = adm_b;
  perform set_config('gemina.staff_role_change', 'off', true);

  -- 2. the administrator writes; the manager reads but cannot write
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.service_categories (id, name, legacy_id) values (cat, 'Test category', 'legacy-cat-1');
  insert into public.services (id, category_id, name, legacy_id, kind, status, benefit_types) values (svc, cat, 'Test service', 'legacy-svc-1', 'grant_call', 'open', array['Fondo perduto']);
  reset role;
  report := report || E'\nok   the administrator creates a category and a service';

  perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.services where id = svc;
  if n <> 1 then failures := failures + 1; report := report || format(E'\nFAIL a manager reads %s services of 1', n);
  else report := report || E'\nok   a manager reads the catalogue'; end if;
  ok := false;
  begin insert into public.services (name) values ('Manager service'); exception when others then ok := true; end;
  if not ok then failures := failures + 1; report := report || E'\nFAIL a manager inserted a service'; end if;
  update public.services set name = 'Hacked' where id = svc;
  get diagnostics n = row_count;
  if n <> 0 then failures := failures + 1; report := report || E'\nFAIL a manager updated a service'; end if;
  delete from public.services where id = svc;
  get diagnostics n = row_count;
  if n <> 0 then failures := failures + 1; report := report || E'\nFAIL a manager deleted a service'; end if;
  reset role;
  if (select name from public.services where id = svc) <> 'Test service' then failures := failures + 1; report := report || E'\nFAIL the service changed'; end if;
  report := report || E'\nok   a manager cannot insert, update or delete';

  -- 3. another organization
  perform set_config('request.jwt.claims', json_build_object('sub', adm_b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.services;
  if n <> 0 then failures := failures + 1; report := report || format(E'\nFAIL the admin of another organization reads %s services', n);
  else report := report || E'\nok   the admin of another organization reads nothing'; end if;
  update public.services set name = 'Hacked' where id = svc;
  get diagnostics n = row_count;
  if n <> 0 then failures := failures + 1; report := report || E'\nFAIL another organization updated a service'; end if;
  ok := false;
  begin insert into public.services (organization_id, name) values (org_a, 'Cross'); exception when others then ok := true; end;
  if not ok then failures := failures + 1; report := report || E'\nFAIL another organization inserted into organization A'; end if;
  reset role;

  -- 4. legacy_id unique per organization, reusable in another
  ok := false;
  begin insert into public.services (organization_id, name, legacy_id) values (org_a, 'Dup', 'legacy-svc-1'); exception when unique_violation then ok := true; end;
  if not ok then failures := failures + 1; report := report || E'\nFAIL the same legacy_id was accepted twice in one organization'; end if;
  begin insert into public.services (organization_id, name, legacy_id) values (org_b, 'Same id, other organization', 'legacy-svc-1'); report := report || E'\nok   legacy_id is unique per organization';
  exception when others then failures := failures + 1; report := report || E'\nFAIL the same legacy_id was refused in another organization'; end;

  -- 5. audit
  select count(*) into n from public.audit_log where table_name = 'services' and row_id = svc::text and action = 'insert';
  if n <> 1 then failures := failures + 1; report := report || format(E'\nFAIL expected 1 audit row for the service insert, found %s', n);
  else report := report || E'\nok   the insert is in the audit log'; end if;

  -- 6. codes
  foreach t in array array['kind', 'status'] loop
    ok := false;
    begin
      if t = 'kind' then insert into public.services (organization_id, name, kind) values (org_a, 'x', 'bando'); else insert into public.services (organization_id, name, status) values (org_a, 'x', 'Aperto'); end if;
    exception when check_violation then ok := true; end;
    if not ok then failures := failures + 1; report := report || format(E'\nFAIL services.%s accepted a value outside the codes', t); end if;
  end loop;
  ok := false;
  begin insert into public.data_requests (organization_id, name, data_type) values (org_a, 'x', 'Testo'); exception when check_violation then ok := true; end;
  if not ok then failures := failures + 1; report := report || E'\nFAIL data_requests.data_type accepted an Italian label'; end if;

  raise exception 'TEST REPORT 041 catalog: % failure(s)%', failures, report;
end $$;
