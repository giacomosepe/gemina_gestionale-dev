-- Organization isolation (PM-149). Two organizations; a staff user in each. Nothing may cross. One DO block, rolled back by the final RAISE.
-- Part 1 is structural (every table is covered), part 2 is behavioural (rows of the other organization are invisible and cannot be written).

do $$
declare
  org_a uuid := (select id from public.organizations order by created_at limit 1);
  org_b uuid := gen_random_uuid();
  ua uuid := gen_random_uuid();
  ub uuid := gen_random_uuid();
  co_a uuid := gen_random_uuid();
  co_b uuid := gen_random_uuid();
  n int; t text;
  report text := '';
  failures int := 0;
begin
  -- 1. structure: every table has organization_id and a restrictive policy, except the listed ones ---------------------------
  for t in
    select c.relname from pg_class c
     where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and c.relname not in ('permissions', 'organizations', 'profiles')
       and not (exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'organization_id' and a.attnotnull and not a.attisdropped)
                and exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname and p.permissive = 'RESTRICTIVE'
                            and p.qual like '%current_organization_id%'))
  loop
    failures := failures + 1; report := report || format(E'\nFAIL table %s has no organization_id not null or no organization policy', t);
  end loop;

  -- 2. behaviour --------------------------------------------------------------------------------------------------------------
  insert into public.organizations (id, name) values (org_b, 'Test organization B');
  -- permissions are kept per organization: a new organization starts with a copy of the matrix of the first one
  insert into public.role_permissions (staff_role, permission, scope, organization_id)
    select staff_role, permission, scope, org_b from public.role_permissions where organization_id = org_a;
  insert into auth.users (id, email, aud, role) values
    (ua, 'iso-a@example.test', 'authenticated', 'authenticated'), (ub, 'iso-b@example.test', 'authenticated', 'authenticated');
  perform set_config('gemina.staff_role_change', 'on', true);
  update public.profiles set role = 'staff', staff_role = 'admin', organization_id = org_a, zite_user_id = 'iso-a' where id = ua;
  update public.profiles set role = 'staff', staff_role = 'admin', organization_id = org_b, zite_user_id = 'iso-b' where id = ub;
  perform set_config('gemina.staff_role_change', 'off', true);
  insert into public.companies (id, name, zite_azienda_id, organization_id) values (co_a, 'Company A', 'iso-co-a', org_a), (co_b, 'Company B', 'iso-co-b', org_b);

  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
  set local role authenticated;

  if private.current_organization_id() is distinct from org_b then failures := failures + 1; report := report || E'\nFAIL helper does not return the organization of staff B';
  else report := report || E'\nok   helper returns the organization of the signed-in user'; end if;

  select count(*) into n from public.companies;
  if n <> 1 or exists (select 1 from public.companies where id = co_a) then failures := failures + 1; report := report || format(E'\nFAIL staff B sees %s companies (expected only its own)', n);
  else report := report || E'\nok   staff B sees only the companies of B'; end if;

  select count(*) into n from public.organizations;
  if n <> 1 then failures := failures + 1; report := report || format(E'\nFAIL staff B sees %s organizations', n);
  else report := report || E'\nok   staff B sees only its organization'; end if;

  select count(*) into n from public.profiles where id = ua;
  if n <> 0 then failures := failures + 1; report := report || E'\nFAIL staff B sees the profile of staff A';
  else report := report || E'\nok   staff B does not see the profile of staff A'; end if;

  update public.companies set name = 'changed' where id = co_a;
  get diagnostics n = row_count;
  if n <> 0 then failures := failures + 1; report := report || E'\nFAIL staff B updated a company of A';
  else report := report || E'\nok   staff B cannot update a company of A'; end if;

  begin
    insert into public.companies (name, zite_azienda_id, organization_id) values ('Intruder', 'iso-x', org_a);
    failures := failures + 1; report := report || E'\nFAIL staff B inserted a company into A';
  exception when others then report := report || E'\nok   staff B cannot insert into A'; end;

  begin
    insert into public.companies (name, zite_azienda_id) values ('Default org', 'iso-d');
    if not exists (select 1 from public.companies where name = 'Default org' and organization_id = org_b) then
      failures := failures + 1; report := report || E'\nFAIL the default organization is not the one of the user';
    else report := report || E'\nok   a new row takes the organization of the user'; end if;
  exception when others then failures := failures + 1; report := report || E'\nFAIL insert with default organization: ' || sqlerrm; end;

  reset role;
  raise exception 'TEST REPORT 038 organization isolation: % failure(s)%', failures, report;
end $$;
