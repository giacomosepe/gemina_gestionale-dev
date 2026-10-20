-- Bell events from Zite (migration 20261020191340). Same pattern as 001-003: one DO block, rolled back by
-- the final RAISE; the message is the report. The bridge's insert is mirrored as a plain insert (full rights).

do $$
declare
  org      uuid := (select id from public.organizations limit 1);
  u_s1     uuid := gen_random_uuid();
  u_s2     uuid := gen_random_uuid();
  n        int;
  report   text := '';
  failures int := 0;
  ok       boolean;
begin
  insert into auth.users (id, email, aud, role) values
    (u_s1, 't4-s1@example.test', 'authenticated', 'authenticated'),
    (u_s2, 't4-s2@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 'zite-t4-s1' where id = u_s1;
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 'zite-t4-s2' where id = u_s2;

  -- as the bridge's notify does
  insert into public.notifications (organization_id, recipient_id, kind, actor_id, label, event, link, event_key)
    values (org, u_s1, 'event', u_s2, 'Ti è stata assegnata: test', 'attivita-assegnata', 'attivita:abc', 'zite-row-1');
  begin
    insert into public.notifications (organization_id, recipient_id, kind, label, event, event_key)
      values (org, u_s1, 'event', 'again', 'attivita-assegnata', 'zite-row-1');
    ok := false;
  exception when unique_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s the same Zite event cannot arrive twice\n', case when ok then 'PASS' else 'FAIL' end);
  begin
    insert into public.notifications (organization_id, recipient_id, kind, label, event_key)
      values (org, u_s1, 'event', repeat('x', 301), 'zite-row-2');
    ok := false;
  exception when check_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s labels longer than 300 characters are refused\n', case when ok then 'PASS' else 'FAIL' end);

  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.notifications where kind = 'event' and link = 'attivita:abc';
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s the recipient sees the event with its link (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  update public.notifications set read_at = now() where event_key = 'zite-row-1';
  get diagnostics n = row_count;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s the recipient can mark it read (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  begin
    update public.notifications set link = 'pratica:other' where event_key = 'zite-row-1';
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s the recipient cannot change the link\n', case when ok then 'PASS' else 'FAIL' end);
  begin
    insert into public.notifications (organization_id, recipient_id, kind, label, event_key)
      values (org, u_s2, 'event', 'forged', 'forged-1');
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a browser cannot create an event\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', u_s2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.notifications where event_key = 'zite-row-1';
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s another colleague does not see it (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  reset role;

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
