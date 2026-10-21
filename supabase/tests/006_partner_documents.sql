-- Documents between Gemina and the segnalatori (migration 20261021150000). Same pattern as 001-005: one DO block, everything
-- rolled back by the final RAISE; the message is the report. A file reaching Storage is mirrored by the owner inserting the
-- storage.objects row (what the Storage API does after its own upload check).

do $$
declare
  org      uuid := (select id from public.organizations limit 1);
  u_s1     uuid := gen_random_uuid();  -- staff
  u_ref    uuid := gen_random_uuid();  -- segnalatore A
  u_ref2   uuid := gen_random_uuid();  -- segnalatore B
  p_ref    uuid;
  p_ref2   uuid;
  conv     uuid;
  conv2    uuid;
  m_ref    uuid;   -- A's message
  m_staff  uuid;   -- staff's message to A
  m_int    uuid;   -- staff's internal note on A's conversation
  d_file   uuid;   -- A's direct file
  d_msg    uuid;   -- A's file on own message
  d_int    uuid;   -- staff file on the internal note
  d_gem    uuid;   -- Gemina document for A
  d_v2     uuid;
  d_v3     uuid;
  d_link   uuid;
  d_b      uuid;   -- B's file
  path     text;
  n        int;
  i        int;
  r        record;
  report   text := '';
  failures int := 0;
  ok       boolean;
