-- Allegati per la firma (migration signature_attachments, 2026-11-09). Same pattern as 001-028: one DO block, everything rolled back by the final RAISE.
-- Made-up rows only (own company, pratica and scadenze).

do $$
declare
  u_s1  uuid := gen_random_uuid();
  u_s2  uuid := gen_random_uuid();
  u_ref uuid := gen_random_uuid();
  org   uuid := (select id from public.organizations limit 1);
  p_ref uuid;
  pr1   uuid := gen_random_uuid();
  pr2   uuid := gen_random_uuid();
  sc1   uuid; sc2 uuid; sc_other uuid;
  a1    uuid; a2 uuid;
  f1    uuid;
  r     record;
  n     int;
  ok    boolean;
  report text := '';
  failures int := 0;
  sha_o text := repeat('a', 64);
  sha_s1 text := repeat('b', 64);
  sha_s2 text := repeat('c', 64);
begin
  insert into auth.users (id, email, aud, role) values
    (u_s1,  't29-s1@example.test',  'authenticated', 'authenticated'),
    (u_s2,  't29-s2@example.test',  'authenticated', 'authenticated'),
    (u_ref, 't29-ref@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't29-zite-s1' where id = u_s1;
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't29-zite-s2' where id = u_s2;
  update public.profiles set role = 'partner' where id = u_ref;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t29-ref', 'Test referrer 29', 't29-ref@example.test', org) returning id into p_ref;
  insert into public.partner_members (partner_id, profile_id) values (p_ref, u_ref);
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T29 A', 't29-a', org);
  perform private.sync_pratiche(jsonb_build_array(
    jsonb_build_object('id', pr1, 'code', 'T29-1', 'zite_azienda_id', 't29-a', 'status', 'In lavorazione', 'is_open', true, 'total_fee_cents', 100000, 'removed', false),
    jsonb_build_object('id', pr2, 'code', 'T29-2', 'zite_azienda_id', 't29-a', 'status', 'In lavorazione', 'is_open', true, 'total_fee_cents', 100000, 'removed', false)));

  ---------------------------------------------------------------- as a colleague
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;

  insert into public.scadenze (pratica_id, tipo, numero, nome) values (pr1, 'dom', 1, 'Domanda') returning id into sc1;
  insert into public.scadenze (pratica_id, tipo, numero, nome) values (pr1, 'int', 1, 'Rendicontazione 1') returning id into sc2;
  insert into public.scadenze (pratica_id, tipo, numero, nome) values (pr2, 'dom', 1, 'Domanda') returning id into sc_other;

  -- the folder of a scadenza
  update public.scadenze set drive_folder = 'https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOp' where id = sc1;
  begin
    update public.scadenze set drive_folder = 'https://example.com/drive/folders/1AbCdEfGhIjKlMnOp' where id = sc2;
    ok := false;
  exception when check_violation then ok := true; end;
  ok := ok and (select drive_folder from public.scadenze where id = sc1) is not null;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a scadenza keeps a Drive folder link; anything else is refused\n', case when ok then 'PASS' else 'FAIL' end);

  -- a document to sign
  insert into public.signature_attachments (pratica_id, scadenza_id, zite_dato_id, name, signatures_required, signers)
  values (pr1, sc1, 'dato-0001-questionario', '  Questionario PMS ', 2, array['cliente', 'gemina']) returning id into a1;
  select * into r from public.signature_attachments_v where id = a1;
  ok := r.name = 'Questionario PMS' and r.status = 'da_preparare' and r.signatures_done = 0 and r.created_by = u_s1 and r.last_event = 'created';
  failures := failures + (not ok)::int;
  report := report || format(E'%s a new document: trimmed name, state da_preparare, author set, event created\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.signature_attachments (pratica_id, scadenza_id, zite_dato_id, name, signatures_required, signers)
    values (pr1, sc_other, 'dato-0001-questionario', 'X', 1, array['cliente']);
    ok := false;
  exception when foreign_key_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a scadenza of another pratica is refused\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.signature_attachments (pratica_id, scadenza_id, zite_dato_id, name, signatures_required, signers)
    values (pr1, sc1, 'dato-0001-questionario', 'Twice', 1, array['cliente']);
    ok := false;
  exception when unique_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s one row per scadenza and voce\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.signature_attachments (pratica_id, scadenza_id, zite_dato_id, name, signatures_required, signers)
    values (pr1, sc2, 'dato-0002-mandato', 'Mandato', 1, array['cliente', 'gemina']);
    ok := false;
  exception when check_violation then ok := true; end;
  begin
    insert into public.signature_attachments (pratica_id, scadenza_id, zite_dato_id, name, signatures_required, signers)
    values (pr1, sc2, 'dato-0002-mandato', 'Mandato', 1, array['notaio']);
    ok := false;
  exception when check_violation then ok := ok; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s signers: only cliente / gemina, never more than the signatures required\n', case when ok then 'PASS' else 'FAIL' end);

  insert into public.signature_attachments (pratica_id, scadenza_id, zite_dato_id, name, signatures_required, signers, sent_at, sent_by)
  values (pr1, sc2, 'dato-0002-mandato', 'Mandato', 1, array['cliente'], now(), u_s2) returning id into a2;
  ok := (select sent_at is null and sent_by is null from public.signature_attachments where id = a2);
  failures := failures + (not ok)::int;
  report := report || format(E'%s a new row cannot arrive already sent\n', case when ok then 'PASS' else 'FAIL' end);

  -- the original file
  insert into public.signature_attachment_files (attachment_id, kind, file_name, drive_file_id, signatures, sha256, size_bytes, storage_path)
  values (a1, 'original', 'Questionario PMS.pdf', 'DriveFile0000001', 0, sha_o, 1000, org::text || '/' || a1::text || '/' || sha_o || '.pdf') returning id into f1;
  select * into r from public.signature_attachments_v where id = a1;
  ok := r.status = 'pronto' and r.current_file_name = 'Questionario PMS.pdf' and r.last_event = 'file';
  failures := failures + (not ok)::int;
  report := report || format(E'%s with its original: state pronto, current file, event file\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.signature_attachment_files (attachment_id, kind, file_name, drive_file_id, signatures, sha256, storage_path)
    values (a1, 'original', 'copy.pdf', 'DriveFile0000002', 0, sha_s1, 'elsewhere/' || sha_s1 || '.pdf');
    ok := false;
  exception when invalid_parameter_value then ok := true; end;
  begin
    insert into public.signature_attachment_files (attachment_id, kind, file_name, drive_file_id, signatures, sha256)
    values (a1, 'original', 'same bytes.pdf', 'DriveFile0000003', 0, sha_o);
    ok := false;
  exception when unique_violation then ok := ok; end;
  begin
    insert into public.signature_attachment_files (attachment_id, kind, file_name, drive_file_id, signatures, sha256)
    values (a1, 'signed', 'Questionario PMS.pdf', 'DriveFile0000004', 0, sha_s1);
    ok := false;
  exception when check_violation then ok := ok; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a copy only in its own folder; the same bytes once; signed = at least one .p7m\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    update public.signature_attachment_files set file_name = 'renamed.pdf' where id = f1;
    ok := false;
  -- refused by the column grant (only storage_path is updatable) before the trigger even runs
  exception when insufficient_privilege or invalid_parameter_value then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a version never changes\n', case when ok then 'PASS' else 'FAIL' end);

  -- sent (step 9 writes these): who sent is the colleague, whatever the request says
  update public.signature_attachments set sent_at = now(), sent_to = 'cliente@example.test', sent_message_id = 'msg-1', sent_by = u_s2 where id = a1;
  select * into r from public.signature_attachments_v where id = a1;
  ok := r.status = 'inviato' and r.sent_by = u_s1 and r.last_event = 'sent'
        and (select detail->>'to' from public.signature_events where attachment_id = a1 and event = 'sent') = 'cliente@example.test';
  failures := failures + (not ok)::int;
  report := report || format(E'%s sent: state inviato, sender = the colleague, event sent with the address\n', case when ok then 'PASS' else 'FAIL' end);

  update public.signature_attachments set signatures_required = 1, signers = array['cliente'] where id = a1;
  ok := (select signatures_required = 2 and signers = array['cliente', 'gemina'] from public.signature_attachments where id = a1);
  failures := failures + (not ok)::int;
  report := report || format(E'%s after sending, signatures and signers stay as they were\n', case when ok then 'PASS' else 'FAIL' end);

  -- signed once, then twice
  insert into public.signature_attachment_files (attachment_id, kind, file_name, drive_file_id, signatures, sha256)
  values (a1, 'signed', 'Questionario PMS.pdf.p7m', 'DriveFile0000005', 1, sha_s1);
  select * into r from public.signature_attachments_v where id = a1;
  ok := r.status = 'firmato_in_parte' and r.signatures_done = 1 and r.current_kind = 'signed' and r.last_event = 'signed_file';
  insert into public.signature_attachment_files (attachment_id, kind, file_name, drive_file_id, signatures, sha256)
  values (a1, 'signed', 'Questionario PMS.pdf.p7m.p7m', 'DriveFile0000006', 2, sha_s2);
  select * into r from public.signature_attachments_v where id = a1;
  ok := ok and r.status = 'firmato' and r.signatures_done = 2 and r.current_file_name = 'Questionario PMS.pdf.p7m.p7m';
  failures := failures + (not ok)::int;
  report := report || format(E'%s 1 of 2 signatures = firmato_in_parte, 2 of 2 = firmato, the latest signed file is current\n', case when ok then 'PASS' else 'FAIL' end);

  -- a copy attached later, once
  update public.signature_attachment_files set storage_path = org::text || '/' || a1::text || '/' || sha_s1 || '.pdf.p7m' where sha256 = sha_s1;
  begin
    update public.signature_attachment_files set storage_path = org::text || '/' || a1::text || '/' || sha_s1 || '.other' where sha256 = sha_s1;
    ok := false;
  exception when invalid_parameter_value then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s the bucket copy of a version can be added later, once\n', case when ok then 'PASS' else 'FAIL' end);

  -- marked signed by hand, and back
  update public.signature_attachments set marked_signed_at = now() where id = a2;
  ok := (select status = 'firmato' and marked_signed_by = u_s1 from public.signature_attachments_v where id = a2);
  update public.signature_attachments set marked_signed_at = null where id = a2;
  ok := ok and (select status = 'da_preparare' and marked_signed_by is null from public.signature_attachments_v where id = a2)
        and (select array_agg(event order by created_at, event) from public.signature_events where attachment_id = a2) @> array['created', 'marked_signed', 'unmarked'];
  failures := failures + (not ok)::int;
  report := report || format(E'%s «Segna come firmati» and back, both in the history\n', case when ok then 'PASS' else 'FAIL' end);

  -- archived
  update public.signature_attachments set archived = true where id = a2;
  ok := (select status from public.signature_attachments_v where id = a2) = 'archiviato';
  begin
    insert into public.signature_attachment_files (attachment_id, kind, file_name, drive_file_id, signatures, sha256)
    values (a2, 'original', 'Mandato.pdf', 'DriveFile0000007', 0, repeat('d', 64));
    ok := false;
  exception when invalid_parameter_value then ok := ok; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s an archived document takes no new file\n', case when ok then 'PASS' else 'FAIL' end);

  -- nobody writes the history or deletes anything
  begin
    insert into public.signature_events (organization_id, attachment_id, event) values (org, a1, 'signed');
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  begin
    delete from public.signature_attachments where id = a1;
    ok := false;
  exception when insufficient_privilege then ok := ok; end;
  begin
    delete from public.signature_attachment_files where attachment_id = a1;
    ok := false;
  exception when insufficient_privilege then ok := ok; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff cannot write the history nor delete a document or a version\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  ---------------------------------------------------------------- a referrer and anonymous see nothing
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.signature_attachments_v;
  ok := n = 0 and (select count(*) from public.signature_events) = 0 and (select count(*) from public.signature_attachment_files) = 0;
  begin
    insert into public.signature_attachments (pratica_id, scadenza_id, zite_dato_id, name, signatures_required, signers)
    values (pr1, sc2, 'dato-0003-altro', 'Altro', 1, array['cliente']);
    ok := false;
  -- a referrer cannot even see the scadenza, so the check on it refuses first
  exception when insufficient_privilege or foreign_key_violation then ok := ok; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a referrer reads nothing and cannot create a document\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  set local role anon;
  begin
    perform count(*) from public.signature_attachments_v;
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s anonymous cannot read the documents\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  ok := exists (select 1 from storage.buckets where id = 'signature-files' and not public and file_size_limit = 52428800)
        and (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'signature-files%') = 1;
  failures := failures + (not ok)::int;
  report := report || format(E'%s private bucket signature-files (50 MB), staff read only, no write policy\n', case when ok then 'PASS' else 'FAIL' end);

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
