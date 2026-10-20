-- Staff follow Ruoli (migration 20261020190000). Same pattern as 001/002: one DO block, everything
-- rolled back by the final RAISE; the error message is the report.
-- What the bridge does with the staff secret is mirrored here as plain updates (it runs with full rights).

do $$
declare
  org      uuid := (select id from public.organizations limit 1);
  u_s1     uuid := gen_random_uuid();  -- stays in the team
  u_old    uuid := gen_random_uuid();  -- leaves the team
  u_ref    uuid := gen_random_uuid();  -- referrer
  p_ref    uuid;
  conv     uuid;
  n        int;
  report   text := '';
  failures int := 0;
  ok       boolean;
begin
  insert into auth.users (id, email, aud, role) values
    (u_s1,  't3-s1@example.test',  'authenticated', 'authenticated'),
    (u_old, 't3-old@example.test', 'authenticated', 'authenticated'),
    (u_ref, 't3-ref@example.test', 'authenticated', 'authenticated');
  -- as the bridge does in resolveStaff
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 'zite-t3-s1' where id = u_s1;
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 'zite-t3-old' where id = u_old;
  update public.profiles set role = 'partner' where id = u_ref;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id)
    values ('test3-ref', 'Test referrer 3', 't3-ref@example.test', org) returning id into p_ref;
  insert into public.partner_members (partner_id, profile_id) values (p_ref, u_ref);
  insert into public.conversations (kind, title, partner_id, created_by)
    values ('partner', 'Thread t3', p_ref, u_s1) returning id into conv;

  select count(*) into n from public.profiles where id in (u_s1, u_old) and organization_id = org;
  ok := n = 2; failures := failures + (not ok)::int;
  report := report || format(E'%s a new staff profile gets the organization from the trigger (expect 2, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  -- the same Zite user id cannot sit on two profiles
  begin
    update public.profiles set zite_user_id = 'zite-t3-s1' where id = u_old;
    ok := false;
  exception when unique_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a Zite user id is unique across profiles\n', case when ok then 'PASS' else 'FAIL' end);

  -- a staff member cannot change their own role, staff role or Zite id from a browser
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    update public.profiles set zite_user_id = 'hijack' where id = u_s1;
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a browser cannot set zite_user_id\n', case when ok then 'PASS' else 'FAIL' end);
  begin
    update public.profiles set staff_role = 'admin' where id = u_s1;
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a browser cannot promote itself to admin\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  -- leaving the team, as the bridge does in staffLeave
  update public.profiles set role = 'former_staff', staff_role = null, organization_id = null where id = u_old;
  select count(*) into n from public.profiles where id = u_old;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s the former staff profile is kept for history (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  perform set_config('request.jwt.claims', json_build_object('sub', u_old, 'role', 'authenticated')::text, true);
  set local role authenticated;
  ok := not private.is_staff(); failures := failures + (not ok)::int;
  report := report || format(E'%s former staff is no longer staff for the rules\n', case when ok then 'PASS' else 'FAIL' end);
  select count(*) into n from public.conversations;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s former staff sees no conversations (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.comments;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s former staff sees no comments (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  begin
    insert into public.messages (conversation_id, sender_id, body) values (conv, u_old, 'still here?');
    ok := false;
  exception when others then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s former staff cannot write messages\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  -- the referrer writes first: every CURRENT staff member is notified, the former one is not
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.messages (conversation_id, sender_id, body) values (conv, u_ref, 'hello');
  reset role;
  select count(*) into n from public.notifications where conversation_id = conv and recipient_id = u_old;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s former staff gets no notification (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.notifications where conversation_id = conv and recipient_id = u_s1;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s current staff is notified (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  -- coming back: staff again, same profile
  update public.profiles set role = 'staff', staff_role = 'manager' where id = u_old;
  select count(*) into n from public.profiles where id = u_old and role = 'staff' and organization_id = org;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s a person who comes back is staff again on the same profile (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