begin
  insert into auth.users (id, email, aud, role) values
    (u_s1,   't6-s1@example.test',   'authenticated', 'authenticated'),
    (u_ref,  't6-ref@example.test',  'authenticated', 'authenticated'),
    (u_ref2, 't6-ref2@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'manager', name_first = 'Uno', name_last = 'Test' where id = u_s1;
  update public.profiles set role = 'partner' where id in (u_ref, u_ref2);
  insert into public.partners (zite_segnalatore_id, name, email, organization_id)
    values ('t6-ref', 'Test referrer 6', 't6-ref@example.test', org) returning id into p_ref;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id)
    values ('t6-ref2', 'Test referrer 6b', 't6-ref2@example.test', org) returning id into p_ref2;
  insert into public.partner_members (partner_id, profile_id) values (p_ref, u_ref), (p_ref2, u_ref2);
  insert into public.conversations (kind, title, partner_id, created_by) values ('partner', 'Filo A', p_ref, u_ref) returning id into conv;
  insert into public.conversations (kind, title, partner_id, created_by) values ('partner', 'Filo B', p_ref2, u_ref2) returning id into conv2;
  insert into public.conversation_members (conversation_id, profile_id) values (conv, u_s1);

  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.messages (conversation_id, sender_id, body) values (conv, u_ref, 'ecco il file') returning id into m_ref;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.messages (conversation_id, sender_id, body) values (conv, u_s1, 'grazie') returning id into m_staff;
  insert into public.messages (conversation_id, sender_id, body, internal) values (conv, u_s1, 'nota interna', true) returning id into m_int;
  reset role;

  ---------------------------------------------------------------- segnalatore A uploads
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;

  insert into public.documents (kind, partner_id, title, mime_type, storage_path, uploaded_at, from_gemina, notified_at, category)
    values ('partner', p_ref, 'Bilancio 2025 (finale).pdf', 'application/pdf', 'partner/someone-else/x.pdf', now(), true, now(), 'Accordo')
    returning id, storage_path into d_file, path;
  select * into r from public.documents where id = d_file;
  ok := path = 'partner/' || p_ref || '/' || d_file || '/Bilancio_2025_finale_.pdf';
  failures := failures + (not ok)::int;
  report := report || format(E'%s the server makes the storage path (got %s)\n', case when ok then 'PASS' else 'FAIL' end, path);
  ok := r.uploaded_at is null and not r.from_gemina and r.notified_at is null and r.category is null and r.uploaded_by = u_ref;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a browser cannot claim upload, Gemina, notice or type; the author is set\n', case when ok then 'PASS' else 'FAIL' end);

  select count(*) into n from public.partner_documents() where id = d_file;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s the author sees the upload in progress (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  ok := private.can_upload_document_path(path); failures := failures + (not ok)::int;
  report := report || format(E'%s the author may upload to that path\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    perform public.confirm_document_upload(d_file);
    ok := false;
  exception when sqlstate 'P0002' then ok := true; when others then ok := false; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s confirming before the file is in Storage is refused\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.documents (kind, partner_id, title) values ('partner', p_ref2, 'intrusione.pdf');
    ok := false;
  exception when others then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s A cannot add a document for B\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.documents (kind, partner_id, title, conversation_id) values ('partner', p_ref, 'storto.pdf', conv2);
    ok := false;
  exception when others then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s A cannot put a document in B''s conversation\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.documents (kind, partner_id, title, message_id) values ('partner', p_ref, 'su gemina.pdf', m_staff);
    ok := false;
  exception when others then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s A cannot attach to a message of Gemina\n', case when ok then 'PASS' else 'FAIL' end);

  insert into public.documents (kind, partner_id, title, message_id) values ('partner', p_ref, 'allegato.pdf', m_ref) returning id into d_msg;
  select conversation_id into r from public.documents where id = d_msg;
  ok := r.conversation_id = conv; failures := failures + (not ok)::int;
  report := report || format(E'%s a file on A''s own message takes the message''s conversation\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.documents (kind, partner_id, title, link_url) values ('partner', p_ref, 'Sito', 'http://esempio.it');
    ok := false;
  exception when others then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a link must be https\n', case when ok then 'PASS' else 'FAIL' end);

  insert into public.documents (kind, partner_id, title, link_url) values ('partner', p_ref, 'Sito', 'https://esempio.it/a')
    returning id into d_link;
  select * into r from public.documents where id = d_link;
  ok := r.storage_path is null and r.uploaded_at is not null; failures := failures + (not ok)::int;
  report := report || format(E'%s a link has no file and is complete at once\n', case when ok then 'PASS' else 'FAIL' end);

  update public.documents set title = 'cambiato' where id = d_link;
  select title into r from public.documents where id = d_link;
  ok := r.title = 'Sito'; failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalatore cannot edit a document\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  select count(*) into n from public.notifications where document_id = d_link and recipient_id = u_s1 and kind = 'document'
     and link = 'segnalatore:t6-ref';
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s a shared link puts a bell for the team, with the segnalatore link (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  ---------------------------------------------------------------- the file reaches Storage, A confirms
  insert into storage.objects (bucket_id, name, metadata)
    values ('documents', path, jsonb_build_object('size', 1234, 'mimetype', 'application/pdf'));
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.confirm_document_upload(d_file);
  ok := not private.can_upload_document_path(path); failures := failures + (not ok)::int;
  report := report || format(E'%s after the upload the path cannot be written again\n', case when ok then 'PASS' else 'FAIL' end);
  ok := private.can_access_document_path(path); failures := failures + (not ok)::int;
  report := report || format(E'%s A can download own file\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;
  select * into r from public.documents where id = d_file;
  ok := r.uploaded_at is not null and r.size_bytes = 1234; failures := failures + (not ok)::int;
  report := report || format(E'%s confirmation takes size from Storage\n', case when ok then 'PASS' else 'FAIL' end);
  select count(*) into n from public.notifications where document_id = d_file and recipient_id = u_s1 and kind = 'document';
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s a confirmed direct file puts a bell for the team (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  ---------------------------------------------------------------- the file on A's message: no separate bell
  insert into storage.objects (bucket_id, name, metadata)
    select 'documents', storage_path, '{"size": 10}'::jsonb from public.documents where id = d_msg;
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.confirm_document_upload(d_msg);
  reset role;
  select count(*) into n from public.notifications where document_id = d_msg;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s a file on a message rides on the message''s notice (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  ---------------------------------------------------------------- staff
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.documents (kind, partner_id, title, message_id, shared) values ('partner', p_ref, 'interno.pdf', m_int, true)
    returning id into d_int;
  select shared into r from public.documents where id = d_int;
  ok := not r.shared; failures := failures + (not ok)::int;
  report := report || format(E'%s a file on an internal note is never shared\n', case when ok then 'PASS' else 'FAIL' end);

  insert into public.documents (kind, partner_id, title, category) values ('partner', p_ref, 'Presentazione.pdf', 'Presentazione')
    returning id into d_gem;
  select * into r from public.documents where id = d_gem;
  ok := r.from_gemina and r.category = 'Presentazione'; failures := failures + (not ok)::int;
  report := report || format(E'%s a staff document is marked Gemina and keeps its type\n', case when ok then 'PASS' else 'FAIL' end);

  insert into public.documents (kind, partner_id, title, version_of) values ('partner', p_ref, 'Bilancio v2.pdf', d_file) returning id into d_v2;
  insert into public.documents (kind, partner_id, title, version_of) values ('partner', p_ref, 'Bilancio v3.pdf', d_v2) returning id into d_v3;
  select version_of into r from public.documents where id = d_v3;
  ok := r.version_of = d_file; failures := failures + (not ok)::int;
  report := report || format(E'%s a version points at the first version\n', case when ok then 'PASS' else 'FAIL' end);

  select count(*) into n from public.partner_documents(p_ref) where id in (d_v2, d_v3, d_gem, d_int);
  ok := n = 4; failures := failures + (not ok)::int;
  report := report || format(E'%s staff see their own uploads in progress (expect 4, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  update public.documents set storage_path = 'partner/x/y', partner_id = p_ref2, uploaded_at = now(), title = 'Bilancio finale.pdf'
   where id = d_file;
  select * into r from public.documents where id = d_file;
  ok := r.storage_path = path and r.partner_id = p_ref and r.title = 'Bilancio finale.pdf';
  failures := failures + (not ok)::int;
  report := report || format(E'%s a staff edit changes the title but never scope or path\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    perform public.notify_document(d_gem);
    ok := false;
  exception when others then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a document not yet uploaded cannot be announced\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  insert into storage.objects (bucket_id, name, metadata)
    select 'documents', storage_path, '{"size": 99}'::jsonb from public.documents where id in (d_gem, d_int);
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.confirm_document_upload(d_gem);
  perform public.confirm_document_upload(d_int);
  select count(*) into n from public.notifications where document_id = d_gem;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s a Gemina document is not announced by itself (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  perform public.notify_document(d_gem);
  reset role;
  select count(*) into n from public.notifications where document_id = d_gem and recipient_id = u_ref and kind = 'document' and link = 'documenti';
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s "Notifica segnalatore" puts a bell for the segnalatore (expect 1, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.documents where id = d_gem and notified_at is not null;
  ok := n = 1; failures := failures + (not ok)::int;
  report := report || format(E'%s and records when\n', case when ok then 'PASS' else 'FAIL' end);

  ---------------------------------------------------------------- what A sees, and B
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.partner_documents() where id in (d_file, d_msg, d_link, d_gem);
  ok := n = 4; failures := failures + (not ok)::int;
  report := report || format(E'%s A sees own files, link and Gemina''s document (expect 4, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  select count(*) into n from public.documents where id in (d_int, d_v2, d_v3);
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s A never sees the internal file or Gemina''s uploads in progress (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  ok := private.can_access_document_path((select storage_path from public.documents where id = d_gem));
  failures := failures + (not ok)::int;
  report := report || format(E'%s A can download Gemina''s document\n', case when ok then 'PASS' else 'FAIL' end);
  begin
    perform public.notify_document(d_gem);
    ok := false;
  exception when others then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalatore cannot send "Notifica segnalatore"\n', case when ok then 'PASS' else 'FAIL' end);
  begin
    perform public.remove_document(d_gem);
    ok := false;
  exception when others then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s A cannot remove Gemina''s document\n', case when ok then 'PASS' else 'FAIL' end);
  perform public.mark_documents_read();
  select count(*) into n from public.notifications where recipient_id = u_ref and kind = 'document' and read_at is null;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s A marks own document notices read (expect 0 unread, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  perform public.remove_document(d_link);
  select count(*) into n from public.partner_documents() where id = d_link;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s A removes own link, which disappears (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  reset role;
  select count(*) into n from public.notifications where document_id = d_link and read_at is null;
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s and its bell entries are cleared (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  perform set_config('request.jwt.claims', json_build_object('sub', u_ref2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.partner_documents();
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s B sees none of A''s documents (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  ok := not private.can_access_document_path(path); failures := failures + (not ok)::int;
  report := report || format(E'%s B cannot download A''s file\n', case when ok then 'PASS' else 'FAIL' end);
  begin
    insert into public.documents (kind, partner_id, title, version_of) values ('partner', p_ref2, 'furto.pdf', d_file);
    ok := false;
  exception when others then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s B cannot add a version of A''s document\n', case when ok then 'PASS' else 'FAIL' end);

  -- send limit: 30 a minute
  begin
    for i in 1..30 loop
      insert into public.documents (kind, partner_id, title) values ('partner', p_ref2, 'f' || i || '.pdf');
    end loop;
    ok := true;
  exception when others then ok := false; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s B can add 30 documents in a minute\n', case when ok then 'PASS' else 'FAIL' end);
  begin
    insert into public.documents (kind, partner_id, title) values ('partner', p_ref2, 'f31.pdf');
    ok := false;
  exception when sqlstate 'P0429' then ok := true; when others then ok := false; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s the 31st is refused with P0429\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  ---------------------------------------------------------------- staff mark B's notices read for the team
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.mark_documents_read(p_ref);
  reset role;
  select count(*) into n from public.notifications nn join public.documents d on d.id = nn.document_id
   where d.partner_id = p_ref and nn.read_at is null
     and exists (select 1 from public.profiles p where p.id = nn.recipient_id and p.role = 'staff');
  ok := n = 0; failures := failures + (not ok)::int;
  report := report || format(E'%s staff reading one segnalatore''s documents clears the team''s bell (expect 0, got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  ---------------------------------------------------------------- history import keeps what it is given, no notices
  perform set_config('request.jwt.claims', '', true);
  perform set_config('gemina.import', 'on', true);
  insert into public.documents (kind, partner_id, title, storage_path, uploaded_at, from_gemina, zite_documento_id, created_at)
    values ('partner', p_ref, 'Storico.pdf', 'partner/' || p_ref || '/storico/Storico.pdf', '2026-01-01', true, 'zite-doc-1', '2026-01-01')
    returning id into d_b;
  perform set_config('gemina.import', 'off', true);
  select * into r from public.documents where id = d_b;
  ok := r.zite_documento_id = 'zite-doc-1' and r.created_at = '2026-01-01'::timestamptz and r.from_gemina
        and not exists (select 1 from public.notifications where document_id = d_b);
  failures := failures + (not ok)::int;
  report := report || format(E'%s the history import keeps time, Zite id and author side, without notices\n', case when ok then 'PASS' else 'FAIL' end);

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
