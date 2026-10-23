-- Pratiche mirror (migration pratiche_mirror, PRDDISC-11): private.sync_pratiche (insert, update, removed, restored, mark missing),
-- company resolved from the azienda, staff-only read, no browser write. Same pattern as 001-013: rolled back by the final RAISE.
-- Made-up rows only. The bridge actions around it are checked by calling the deployed bridge (see the issue).

do $$
declare
  u_s1     uuid := gen_random_uuid();
  u_ref    uuid := gen_random_uuid();
  org      uuid := (select id from public.organizations limit 1);
  p_ref    uuid;
  c1       uuid;
  pa       uuid := gen_random_uuid();
  pb       uuid := gen_random_uuid();
  pc       uuid := gen_random_uuid();
  res      jsonb;
  r        record;
  n        int;
  report   text := '';
  failures int := 0;
  ok       boolean;
begin
  insert into auth.users (id, email, aud, role) values
    (u_s1,  't14-s1@example.test',  'authenticated', 'authenticated'),
    (u_ref, 't14-ref@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't14-zite-s1' where id = u_s1;
  update public.profiles set role = 'partner' where id = u_ref;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t14-ref', 'Test referrer 14', 't14-ref@example.test', org) returning id into p_ref;
  insert into public.partner_members (partner_id, profile_id) values (p_ref, u_ref);
  insert into public.companies (name, zite_azienda_id, organization_id) values ('Test company 14', 't14-azienda', org) returning id into c1;

  ok := (select relrowsecurity from pg_class where oid = 'public.pratiche'::regclass)
        and (select data_type from information_schema.columns where table_schema = 'public' and table_name = 'pratiche' and column_name = 'id') = 'uuid';
  failures := failures + (not ok)::int;
  report := report || format(E'%s RLS on; id is a uuid (the Zite record UUID)\n', case when ok then 'PASS' else 'FAIL' end);

  -- insert two
  res := private.sync_pratiche(jsonb_build_array(
    jsonb_build_object('id', pa, 'code', 'PR-T14-001', 'zite_azienda_id', 't14-azienda', 'status', 'In lavorazione', 'is_open', true, 'total_fee_cents', 1900000, 'removed', false),
    jsonb_build_object('id', pb, 'code', 'PR-T14-002', 'zite_azienda_id', 't14-unknown', 'status', 'Fatturazione completata', 'is_open', false, 'total_fee_cents', null, 'removed', false)));
  select * into r from public.pratiche where id = pa;
  ok := (res->>'inserted')::int = 2 and (res->>'updated')::int = 0 and r.company_id = c1 and r.total_fee_cents = 1900000 and r.is_open and r.removed_at is null
        and (select company_id is null and not is_open and total_fee_cents is null from public.pratiche where id = pb);
  failures := failures + (not ok)::int;
  report := report || format(E'%s two pratiche inserted; company resolved from the azienda (null when the azienda is unknown); fee and is_open as sent (%s)\n', case when ok then 'PASS' else 'FAIL' end, res);

  -- update: Zite changes the fee and the status
  res := private.sync_pratiche(jsonb_build_array(
    jsonb_build_object('id', pa, 'code', 'PR-T14-001', 'zite_azienda_id', 't14-azienda', 'status', 'Lavoro completato', 'is_open', true, 'total_fee_cents', 2100000, 'removed', false)));
  select * into r from public.pratiche where id = pa;
  ok := (res->>'inserted')::int = 0 and (res->>'updated')::int = 1 and r.total_fee_cents = 2100000 and r.status = 'Lavoro completato';
  failures := failures + (not ok)::int;
  report := report || format(E'%s an edit in Zite updates the same row (no duplicate)\n', case when ok then 'PASS' else 'FAIL' end);

  -- the azienda appears in Supabase later: the next sync fills company_id
  select company_id is null into ok from public.pratiche where id = pb;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('Test company 14b', 't14-unknown', org);
  perform private.sync_pratiche(jsonb_build_array(
    jsonb_build_object('id', pb, 'code', 'PR-T14-002', 'zite_azienda_id', 't14-unknown', 'status', 'Fatturazione completata', 'is_open', false, 'total_fee_cents', null, 'removed', false)));
  ok := ok and (select company_id is not null from public.pratiche where id = pb);
  failures := failures + (not ok)::int;
  report := report || format(E'%s a company created later is picked up by the next sync\n', case when ok then 'PASS' else 'FAIL' end);

  -- removed in Zite: kept, marked; then restored
  perform private.sync_pratiche(jsonb_build_array(jsonb_build_object('id', pa, 'code', 'PR-T14-001', 'zite_azienda_id', 't14-azienda', 'status', 'Lavoro completato', 'is_open', true, 'total_fee_cents', 2100000, 'removed', true)));
  ok := (select removed_at is not null from public.pratiche where id = pa);
  perform private.sync_pratiche(jsonb_build_array(jsonb_build_object('id', pa, 'code', 'PR-T14-001', 'zite_azienda_id', 't14-azienda', 'status', 'Lavoro completato', 'is_open', true, 'total_fee_cents', 2100000, 'removed', false)));
  ok := ok and (select removed_at is null from public.pratiche where id = pa);
  failures := failures + (not ok)::int;
  report := report || format(E'%s a pratica deleted in Zite is marked removed, never deleted; it can come back\n', case when ok then 'PASS' else 'FAIL' end);

  -- repair: mark missing (every other pratica not already removed, including the real ones: rolled back)
  res := private.sync_pratiche(jsonb_build_array(jsonb_build_object('id', pa, 'code', 'PR-T14-001', 'zite_azienda_id', 't14-azienda', 'status', 'Lavoro completato', 'is_open', true, 'total_fee_cents', 2100000, 'removed', false)), true);
  ok := (select removed_at is not null from public.pratiche where id = pb) and (select removed_at is null from public.pratiche where id = pa)
        and (res->>'marked_removed')::int >= 1;
  failures := failures + (not ok)::int;
  report := report || format(E'%s the repair marks the pratiche missing from the list as removed and keeps the listed ones\n', case when ok then 'PASS' else 'FAIL' end);

  -- bad input
  begin
    perform private.sync_pratiche('{"not":"array"}'::jsonb);
    ok := false;
  exception when invalid_parameter_value then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s anything but a json array is refused\n', case when ok then 'PASS' else 'FAIL' end);

  -- access
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.pratiche where id in (pa, pb);
  ok := n = 2;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff read the mirror (rows: %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  begin
    insert into public.pratiche (id, code) values (pc, 'PR-T14-003');
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff cannot insert\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    update public.pratiche set total_fee_cents = 1 where id = pa;
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff cannot update\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    delete from public.pratiche where id = pa;
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff cannot delete\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    perform private.sync_pratiche('[]'::jsonb);
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a signed-in user cannot call the sync function\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  ok := (select count(*) from public.pratiche) = 0;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a partner reads zero rows\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  set local role anon;
  begin
    perform count(*) from public.pratiche;
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s anonymous cannot read\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
