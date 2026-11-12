-- Portale di caricamento fatture più stretto (migration portal_uploads_hardening, 2026-11-10).
-- Same pattern as 001-030: one DO block, everything rolled back by the final RAISE.

do $$
declare
  ok boolean;
  report text := '';
  failures int := 0;
  b record;
  u_ref uuid := gen_random_uuid();
begin
  select file_size_limit, allowed_mime_types, public into b from storage.buckets where id = 'portal-uploads';
  ok := b.public = false and b.file_size_limit = 104857600 and 'application/pdf' = any(b.allowed_mime_types)
        and not ('text/html' = any(b.allowed_mime_types)) and not ('application/x-msdownload' = any(b.allowed_mime_types));
  failures := failures + (not ok)::int;
  report := report || format(E'%s bucket portal-uploads private, 100 MB, no html / executables\n', case when ok then 'PASS' else 'FAIL' end);

  ok := exists (select 1 from pg_constraint where conname = 'upload_portal_files_status_check'
                 and pg_get_constraintdef(oid) like '%rejected%');
  failures := failures + (not ok)::int;
  report := report || format(E'%s status rejected allowed\n', case when ok then 'PASS' else 'FAIL' end);

  ok := not has_table_privilege('anon', 'private.portal_link_failures', 'select')
        and not has_table_privilege('authenticated', 'private.portal_link_failures', 'select')
        and not has_table_privilege('authenticated', 'private.portal_link_failures', 'insert');
  failures := failures + (not ok)::int;
  report := report || format(E'%s failures table closed to anon and authenticated\n', case when ok then 'PASS' else 'FAIL' end);

  -- a signed-in user cannot reach it through the API either
  insert into auth.users (id, email, aud, role) values (u_ref, 't31@example.test', 'authenticated', 'authenticated');
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform count(*) from private.portal_link_failures;
    ok := false;
  exception when insufficient_privilege then ok := true;
  end;
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a signed-in user is refused on the failures table\n', case when ok then 'PASS' else 'FAIL' end);

  insert into private.portal_link_failures (ip_hash) values (repeat('a', 64));
  ok := (select count(*) from private.portal_link_failures where ip_hash = repeat('a', 64)) = 1;
  failures := failures + (not ok)::int;
  report := report || format(E'%s the server records a failure\n', case when ok then 'PASS' else 'FAIL' end);

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
