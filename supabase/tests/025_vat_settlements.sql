-- VAT settlements table (migration vat_settlements, PRDDISC-17). One DO block, rolled back by the final RAISE. Made-up rows only (no real settlement data).
do $$
declare
  u_admin uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid(); u_part uuid := gen_random_uuid(); u_client uuid := gen_random_uuid();
  org uuid := (select id from public.organizations limit 1);
  pa uuid; cclient uuid; vid uuid := gen_random_uuid();
  k int; n int; report text := ''; failures int := 0; ok boolean;
begin
  insert into auth.users (id, email, aud, role) values
    (u_admin, 't25-admin@example.test', 'authenticated', 'authenticated'), (u_mgr, 't25-mgr@example.test', 'authenticated', 'authenticated'),
    (u_part, 't25-part@example.test', 'authenticated', 'authenticated'), (u_client, 't25-client@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'admin', zite_user_id = 't25-z-admin' where id = u_admin;
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't25-z-mgr' where id = u_mgr;
  update public.profiles set role = 'partner' where id = u_part;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t25-a', 'T25 A', 't25-part@example.test', org) returning id into pa;
  insert into public.partner_members (partner_id, profile_id) values (pa, u_part);
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T25 client', 't25-client', org) returning id into cclient;
  insert into public.company_members (company_id, profile_id) values (cclient, u_client);
  update public.profiles set role = 'client' where id = u_client;

  -- 1. an administrator writes: insert, update
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.vat_settlements (id, period, year, quarter, vat_credit_other_cents, vat_advance_cents, note) values (vid, 'T4 2031', 2031, 4, 12050, 99900, 'prova');
  insert into public.vat_settlements (period, year, quarter, vat_credit_other_cents) values ('T1 2031', 2031, 1, null);
  update public.vat_settlements set vat_credit_other_cents = 5000 where id = vid;
  ok := (select vat_credit_other_cents = 5000 and vat_advance_cents = 99900 and organization_id = org from public.vat_settlements where id = vid)
        and (select count(*) from public.vat_settlements where year = 2031) = 2;
  -- (the SQL connector holds back DELETE statements, so the delete policy is checked in the structure test instead)
  failures := failures + (not ok)::int;
  report := report || format(E'%s an administrator inserts and updates\n', case when ok then 'PASS' else 'FAIL' end);

  -- 2. table rules
  k := 0;
  begin insert into public.vat_settlements (period, year, quarter, vat_advance_cents) values ('T2 2031', 2031, 2, 100); exception when check_violation then k := k + 1; end;
  begin insert into public.vat_settlements (period, year, quarter) values ('T4 2031', 2031, 4); exception when unique_violation then k := k + 1; end;
  begin insert into public.vat_settlements (period, year, quarter, vat_credit_other_cents) values ('T3 2031', 2031, 3, -1); exception when check_violation then k := k + 1; end;
  begin insert into public.vat_settlements (period, year, quarter) values ('Q3 2031', 2031, 3); exception when check_violation then k := k + 1; end;
  begin insert into public.vat_settlements (period, year, quarter) values ('T5 2031', 2031, 5); exception when check_violation then k := k + 1; end;
  ok := k = 5;
  failures := failures + (not ok)::int;
  report := report || format(E'%s refused: advance outside Q4, a second row for the same quarter, a negative amount, a wrong period label, quarter 5 (%s of 5)\n', case when ok then 'PASS' else 'FAIL' end, k);
  reset role;

  -- 3. a manager reads but cannot insert or update
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  set local role authenticated;
  n := (select count(*) from public.vat_settlements where year = 2031);
  k := 0;
  begin insert into public.vat_settlements (period, year, quarter) values ('T1 2032', 2032, 1); exception when insufficient_privilege then k := k + 1; end;
  update public.vat_settlements set vat_credit_other_cents = 1 where id = vid;
  get diagnostics k = row_count;   -- 0: RLS hides the row from the update
  ok := n = 2 and k = 0;
  k := 0;
  begin insert into public.vat_settlements (period, year, quarter) values ('T1 2032', 2032, 1); exception when insufficient_privilege then k := 1; end;
  ok := ok and k = 1 and (select vat_credit_other_cents = 5000 from public.vat_settlements where id = vid);
  failures := failures + (not ok)::int;
  report := report || format(E'%s a manager reads the rows but cannot insert or update\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  -- 4. a segnalatore, a client and an anonymous caller see and write nothing
  k := 0;
  perform set_config('request.jwt.claims', json_build_object('sub', u_part, 'role', 'authenticated')::text, true);
  set local role authenticated;
  n := (select count(*) from public.vat_settlements);
  begin insert into public.vat_settlements (period, year, quarter) values ('T1 2033', 2033, 1); exception when insufficient_privilege then k := k + 1; end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', u_client, 'role', 'authenticated')::text, true);
  set local role authenticated;
  n := n + (select count(*) from public.vat_settlements);
  begin insert into public.vat_settlements (period, year, quarter) values ('T1 2033', 2033, 1); exception when insufficient_privilege then k := k + 1; end;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  set local role anon;
  begin perform count(*) from public.vat_settlements; exception when insufficient_privilege then k := k + 1; end;
  reset role;
  ok := n = 0 and k = 3;
  failures := failures + (not ok)::int;
  report := report || format(E'%s partner and client see no row and cannot write; anonymous is refused (%s of 3)\n', case when ok then 'PASS' else 'FAIL' end, k);

  -- 5. structure: RLS on, only the four staff policies, no partner or client policy
  ok := (select relrowsecurity from pg_class where oid = 'public.vat_settlements'::regclass)
        and (select count(*) from pg_policies where schemaname = 'public' and tablename = 'vat_settlements') = 4
        and exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'vat_settlements' and cmd = 'DELETE' and qual like '%admin%')
        and not has_table_privilege('anon', 'public.vat_settlements', 'select')
        and exists (select 1 from pg_trigger where tgrelid = 'public.vat_settlements'::regclass and tgname = 'vat_settlements_touch');
  failures := failures + (not ok)::int;
  report := report || format(E'%s RLS is on with exactly four policies (staff read, administrator insert/update/delete); anon has no access; updated_at trigger present\n', case when ok then 'PASS' else 'FAIL' end);

  raise exception E'TEST REPORT (025 vat settlements): % failure(s)\n%', failures, report;
end $$;
