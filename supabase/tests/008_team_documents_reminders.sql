-- Team documents (kind 'team') and date reminders (migrations 20261021221703 and 20261021221829). Same pattern as 001-007: one
-- DO block, everything rolled back by the final RAISE; the message is the report. Email requests are only queued in pg_net
-- (never sent: this block never commits); a placeholder functions_url is stored if none exists.

do $$
declare
  org      uuid := (select id from public.organizations limit 1);
  u_s1     uuid := gen_random_uuid();
  u_s2     uuid := gen_random_uuid();
  u_ref    uuid := gen_random_uuid();
  p_ref    uuid;
  d_team   uuid;
  path     text;
  rem      uuid;
  rem2     uuid;
  n        int;
  q0       int;
  r        record;
  today    date := (now() at time zone 'Europe/Rome')::date;
  report   text := '';
  failures int := 0;
  ok       boolean;
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'functions_url') then
    perform vault.create_secret('https://example.invalid/functions/v1', 'functions_url');
  end if;
  insert into auth.users (id, email, aud, role) values
    (u_s1,  't8-s1@example.test',  'authenticated', 'authenticated'),
    (u_s2,  't8-s2@example.test',  'authenticated', 'authenticated'),
    (u_ref, 't8-ref@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't8-zite-s1' where id = u_s1;
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't8-zite-s2' where id = u_s2;
  update public.profiles set role = 'partner' where id = u_ref;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id)
    values ('t8-ref', 'Test referrer 8', 't8-ref@example.test', org) returning id into p_ref;
  insert into public.partner_members (partner_id, profile_id) values (p_ref, u_ref);

  ---------------------------------------------------------------- team documents
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.documents (kind, title, mime_type, zite_azienda_id, zite_pratica_id, zite_attivita_id, shared)
    values ('team', 'Visura camerale.pdf', 'application/pdf', 't8-azienda', 't8-pratica', 't8-azione', true)
    returning id, storage_path into d_team, path;
  reset role;
  select * into r from public.documents where id = d_team;
  ok := path = 'team/t8-azienda/' || d_team || '/Visura_camerale.pdf';
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff add a team document; the server makes the path (got %s)\n', case when ok then 'PASS' else 'FAIL' end, path);
  ok := not r.shared and r.organization_id = private.default_organization_id() and r.zite_attivita_id = 't8-azione';
  failures := failures + (not ok)::int;
  report := report || format(E'%s a team document is never shared, takes the organization and keeps the azione\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.documents (kind, title, zite_pratica_id) values ('team', 'senza azienda.pdf', 't8-pratica');
    ok := false;
  exception when check_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a team document needs an azienda (since 20261022150000)\n', case when ok then 'PASS' else 'FAIL' end);

  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    update public.documents set shared = true where id = d_team;
  exception when check_violation then null; end;
  reset role;
  select shared into r from public.documents where id = d_team;
  ok := not r.shared; failures := failures + (not ok)::int;
  report := report || format(E'%s staff cannot share a team document\n', case when ok then 'PASS' else 'FAIL' end);

  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.documents where id = d_team;
  reset role;
  ok := n = 0 and not exists (select 1 from public.partner_documents() where id = d_team);
  failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalatore cannot see a team document (got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    insert into public.documents (kind, title, zite_pratica_id) values ('team', 'intruso.pdf', 't8-pratica');  -- refused for a segnalatore whatever the scope
    ok := false;
  exception when others then ok := true; end;
  ok := ok and not private.can_access_document_path(path);
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalatore cannot add a team document nor read its file\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.documents (kind, title, zite_azienda_id, zite_pratica_id, conversation_id)
      select 'team', 'in conversazione.pdf', 't8-azienda', 't8-pratica', id from public.conversations limit 1;
    ok := not found;
  exception when check_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a team document cannot sit in a conversation\n', case when ok then 'PASS' else 'FAIL' end);

  ---------------------------------------------------------------- reminders: who may write
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    insert into public.reminders (zite_pratica_id, date_key, label, due_date, days_before, recipients)
      values ('t8-pratica', 'scadenza', 'Scadenza', today + 7, array[7], array['t8-zite-s1']);
    ok := false;
  exception when others then ok := true; end;
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalatore cannot write a reminder\n', case when ok then 'PASS' else 'FAIL' end);

  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.reminders (zite_pratica_id, date_key, label, pratica_title, due_date, days_before, recipients)
    values ('t8-pratica', 'scadenza', 'Invio domanda', 'Pratica di prova', today + 7, array[1, 7, 7], array['t8-zite-s1', 't8-zite-s2', 't8-zite-s1'])
    returning id into rem;
  insert into public.reminders (zite_pratica_id, date_key, label, due_date, days_before, recipients)
    values ('t8-pratica', 'kickoff', 'Kick-off', today + 3, array[7], array['t8-zite-s1']) returning id into rem2;
  begin
    insert into public.reminders (zite_pratica_id, date_key, label, due_date, days_before, recipients)
      values ('t8-pratica', 'scadenza', 'doppio', today, array[0], array['t8-zite-s1']);
    ok := false;
  exception when unique_violation then ok := true; end;
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s one reminder per pratica and date\n', case when ok then 'PASS' else 'FAIL' end);
  select * into r from public.reminders where id = rem;
  ok := r.days_before = array[7, 1]::smallint[] and r.recipients = array['t8-zite-s1', 't8-zite-s2'] and r.created_by = u_s1;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff write a reminder; days and people cleaned, author set (%s / %s)\n', case when ok then 'PASS' else 'FAIL' end, r.days_before, r.recipients);

  begin
    insert into public.reminders (zite_pratica_id, date_key, label, due_date, days_before, recipients)
      values ('t8-pratica', 'x', 'Troppo lontano', today, array[120], array['t8-zite-s1']);
    ok := false;
  exception when check_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s days before are 0 to 90\n', case when ok then 'PASS' else 'FAIL' end);

  ---------------------------------------------------------------- the morning job
  select count(*) into q0 from net.http_request_queue;
  perform private.send_due_reminders(true);
  select count(*) into n from public.notifications where recipient_id in (u_s1, u_s2) and event = 'promemoria';
  ok := n = 2; failures := failures + (not ok)::int;
  report := report || format(E'%s 7 days before: a bell for each recipient, none for a reminder not due (expect 2, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.notifications where recipient_id = u_s1 and event = 'promemoria' and link = 'pratica:t8-pratica'
     and label like 'Promemoria: Invio domanda tra 7 giorni%Pratica di prova';
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s the bell says what, when and which pratica, and opens the pratica (got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  select count(*) - q0 into n from net.http_request_queue;
  ok := n = 1 or not exists (select 1 from vault.decrypted_secrets where name = 'message_emails_secret'); failures := failures + (not ok)::int;
  report := report || format(E'%s one email request for the run (got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  perform private.send_due_reminders(true);
  select count(*) into n from public.notifications where recipient_id in (u_s1, u_s2) and event = 'promemoria';
  n := n - 2;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s a second run the same day sends nothing (got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  n := private.send_due_reminders(false);
  ok := n = 0 or extract(hour from now() at time zone 'Europe/Rome') >= 8; failures := failures + (not ok)::int;
  report := report || format(E'%s before 8 in Rome the hourly job does nothing\n', case when ok then 'PASS' else 'FAIL' end);

  update public.reminders set due_date = today + 1 where id = rem;
  perform private.send_due_reminders(true);
  select count(*) - 2 into n from public.notifications where recipient_id in (u_s1, u_s2) and event = 'promemoria';
  ok := n = 2; failures := failures + (not ok)::int;
  report := report || format(E'%s a changed date re-arms the reminder (1 day before: expect 2, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  update public.reminders set due_date = today + 7, closed = true where id = rem;
  delete from public.reminder_sends where reminder_id = rem;
  perform private.send_due_reminders(true);
  select count(*) - 4 into n from public.notifications where recipient_id in (u_s1, u_s2) and event = 'promemoria';
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s a closed pratica gets no reminders (got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  update public.reminders set closed = false, due_date = today - 1, days_before = array[0] where id = rem;
  perform private.send_due_reminders(true);
  select count(*) - 4 into n from public.notifications where recipient_id in (u_s1, u_s2) and event = 'promemoria';
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s a past date sends nothing (got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.reminders;
  reset role;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalatore sees no reminders (got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
