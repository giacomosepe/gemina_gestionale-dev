-- Access rules test (messaging). Run in the SQL editor or via execute_sql.
-- Everything happens inside one DO block that ends with RAISE EXCEPTION, so ALL
-- test data is rolled back. The exception message is the report: every line is
-- PASS or FAIL, last line is the number of failures.
-- Covers supabase/tests/README.md, except Realtime and the bridge (tested separately).

do $$
declare
  org        uuid := (select id from public.organizations limit 1);
  u_staff    uuid := gen_random_uuid();
  u_ref_a    uuid := gen_random_uuid();
  u_ref_b    uuid := gen_random_uuid();
  u_client   uuid := gen_random_uuid();
  u_nobody   uuid := gen_random_uuid();
  p_a        uuid;
  p_b        uuid;
  comp       uuid;
  conv_a     uuid;
  conv_b     uuid;
  conv_c     uuid;
  n          int;
  i          int;
  report     text := '';
  failures   int := 0;
  ok         boolean;

  -- helpers are inline (plpgsql has no nested functions)
begin
  ---------------------------------------------------------------- fixtures (as owner)
  insert into auth.users (id, email, aud, role) values
    (u_staff,  't-staff@example.test',  'authenticated', 'authenticated'),
    (u_ref_a,  't-ref-a@example.test',  'authenticated', 'authenticated'),
    (u_ref_b,  't-ref-b@example.test',  'authenticated', 'authenticated'),
    (u_client, 't-client@example.test', 'authenticated', 'authenticated'),
    (u_nobody, 't-nobody@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff'   where id = u_staff;
  update public.profiles set role = 'partner' where id in (u_ref_a, u_ref_b);

  insert into public.partners (zite_segnalatore_id, name, email, organization_id)
    values ('test-ref-a', 'Test referrer A', 't-ref-a@example.test', org) returning id into p_a;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id)
    values ('test-ref-b', 'Test referrer B', 't-ref-b@example.test', org) returning id into p_b;
  insert into public.partner_members (partner_id, profile_id) values (p_a, u_ref_a), (p_b, u_ref_b);

  insert into public.companies (name, zite_azienda_id, organization_id)
    values ('Test company', 'test-company', org) returning id into comp;
  insert into public.company_members (company_id, profile_id) values (comp, u_client);

  insert into public.conversations (kind, title, partner_id, created_by)
    values ('partner', 'A thread', p_a, u_staff) returning id into conv_a;
  insert into public.conversations (kind, title, partner_id, created_by)
    values ('partner', 'B thread', p_b, u_staff) returning id into conv_b;
  insert into public.conversations (kind, title, company_id, created_by)
    values ('client', 'Client thread', comp, u_staff) returning id into conv_c;

  insert into public.messages (conversation_id, sender_id, body, internal) values
    (conv_a, u_staff, 'to A', false),
    (conv_a, u_staff, 'internal note on A', true),
    (conv_b, u_staff, 'to B', false),
    (conv_c, u_staff, 'to client', false);

  ---------------------------------------------------------------- referrer A
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref_a, 'role', 'authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from public.conversations;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s A sees only own conversations (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  select count(*) into n from public.messages;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s A sees own non-internal messages only (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  select count(*) into n from public.messages where internal;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s A never sees internal notes (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  select count(*) into n from public.partners;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s A sees only own referrer record (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  select count(*) into n from public.profiles where id = u_ref_b;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s A cannot see B''s profile (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  select count(*) into n from public.companies;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s A sees no client companies (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  begin
    insert into public.messages (conversation_id, sender_id, body) values (conv_b, u_ref_a, 'intrusion');
    ok := false;
  exception when others then ok := true;
  end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s A cannot write in B''s conversation\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.conversation_members (conversation_id, profile_id, last_read_at) values (conv_b, u_ref_a, now());
    ok := false;
  exception when others then ok := true;
  end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s A cannot mark B''s conversation as read\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.conversations (kind, title, partner_id, created_by) values ('partner', 'fake', p_b, u_ref_a);
    ok := false;
  exception when others then ok := true;
  end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s A cannot create a conversation for B\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.messages (conversation_id, sender_id, body, internal) values (conv_a, u_ref_a, 'sneaky', true);
    ok := false;
  exception when others then ok := true;
  end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s A cannot post an internal note\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.messages (conversation_id, sender_id, body) values (conv_a, u_staff, 'impersonation');
    ok := false;
  exception when others then ok := true;
  end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s A cannot post as someone else\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    update public.messages set body = 'edited' where conversation_id = conv_a;
    ok := false;
  exception when others then ok := true;
  end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s A cannot edit messages\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    update public.profiles set role = 'staff' where id = u_ref_a;
    ok := false;
  exception when others then ok := true;
  end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s A cannot make themself staff\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.messages (conversation_id, sender_id, body) values (conv_a, u_ref_a, 'hello');
    insert into public.conversation_members (conversation_id, profile_id, last_read_at) values (conv_a, u_ref_a, now());
    ok := true;
  exception when others then ok := false;
  end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s A can write and mark read in own conversation\n', case when ok then 'PASS' else 'FAIL' end);

  -- Since 20261021140000 a referrer starts a conversation only through the bridge (the portal checks colleague and pratica).
  begin
    insert into public.conversations (kind, title, partner_id, created_by) values ('partner', 'A new thread', p_a, u_ref_a);
    ok := false;
  exception when others then ok := true;
  end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s A cannot start a conversation from a browser, even in own scope (bridge only)\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  ---------------------------------------------------------------- user with no memberships
  perform set_config('request.jwt.claims', json_build_object('sub', u_nobody, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select (select count(*) from public.conversations) + (select count(*) from public.messages)
       + (select count(*) from public.partners) + (select count(*) from public.companies)
       + (select count(*) from public.documents) + (select count(*) from public.notifications)
       + (select count(*) from public.comments) into n;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s user without memberships sees nothing (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  reset role;

  ---------------------------------------------------------------- client
  perform set_config('request.jwt.claims', json_build_object('sub', u_client, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.conversations;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s client sees only own company conversation (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  -- send limit: 20 per minute, the 21st is refused with P0429
  begin
    for i in 1..20 loop
      insert into public.messages (conversation_id, sender_id, body) values (conv_c, u_client, 'msg ' || i);
    end loop;
    ok := true;
  exception when others then ok := false;
  end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s client can send 20 messages in a minute\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.messages (conversation_id, sender_id, body) values (conv_c, u_client, 'msg 21');
    ok := false;
  exception when sqlstate 'P0429' then ok := true;
           when others then ok := false;
  end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s the 21st message is refused with P0429\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  ---------------------------------------------------------------- staff
  perform set_config('request.jwt.claims', json_build_object('sub', u_staff, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.conversations where id in (conv_a, conv_b, conv_c);
  ok := n = 3; failures := failures + (not ok)::int;
  report := report || format(E'%s staff see all conversations (expect 3, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  select count(*) into n from public.messages where internal and conversation_id = conv_a;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s staff see internal notes (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  begin
    update public.messages set deleted_at = now() where conversation_id = conv_b;
    ok := true;
  exception when others then ok := false;
  end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff can hide a message\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
