-- Team documents with the azienda as home, lifespan, bucket size, reminders of a trattativa (migration 20261022145359).
-- Same pattern as 001-008: one DO block, everything rolled back by the final RAISE; the message is the report. The morning job
-- is not run here (it queues an email request, which the connector refuses); the bell link is checked on the function text.

do $$
declare
  org      uuid := (select id from public.organizations limit 1);
  u_s1     uuid := gen_random_uuid();
  u_ref    uuid := gen_random_uuid();
  p_ref    uuid;
  d1       uuid;
  d2       uuid;
  path     text;
  n        int;
  r        record;
  today    date := (now() at time zone 'Europe/Rome')::date;
  report   text := '';
  failures int := 0;
  ok       boolean;
begin
  insert into auth.users (id, email, aud, role) values
    (u_s1,  't9-s1@example.test',  'authenticated', 'authenticated'),
    (u_ref, 't9-ref@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't9-zite-s1' where id = u_s1;
  update public.profiles set role = 'partner' where id = u_ref;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id)
    values ('t9-ref', 'Test referrer 9', 't9-ref@example.test', org) returning id into p_ref;
  insert into public.partner_members (partner_id, profile_id) values (p_ref, u_ref);

  ---------------------------------------------------------------- the azienda is the home
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.documents (kind, title, mime_type, zite_azienda_id, zite_trattativa_id, category)
    values ('team', 'Bilancio 2025.pdf', 'application/pdf', 't9-azienda', 't9-trattativa', 'Bilancio 2025')
    returning id, storage_path into d1, path;
  reset role;
  select * into r from public.documents where id = d1;
  ok := path = 'team/t9-azienda/' || d1 || '/Bilancio_2025.pdf' and r.lifespan = 'company' and r.category = 'Bilancio 2025'
        and r.zite_trattativa_id = 't9-trattativa' and r.zite_pratica_id is null and not r.shared;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff add a bilancio from a trattativa: azienda path, lifespan company by default (got %s)\n', case when ok then 'PASS' else 'FAIL' end, path);

  begin
    insert into public.documents (kind, title, zite_trattativa_id) values ('team', 'senza azienda.pdf', 't9-trattativa');
    ok := false;
  exception when check_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a team document without an azienda is refused\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.documents (kind, title, zite_azienda_id, lifespan) values ('team', 'progetto di chi.pdf', 't9-azienda', 'project');
    ok := false;
  exception when check_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a project document must say which trattativa or pratica\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.documents (kind, title, zite_azienda_id, lifespan) values ('team', 'x.pdf', 't9-azienda', 'forever');
    ok := false;
  exception when check_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s lifespan is company or project only\n', case when ok then 'PASS' else 'FAIL' end);

  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.documents (kind, title, zite_azienda_id, zite_pratica_id, lifespan)
    values ('team', 'Fattura di progetto.pdf', 't9-azienda', 't9-pratica', 'project') returning id into d2;
  -- at acquisition the trattativa's document also gets the pratica (one column, not a copy); the lifespan can change
  update public.documents set zite_pratica_id = 't9-pratica', lifespan = 'project' where id = d1;
  reset role;
  select * into r from public.documents where id = d1;
  ok := d2 is not null and r.zite_pratica_id = 't9-pratica' and r.lifespan = 'project' and r.storage_path = path;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff add a project document; a document can get its pratica and change lifespan, path unchanged\n', case when ok then 'PASS' else 'FAIL' end);

  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    insert into public.documents (kind, title, zite_azienda_id, version_of) values ('team', 'altra.pdf', 't9-altra', d1);
    ok := false;
  exception when check_violation then ok := true; end;
  insert into public.documents (kind, title, zite_azienda_id, version_of) values ('team', 'Bilancio 2025 v2.pdf', 't9-azienda', d1)
    returning id into d2;
  reset role;
  ok := ok and (select version_of from public.documents where id = d2) = d1;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a new version stays with the same azienda\n', case when ok then 'PASS' else 'FAIL' end);

  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.documents where zite_azienda_id = 't9-azienda';
  ok := n = 0 and not private.can_access_document_path(path);
  begin
    insert into public.documents (kind, title, zite_azienda_id) values ('team', 'intruso.pdf', 't9-azienda');
    ok := false;
  exception when others then null; end;
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalatore cannot see, read or add an azienda document (saw %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  ---------------------------------------------------------------- bucket
  ok := (select file_size_limit from storage.buckets where id = 'documents') = 52428800;
  failures := failures + (not ok)::int;
  report := report || format(E'%s the bucket takes files up to 50 MB\n', case when ok then 'PASS' else 'FAIL' end);

  ---------------------------------------------------------------- reminders of a trattativa
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.reminders (zite_trattativa_id, date_key, label, pratica_title, due_date, days_before, recipients)
    values ('t9-trattativa', 'chiusura', 'Chiusura prevista', 'Trattativa di prova', today + 7, array[7], array['t9-zite-s1']);
  begin
    insert into public.reminders (zite_trattativa_id, date_key, label, due_date, days_before, recipients)
      values ('t9-trattativa', 'chiusura', 'doppio', today, array[0], array['t9-zite-s1']);
    ok := false;
  exception when unique_violation then ok := true; end;
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff set a reminder on a trattativa; one per trattativa and date\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.reminders (zite_pratica_id, zite_trattativa_id, date_key, label, due_date, days_before, recipients)
      values ('t9-pratica', 't9-trattativa', 'x', 'Due record', today, array[0], array['t9-zite-s1']);
    ok := false;
  exception when check_violation then ok := true; end;
  begin
    insert into public.reminders (date_key, label, due_date, days_before, recipients)
      values ('y', 'Nessun record', today, array[0], array['t9-zite-s1']);
    ok := false;
  exception when check_violation then ok := ok and true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a reminder is about exactly one pratica or trattativa\n', case when ok then 'PASS' else 'FAIL' end);

  ok := pg_get_functiondef('private.send_due_reminders(boolean)'::regprocedure) like '%''trattativa:'' || r.zite_trattativa_id%';
  failures := failures + (not ok)::int;
  report := report || format(E'%s the morning job links a trattativa reminder to the trattativa\n', case when ok then 'PASS' else 'FAIL' end);

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
