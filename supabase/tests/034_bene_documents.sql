-- Documenti del singolo bene (migration bene_documents, 2026-11-11). One DO block, everything rolled back by the final RAISE.

do $$
declare
  org    uuid := (select id from public.organizations limit 1);
  staff  uuid := (select id from public.profiles where role = 'staff' limit 1);
  u_ref  uuid := gen_random_uuid();
  p_ref  uuid;
  b      uuid;
  d      uuid;
  ok     boolean;
  report text := '';
  failures int := 0;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', staff, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.beni (trattativa_zite_id, name) values ('t34-trattativa', 'Tornio') returning id into b;
  update public.beni set drive_folder = '1AbCdEfGhIjKlMnOpQrStUv' where id = b;

  insert into public.bene_documents (bene_id, dato_id, name, drive_file_id, valid_until) values (b, 'dato-preventivo', 'Preventivo.pdf', '1ZyXwVuTsRqPoNmLkJiHg', '2027-01-31') returning id into d;
  ok := (select organization_id = org and created_by = staff from public.bene_documents where id = d);
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff adds a document; organization and author set by the database\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.bene_documents (bene_id, dato_id, name) values (b, 'dato-preventivo', 'Senza file');
    ok := false;
  exception when check_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a document needs a Drive file or a link\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.bene_documents (bene_id, dato_id, name, link) values (b, 'dato-preventivo', 'Link', 'javascript:alert(1)');
    ok := false;
  exception when check_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a link must be https\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    delete from public.bene_documents where id = d;
    ok := exists (select 1 from public.bene_documents where id = d);
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff cannot delete a document (it is put aside instead)\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  insert into auth.users (id, email, aud, role) values (u_ref, 't34-ref@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'partner' where id = u_ref;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t34-ref', 'Test referrer 34', 't34-ref@example.test', org) returning id into p_ref;
  insert into public.partner_members (partner_id, profile_id) values (p_ref, u_ref);
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  ok := (select count(*) from public.bene_documents where id = d) = 0;
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalatore reads no document of a bene\n', case when ok then 'PASS' else 'FAIL' end);

  delete from public.beni where id = b;
  ok := not exists (select 1 from public.bene_documents where id = d);
  failures := failures + (not ok)::int;
  report := report || format(E'%s the documents follow their bene\n', case when ok then 'PASS' else 'FAIL' end);

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
