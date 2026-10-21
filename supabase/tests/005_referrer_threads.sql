-- Referrer threads (migration 20261021133651). Same pattern as 001-004: one DO block, everything rolled back by the final
-- RAISE; the message is the report. What the bridge does with full rights (start_partner_conversation) is mirrored as
-- plain inserts by the owner.

do $$
declare
  org      uuid := (select id from public.organizations limit 1);
  u_s1     uuid := gen_random_uuid();  -- colleague chosen by the referrer
  u_s2     uuid := gen_random_uuid();  -- colleague who joins by writing
  u_s3     uuid := gen_random_uuid();  -- colleague never involved
  u_old    uuid := gen_random_uuid();  -- leaves the team
  u_ref    uuid := gen_random_uuid();  -- referrer
  u_ref2   uuid := gen_random_uuid();  -- another referrer
  u_nobody uuid := gen_random_uuid();
  p_ref    uuid;
  p_ref2   uuid;
  conv     uuid;
  conv2    uuid;
  conv_old uuid;
  m_imp    uuid;
  n        int;
  i        int;
  r        record;
  report   text := '';
  failures int := 0;
  ok       boolean;
begin
  insert into auth.users (id, email, aud, role) values
    (u_s1,     't5-s1@example.test',     'authenticated', 'authenticated'),
    (u_s2,     't5-s2@example.test',     'authenticated', 'authenticated'),
    (u_s3,     't5-s3@example.test',     'authenticated', 'authenticated'),
    (u_old,    't5-old@example.test',    'authenticated', 'authenticated'),
    (u_ref,    't5-ref@example.test',    'authenticated', 'authenticated'),
    (u_ref2,   't5-ref2@example.test',   'authenticated', 'authenticated'),
    (u_nobody, 't5-nobody@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'manager', name_first = 'Uno', name_last = 'Test' where id = u_s1;
  update public.profiles set role = 'staff', staff_role = 'manager', name_first = 'Due', name_last = 'Test' where id = u_s2;
  update public.profiles set role = 'staff', staff_role = 'manager', name_first = 'Tre', name_last = 'Test' where id = u_s3;
  update public.profiles set role = 'staff', staff_role = 'manager', name_first = 'Vecchio', name_last = 'Test' where id = u_old;
  update public.profiles set role = 'partner' where id in (u_ref, u_ref2);
  insert into public.partners (zite_segnalatore_id, name, email, organization_id)
    values ('t5-ref', 'Test referrer 5', 't5-ref@example.test', org) returning id into p_ref;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id)
    values ('t5-ref2', 'Test referrer 5b', 't5-ref2@example.test', org) returning id into p_ref2;
  insert into public.partner_members (partner_id, profile_id) values (p_ref, u_ref), (p_ref2, u_ref2);

  ---------------------------------------------------------------- a referrer cannot start a conversation from a browser
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    insert into public.conversations (kind, title, partner_id, created_by) values ('partner', 'Direct', p_ref, u_ref);
    ok := false;
  exception when others then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a referrer cannot create a conversation directly\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  ---------------------------------------------------------------- start, as the bridge does (chosen colleague = s1)
  insert into public.conversations (kind, title, partner_id, created_by, zite_pratica_id)
    values ('partner', 'Domanda sul bando', p_ref, u_ref, 'zite-pr-1') returning id into conv;
  insert into public.conversation_members (conversation_id, profile_id) values (conv, u_s1);
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.messages (conversation_id, sender_id, body) values (conv, u_ref, 'prima domanda');
  reset role;

  select count(*) into n from public.notifications where conversation_id = conv and recipient_id = u_s1 and link = 'segnalatore:t5-ref';
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s the chosen colleague is notified, with the segnalatore link (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.notifications where conversation_id = conv and recipient_id in (u_s2, u_s3, u_old);
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s nobody else of the team is notified (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  -- one conversation per referrer and subject, whatever the case; another referrer may reuse it
  begin
    insert into public.conversations (kind, title, partner_id, created_by) values ('partner', 'DOMANDA SUL BANDO', p_ref, u_ref);
    ok := false;
  exception when unique_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s one conversation per referrer and subject\n', case when ok then 'PASS' else 'FAIL' end);
  begin
    insert into public.conversations (kind, title, partner_id, created_by) values ('partner', 'Domanda sul bando', p_ref2, u_ref2) returning id into conv2;
    ok := true;
  exception when others then ok := false; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s another referrer may use the same subject\n', case when ok then 'PASS' else 'FAIL' end);

  ---------------------------------------------------------------- the team side
  perform set_config('request.jwt.claims', json_build_object('sub', u_s3, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select t.unread, t.taking_part into r from public.partner_threads(p_ref) t where t.id = conv;
  ok := r.unread = 1 and not r.taking_part; failures := failures + (not ok)::int;
  report := report || format(E'%s a colleague not taking part: unread for Gemina, not his thread (unread %s, taking part %s)\n', case when ok then 'PASS' else 'FAIL' end, r.unread, r.taking_part);
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select t.unread, t.taking_part into r from public.partner_threads() t where t.id = conv;
  ok := r.unread = 1 and r.taking_part; failures := failures + (not ok)::int;
  report := report || format(E'%s the chosen colleague: 1 unread, his thread (unread %s, taking part %s)\n', case when ok then 'PASS' else 'FAIL' end, r.unread, r.taking_part);
  reset role;

  -- s3 only reads it: read for the whole team (anyone), the colleagues' bell entries too; s3 does not start taking part
  perform set_config('request.jwt.claims', json_build_object('sub', u_s3, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.mark_conversation_read(conv);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select t.unread into n from public.partner_threads() t where t.id = conv;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s read by one colleague = read for the team (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  reset role;
  select count(*) into n from public.notifications where conversation_id = conv and recipient_id = u_s1 and read_at is null;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s the chosen colleague''s bell entry is read too (expect 0 unread, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.conversation_members where conversation_id = conv and profile_id = u_s3;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s reading does not make a colleague take part (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  -- s2 replies: joins; the referrer is notified with the portal link
  perform set_config('request.jwt.claims', json_build_object('sub', u_s2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.messages (conversation_id, sender_id, body) values (conv, u_s2, 'risposta di Due');
  reset role;
  select count(*) into n from public.notifications where conversation_id = conv and recipient_id = u_ref and link = 'messaggi';
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s the referrer is notified of the reply, portal link (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.conversation_members where conversation_id = conv and profile_id = u_s2;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s the colleague who wrote now takes part (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.notifications where conversation_id = conv and recipient_id = u_s1 and actor_id = u_s2;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s the colleague already taking part sees the other''s reply in the bell (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  -- an internal note: never reaches or counts for the referrer
  perform set_config('request.jwt.claims', json_build_object('sub', u_s2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.messages (conversation_id, sender_id, body, internal) values (conv, u_s2, 'nota interna', true);
  reset role;

  ---------------------------------------------------------------- the referrer side
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.partner_threads();
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s the referrer sees only own threads (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.partner_threads(p_ref2);
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s asking for another referrer returns nothing (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  select t.unread, t.last_from_gemina, array_to_string(array(select x from unnest(t.colleagues) x order by x), ', ') as nomi
    into r from public.partner_threads() t where t.id = conv;
  ok := r.unread = 1 and r.last_from_gemina and r.nomi = 'Due Test, Uno Test'; failures := failures + (not ok)::int;
  report := report || format(E'%s the referrer: 1 unread (the internal note does not count), colleagues listed (unread %s, last from Gemina %s, %s)\n', case when ok then 'PASS' else 'FAIL' end, r.unread, r.last_from_gemina, r.nomi);
  select count(*) into n from public.notifications;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s the referrer has one bell entry, none for the internal note (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  perform public.mark_conversation_read(conv);
  select t.unread into n from public.partner_threads() t where t.id = conv;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s the referrer marks it read (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.notifications where read_at is null;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s ... and the bell entry with it (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  begin
    perform public.mark_conversation_read(conv2);
    ok := false;
  exception when others then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s the referrer cannot mark another referrer''s conversation\n', case when ok then 'PASS' else 'FAIL' end);
  select count(*) into n from public.staff_colleagues() where id in (u_s1, u_s2, u_s3, u_old);
  ok := n = 4; failures := failures + (not ok)::int;
  report := report || format(E'%s the referrer sees the team''s names for the picker (expect 4 test colleagues, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  -- a browser cannot choose a message's time or Zite id
  insert into public.messages (conversation_id, sender_id, body, created_at, zite_messaggio_id)
    values (conv, u_ref, 'dal futuro', now() + interval '30 days', 'zite-rubato');
  reset role;
  select count(*) into n from public.messages
   where conversation_id = conv and body = 'dal futuro' and created_at < now() + interval '1 minute' and zite_messaggio_id is null;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s a browser cannot set a message''s time or Zite id (expect 1 corrected, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  -- the referrer replies: both colleagues taking part are notified, nobody else
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.messages (conversation_id, sender_id, body) values (conv, u_ref, 'grazie');
  reset role;
  select count(*) into n from public.notifications n2
   where n2.conversation_id = conv and n2.actor_id = u_ref and n2.message_id = (select id from public.messages where conversation_id = conv and body = 'grazie');
  select count(*) into i from public.notifications n2
   where n2.conversation_id = conv and n2.actor_id = u_ref and n2.recipient_id in (u_s1, u_s2)
     and n2.message_id = (select id from public.messages where conversation_id = conv and body = 'grazie');
  ok := n = 2 and i = 2; failures := failures + (not ok)::int;
  report := report || format(E'%s the referrer''s reply reaches the two colleagues taking part, nobody else (expect 2/2, got %s/%s)\n', case when ok then 'PASS' else 'FAIL' end, i, n);

  ---------------------------------------------------------------- nobody of the team left: every current staff member
  insert into public.conversations (kind, title, partner_id, created_by) values ('partner', 'Con chi se ne va', p_ref, u_ref) returning id into conv_old;
  insert into public.conversation_members (conversation_id, profile_id) values (conv_old, u_old);
  update public.profiles set role = 'former_staff', staff_role = null, organization_id = null where id = u_old;
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.messages (conversation_id, sender_id, body) values (conv_old, u_ref, 'c''è qualcuno?');
  reset role;
  select count(*) into i from public.profiles where role = 'staff' and organization_id = org;  -- includes real dev staff
  select count(*) into n from public.notifications where conversation_id = conv_old;
  ok := n = i; failures := failures + (not ok)::int;
  report := report || format(E'%s colleague gone: every current staff member is notified (expect %s, got %s)\n', case when ok then 'PASS' else 'FAIL' end, i, n);
  select count(*) into n from public.notifications where conversation_id = conv_old and recipient_id = u_old;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s ... but not the person who left (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  ---------------------------------------------------------------- privacy and helpers
  perform set_config('request.jwt.claims', json_build_object('sub', u_nobody, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select (select count(*) from public.partner_threads()) + (select count(*) from public.staff_colleagues()) into n;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s someone with no role sees no threads and no names (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  begin
    perform private.request_message_emails('sweep', null);
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a browser cannot ask for emails\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  ---------------------------------------------------------------- history import: takes part, no notification
  perform set_config('request.jwt.claims', '{}', true);  -- no logged-in user, as in the import script
  perform set_config('gemina.import', 'on', true);
  insert into public.messages (conversation_id, sender_id, body, created_at, zite_messaggio_id)
    values (conv2, u_s3, 'dal passato', now() - interval '7 days', 'zite-msg-t5') returning id into m_imp;
  select count(*) into n from public.messages where id = m_imp and created_at < now() - interval '6 days' and zite_messaggio_id = 'zite-msg-t5';
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s an imported message keeps its original time and Zite id (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.notifications where message_id = m_imp;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s an imported message notifies nobody (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.conversation_members where conversation_id = conv2 and profile_id = u_s3;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s ... but its Gemina author takes part (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  begin
    insert into public.messages (conversation_id, sender_id, body, zite_messaggio_id) values (conv2, u_s3, 'di nuovo', 'zite-msg-t5');
    ok := false;
  exception when unique_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s the same Zite message cannot be copied twice\n', case when ok then 'PASS' else 'FAIL' end);
  perform set_config('gemina.import', '', true);

  -- the import mode is ignored for a logged-in user
  perform set_config('request.jwt.claims', json_build_object('sub', u_s3, 'role', 'authenticated')::text, true);
  perform set_config('gemina.import', 'on', true);
  set local role authenticated;
  insert into public.messages (conversation_id, sender_id, body) values (conv2, u_s3, 'non è un import');
  reset role;
  perform set_config('gemina.import', '', true);
  select count(*) into n from public.notifications where conversation_id = conv2 and actor_id = u_s3;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s a logged-in user cannot switch notifications off (expect 1 for the referrer, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
