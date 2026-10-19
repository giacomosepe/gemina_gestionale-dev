-- Notifications and comments test. Same pattern as 001: one DO block, everything
-- rolled back by the final RAISE; the error message is the report.

do $$
declare
  org      uuid := (select id from public.organizations limit 1);
  u_s1     uuid := gen_random_uuid();  -- staff 1
  u_s2     uuid := gen_random_uuid();  -- staff 2
  u_s3     uuid := gen_random_uuid();  -- staff 3 (never takes part)
  u_ref    uuid := gen_random_uuid();  -- referrer
  u_ref2   uuid := gen_random_uuid();  -- other referrer
  p_ref    uuid;
  p_ref2   uuid;
  conv     uuid;
  c_top    uuid;
  c_reply  uuid;
  n        int;
  i        int;
  report   text := '';
  failures int := 0;
  ok       boolean;
begin
  insert into auth.users (id, email, aud, role) values
    (u_s1,   't-s1@example.test',   'authenticated', 'authenticated'),
    (u_s2,   't-s2@example.test',   'authenticated', 'authenticated'),
    (u_s3,   't-s3@example.test',   'authenticated', 'authenticated'),
    (u_ref,  't-ref@example.test',  'authenticated', 'authenticated'),
    (u_ref2, 't-ref2@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff' where id in (u_s1, u_s2, u_s3);
  update public.profiles set role = 'partner' where id in (u_ref, u_ref2);
  insert into public.partners (zite_segnalatore_id, name, email, organization_id)
    values ('test-ref', 'Test referrer', 't-ref@example.test', org) returning id into p_ref;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id)
    values ('test-ref2', 'Test referrer 2', 't-ref2@example.test', org) returning id into p_ref2;
  insert into public.partner_members (partner_id, profile_id) values (p_ref, u_ref), (p_ref2, u_ref2);
  insert into public.conversations (kind, title, partner_id, created_by)
    values ('partner', 'Referrer thread', p_ref, u_s1) returning id into conv;

  ---------------------------------------------------------------- messages -> notifications
  -- Referrer writes first: no staff has taken part yet, so ALL staff are notified.
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.messages (conversation_id, sender_id, body) values (conv, u_ref, 'first message');
  reset role;
  select count(*) into i from public.profiles where role = 'staff' and organization_id = org;  -- includes real dev staff
  select count(*) into n from public.notifications where conversation_id = conv and kind = 'message';
  ok := n = i; failures := failures + (not ok)::int;
  report := report || format(E'%s first referrer message notifies every staff member (expect %s, got %s)\n', case when ok then 'PASS' else 'FAIL' end, i, n);

  -- Staff 1 replies (becomes a participant): the referrer is notified, other staff are not.
  insert into public.conversation_members (conversation_id, profile_id, last_read_at) values (conv, u_s1, now());
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.messages (conversation_id, sender_id, body) values (conv, u_s1, 'reply from staff');
  reset role;
  select count(*) into n from public.notifications where conversation_id = conv and recipient_id = u_ref;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s staff reply notifies the referrer (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.notifications where conversation_id = conv and recipient_id = u_s1;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s the sender is not notified of own message (staff 1 total 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  -- Referrer writes again: now only the participating staff (staff 1) is notified.
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.messages (conversation_id, sender_id, body) values (conv, u_ref, 'second message');
  reset role;
  select count(*) into n from public.notifications where conversation_id = conv and recipient_id in (u_s2, u_s3);
  ok := n = 2; failures := failures + (not ok)::int;
  report := report || format(E'%s later messages go only to participating staff (staff 2+3 stay at 2, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  -- Internal note: referrer is never notified.
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.messages (conversation_id, sender_id, body, internal) values (conv, u_s1, 'internal note', true);
  reset role;
  select count(*) into n from public.notifications where conversation_id = conv and recipient_id = u_ref;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s internal notes never notify the referrer (still 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  ---------------------------------------------------------------- notifications access
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.notifications;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s referrer sees only own notifications (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.notifications where label is not null and label = 'Referrer thread';
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s notification carries the label, not the message text\n', case when ok then 'PASS' else 'FAIL' end);
  begin update public.notifications set read_at = now() where recipient_id = u_ref; ok := true;
  exception when others then ok := false; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s referrer can mark own notification read\n', case when ok then 'PASS' else 'FAIL' end);
  begin update public.notifications set label = 'tampered' where recipient_id = u_ref; ok := false;
  exception when others then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s referrer cannot change anything else on a notification\n', case when ok then 'PASS' else 'FAIL' end);
  begin
    insert into public.notifications (organization_id, recipient_id, kind) values (org, u_s1, 'message');
    ok := false;
  exception when others then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s nobody can create a notification by hand\n', case when ok then 'PASS' else 'FAIL' end);
  begin delete from public.notifications; ok := false;
  exception when others then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s nobody can delete notifications\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  ---------------------------------------------------------------- comments
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.comments (record_type, record_zite_id, record_label, body, mentions)
    values ('pratica', 'zite-pratica-1', 'PR-2026-001 Test', 'please check @s2', array[u_s2, u_ref])
    returning id into c_top;
  reset role;

  select count(*) into n from public.notifications where comment_id = c_top and recipient_id = u_s2 and kind = 'mention';
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s @mention notifies the staff member (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.notifications where comment_id = c_top and recipient_id = u_ref;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s mentioning a referrer is ignored (comments are internal) (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  perform set_config('request.jwt.claims', json_build_object('sub', u_s2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.comments (record_type, record_zite_id, parent_id, body)
    values ('pratica', 'zite-pratica-1', c_top, 'done') returning id into c_reply;
  begin
    insert into public.comments (record_type, record_zite_id, parent_id, body)
      values ('pratica', 'zite-pratica-1', c_reply, 'reply to a reply');
    ok := false;
  exception when others then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s replies are one level only\n', case when ok then 'PASS' else 'FAIL' end);
  begin update public.comments set body = 'edited by someone else' where id = c_top; get diagnostics n = row_count; ok := n = 0;
  exception when others then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff cannot edit someone else''s comment\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  select count(*) into n from public.notifications where comment_id = c_reply and recipient_id = u_s1 and kind = 'comment_reply';
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s a reply notifies the original author (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.comments set body = 'please check, thanks' where id = c_top;
  select count(*) into n from public.comments where id = c_top and edited_at is not null;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s author can edit own comment, marked as edited\n', case when ok then 'PASS' else 'FAIL' end);
  select count(*) into n from public.comments where record_zite_id = 'zite-pratica-1';
  ok := n = 2; failures := failures + (not ok)::int;
  report := report || format(E'%s staff read all comments on the record (expect 2, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  begin
    for i in 1..19 loop
      insert into public.comments (record_type, record_zite_id, body) values ('azienda', 'zite-az-1', 'c ' || i);
    end loop;
    insert into public.comments (record_type, record_zite_id, body) values ('azienda', 'zite-az-1', 'one too many');
    ok := false;
  exception when sqlstate 'P0429' then ok := true; when others then ok := false; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s comment send limit fires (P0429)\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.comments;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s referrers never see comments (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  begin
    insert into public.comments (record_type, record_zite_id, body) values ('pratica', 'zite-pratica-1', 'from referrer');
    ok := false;
  exception when others then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s referrers cannot write comments\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', u_ref2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.notifications;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s another referrer sees none of these notifications (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  reset role;

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
