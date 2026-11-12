-- Staff permissions and roles (migrations staff_permissions_foundation, staff_roles_managed_in_supabase, staff_permissions_enforced,
-- staff_leave_francesca_and_partner_reference_manager; 2026-11-12). One DO block, everything rolled back by the final RAISE.
-- Uses the real admin and a real manager; a second manager is turned into an associate inside the test only.

do $$
declare
  adm    uuid := (select id from public.profiles where role = 'staff' and staff_role = 'admin' order by created_at limit 1);
  mgr    uuid := (select id from public.profiles where role = 'staff' and staff_role = 'manager' order by created_at limit 1);
  ass    uuid := (select id from public.profiles where role = 'staff' and staff_role = 'manager' order by created_at offset 1 limit 1);
  fake   uuid := '00000000-0000-0000-0000-000000000001';
  pa     uuid := gen_random_uuid();
  co     uuid := (select id from public.companies order by name limit 1);
  ok     boolean;
  n      int;
  msg    text;
  report text := '';
  failures int := 0;
begin
  if adm is null or mgr is null or ass is null then
    raise exception 'TEST NEEDS one admin and two managers';
  end if;

  -- 1. The matrix as filled in on 12 Nov 2026.
  ok := (select count(*) from public.role_permissions where staff_role = 'admin') = 30
    and (select count(*) from public.role_permissions where staff_role = 'manager') = 26
    and (select count(*) from public.role_permissions where staff_role = 'associate') = 20;
  failures := failures + (not ok)::int;
  report := report || format(E'%s matrix: admin 30, manager 26, associate 20 permissions\n', case when ok then 'PASS' else 'FAIL' end);

  -- 2. A role written without set_staff_role (as the bridge does) is ignored for current staff.
  update public.profiles set staff_role = 'admin' where id = mgr;
  ok := (select staff_role from public.profiles where id = mgr) = 'manager';
  failures := failures + (not ok)::int;
  report := report || format(E'%s a direct write of staff_role on current staff is ignored\n', case when ok then 'PASS' else 'FAIL' end);

  -- The second manager becomes an associate for the rest of the test (the way set_staff_role does it).
  perform set_config('gemina.staff_role_change', 'on', true);
  update public.profiles set staff_role = 'associate' where id = ass;
  perform set_config('gemina.staff_role_change', 'off', true);

  -- A segnalatore whose Reference Manager is the admin (not the manager).
  insert into public.partners (id, zite_segnalatore_id, name, reference_manager_id) values (pa, 't35-segnalatore', 'Test 35', adm);

  -- 3. set_staff_role: admin changes another colleague, never themselves; a manager cannot.
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.set_staff_role(ass, 'manager');
  perform public.set_staff_role(ass, 'associate');
  begin perform public.set_staff_role(adm, 'manager'); ok := false; exception when others then ok := true; end;
  reset role;
  ok := ok and (select staff_role from public.profiles where id = ass) = 'associate';
  failures := failures + (not ok)::int;
  report := report || format(E'%s admin changes a colleague''s role, not their own\n', case when ok then 'PASS' else 'FAIL' end);

  perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.set_staff_role(ass, 'admin'); ok := false; exception when insufficient_privilege then ok := true; end;
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a manager cannot change roles\n', case when ok then 'PASS' else 'FAIL' end);

  -- 4. Commission marking: admin and manager pass the permission check (then stop on the empty list), the associate is refused.
  perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.mark_commissions_paid('{}'::uuid[], null); msg := 'ran'; exception when others then msg := sqlerrm; end;
  reset role;
  ok := msg = 'Seleziona almeno una provvigione.';
  perform set_config('request.jwt.claims', json_build_object('sub', ass, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.mark_commissions_paid('{}'::uuid[], null); msg := 'ran'; exception when insufficient_privilege then msg := 'refused'; end;
  reset role;
  ok := ok and msg = 'refused';
  failures := failures + (not ok)::int;
  report := report || format(E'%s mark paid: manager allowed (own scope), associate refused\n', case when ok then 'PASS' else 'FAIL' end);

  -- 5. Admin-only actions: rebuild, credit notes in totals, VAT settlements.
  perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.rebuild_all_commissions(); ok := false; exception when insufficient_privilege then ok := true; end;
  begin perform public.set_credit_notes_included(fake, '{}'::uuid[], true); ok := false; exception when insufficient_privilege then ok := ok and true; end;
  begin insert into public.vat_settlements (period, year, quarter) values ('T1', 2099, 1); ok := false; exception when insufficient_privilege then ok := ok and true; end;
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a manager cannot rebuild commissions, include credit notes or edit VAT settlements\n', case when ok then 'PASS' else 'FAIL' end);

  -- 6. Associate: no upload links; invoices only to companies of their own segnalatori.
  perform set_config('request.jwt.claims', json_build_object('sub', ass, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.create_upload_portal(fake, null, 30); ok := false; exception when insufficient_privilege then ok := true; end;
  begin perform public.link_invoice_to_company(fake, co); ok := false; exception when insufficient_privilege then ok := ok and true; end;
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s associate: no upload links, no invoices for companies of other segnalatori\n', case when ok then 'PASS' else 'FAIL' end);

  -- 7. Segnalatori: the manager edits only the ones they are Reference Manager of; the admin edits all.
  perform set_config('request.jwt.claims', json_build_object('sub', mgr, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.partners set name = 'Test 35 bis' where id = pa;
  get diagnostics n = row_count;
  reset role;
  ok := n = 0;
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.partners set name = 'Test 35 ter' where id = pa;
  get diagnostics n = row_count;
  reset role;
  ok := ok and n = 1;
  failures := failures + (not ok)::int;
  report := report || format(E'%s segnalatori: manager only their own, admin all\n', case when ok then 'PASS' else 'FAIL' end);

  -- 8. Reads stay open: the associate still reads segnalatori and commissions.
  perform set_config('request.jwt.claims', json_build_object('sub', ass, 'role', 'authenticated')::text, true);
  set local role authenticated;
  ok := exists (select 1 from public.partners where id = pa);
  perform 1 from public.commissions limit 1;
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s an associate still reads segnalatori and commissions\n', case when ok then 'PASS' else 'FAIL' end);

  -- 9. The Reference Manager must be current staff.
  begin
    update public.partners set reference_manager_id = (select id from public.profiles where role <> 'staff' limit 1) where id = pa;
    ok := false;
  exception when invalid_parameter_value then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s the Reference Manager must be a current colleague\n', case when ok then 'PASS' else 'FAIL' end);

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
