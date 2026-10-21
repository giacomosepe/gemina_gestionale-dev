-- Automatic messages from Gemina Advisory and the "Notifica segnalatore" repeat guard (migration 20261021155543). Same pattern
-- as 001-006: one DO block, everything rolled back by the final RAISE; the message is the report. The bridge's insert is
-- mirrored as a plain insert (full rights). Email requests are counted in pg_net's queue (nothing is sent: the queue is only
-- read after commit, and this block never commits); a placeholder functions_url is stored for the test if none exists.

do $$
declare
  org      uuid := (select id from public.organizations limit 1);
  u_s1     uuid := gen_random_uuid();
  u_ref    uuid := gen_random_uuid();
  p_ref    uuid;
  conv     uuid;
  m_auto   uuid;
  d_doc    uuid;
  n        int;
  i        int;
  q0       int;
  r        record;
  report   text := '';
  failures int := 0;
  ok       boolean;
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'functions_url') then
    perform vault.create_secret('https://example.invalid/functions/v1', 'functions_url');
  end if;
  insert into auth.users (id, email, aud, role) values
    (u_s1,  't-s1@example.test',  'authenticated', 'authenticated'),
    (u_ref, 't-ref@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'manager' where id = u_s1;
  update public.profiles set role = 'partner' where id = u_ref;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id)
    values ('test-ref', 'Test referrer', 't-ref@example.test', org) returning id into p_ref;
  insert into public.partner_members (partner_id, profile_id) values (p_ref, u_ref);
  insert into public.conversations (kind, title, partner_id, created_by)
    values ('partner', 'Provvigione maturata: PR-1', p_ref, null) returning id into conv;

  -- the segnalatore asks something first: it must stay unread for the team after the automatic message
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.messages (conversation_id, sender_id, body) values (conv, u_ref, 'quando posso fatturare?');
  reset role;
  perform set_config('request.jwt.claims', '', true);

  ---------------------------------------------------------------- the bridge writes an automatic message (full rights)
  select count(*) into q0 from net.http_request_queue;
  insert into public.messages (conversation_id, sender_id, body, automatic)
    values (conv, null, 'La provvigione è maturata.', true) returning id into m_auto;

  select count(*) into n from public.messages where id = m_auto and automatic;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s the server can write an automatic message (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  select count(*) into n from public.notifications where message_id = m_auto and recipient_id = u_ref;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s the segnalatore gets the bell (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  select count(*) into n from public.notifications where message_id = m_auto and recipient_id <> u_ref;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s nobody of the team is notified (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  select count(*) - q0 into n from net.http_request_queue;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s no email is requested (expect 0 new requests, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  select count(*) into n from public.conversation_members where conversation_id = conv;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s nobody takes part because of it (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  begin
    insert into public.messages (conversation_id, sender_id, body, automatic) values (conv, u_s1, 'signed', true);
    ok := false;
  exception when check_violation then ok := true; when others then ok := false; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s an automatic message has no sender\n', case when ok then 'PASS' else 'FAIL' end);

  ---------------------------------------------------------------- what each side sees
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select * into r from public.partner_threads(p_ref) where id = conv;
  ok := coalesce(r.unread = 1 and r.last_from_gemina, false); failures := failures + (not ok)::int;
  report := report || format(E'%s staff: the question stays unread, the automatic one is from Gemina (unread %s, from_gemina %s)\n', case when ok then 'PASS' else 'FAIL' end, r.unread, r.last_from_gemina);
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select * into r from public.partner_threads() where id = conv;
  ok := coalesce(r.unread = 1 and r.last_from_gemina, false); failures := failures + (not ok)::int;
  report := report || format(E'%s segnalatore: the automatic message is unread and from Gemina (unread %s, from_gemina %s)\n', case when ok then 'PASS' else 'FAIL' end, r.unread, r.last_from_gemina);
  reset role;

  -- a browser (staff) asking for automatic gets a plain message
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.messages (conversation_id, sender_id, body, automatic) values (conv, u_s1, 'from a browser', true);
  select count(*) into n from public.messages where conversation_id = conv and body = 'from a browser' and not automatic;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s a browser insert is never automatic (expect 1 plain, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  reset role;

  ---------------------------------------------------------------- import mode: no bell, original time kept
  perform set_config('request.jwt.claims', '', true);
  perform set_config('gemina.import', 'on', true);
  insert into public.messages (conversation_id, sender_id, body, automatic, created_at)
    values (conv, null, 'storico', true, '2026-01-01T10:00:00Z') returning id into m_auto;
  perform set_config('gemina.import', 'off', true);
  select count(*) into n from public.notifications where message_id = m_auto;
  select count(*) into i from public.messages where id = m_auto and created_at = '2026-01-01T10:00:00Z' and automatic;
  ok := n = 0 and i = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s history import: no bell, original time kept (bells %s, kept %s)\n', case when ok then 'PASS' else 'FAIL' end, n, i);

  ---------------------------------------------------------------- "Notifica segnalatore" pressed twice
  insert into public.documents (kind, partner_id, title, link_url, uploaded_by, from_gemina, uploaded_at)
    values ('partner', p_ref, 'Presentazione', 'https://example.com/doc', u_s1, true, now()) returning id into d_doc;
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into q0 from net.http_request_queue;
  perform public.notify_document(d_doc);
  perform public.notify_document(d_doc);
  reset role;
  select count(*) into n from public.notifications where document_id = d_doc and recipient_id = u_ref;
  select count(*) - q0 into i from net.http_request_queue;
  ok := n = 1 and i = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s a second press within a minute does nothing (bells %s, email requests %s)\n', case when ok then 'PASS' else 'FAIL' end, n, i);

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
