-- Qonto documents (migration qonto_documents, PRDDISC-2): staff read, partner and anonymous see nothing, nobody but the service role writes.
-- Same pattern as 001-009: one DO block, everything rolled back by the final RAISE; the message is the report. Test data only.

do $$
declare
  org      uuid := (select id from public.organizations limit 1);
  u_s1     uuid := gen_random_uuid();
  u_ref    uuid := gen_random_uuid();
  p_ref    uuid;
  d1       uuid;
  n        int;
  r        record;
  report   text := '';
  failures int := 0;
  ok       boolean;
begin
  insert into auth.users (id, email, aud, role) values
    (u_s1,  't10-s1@example.test',  'authenticated', 'authenticated'),
    (u_ref, 't10-ref@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't10-zite-s1' where id = u_s1;
  update public.profiles set role = 'partner' where id = u_ref;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id)
    values ('t10-ref', 'Test referrer 10', 't10-ref@example.test', org) returning id into p_ref;
  insert into public.partner_members (partner_id, profile_id) values (p_ref, u_ref);

  -- structure
  ok := (select relrowsecurity from pg_class where oid = 'public.qonto_documents'::regclass)
        and (select relrowsecurity from pg_class where oid = 'public.qonto_sync_runs'::regclass)
        and exists (select 1 from pg_constraint where conrelid = 'public.qonto_documents'::regclass and contype = 'u'
                    and conkey = array[(select attnum from pg_attribute where attrelid = 'public.qonto_documents'::regclass and attname = 'qonto_id')]);
  failures := failures + (not ok)::int;
  report := report || format(E'%s RLS on both tables; qonto_id unique\n', case when ok then 'PASS' else 'FAIL' end);

  -- the service role writes (as the sync function does)
  set local role service_role;
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, paid_at, total_cents, vat_cents, raw)
    values ('t10-inv-1', 'invoice', 'T10-001', 'paid', 'Incassata', date '2026-01-10', date '2026-02-10', date '2026-02-01', 122000, 22000, '{"id":"t10-inv-1"}')
    returning id into d1;
  insert into public.qonto_documents (qonto_id, kind, status_qonto, status, issue_date, total_cents, vat_cents, raw)
    values ('t10-cn-1', 'credit_note', 'unpaid', 'Emessa', date '2026-01-20', 12200, 2200, '{}');
  insert into public.qonto_sync_runs (fetched_count, inserted_count) values (2, 2);
  reset role;
  select * into r from public.qonto_documents where id = d1;
  ok := r.net_cents = 100000 and r.status = 'Incassata' and r.company_id is null and r.zite_pratica_id is null and r.currency = 'EUR';
  failures := failures + (not ok)::int;
  report := report || format(E'%s service role inserts; net = total - VAT in cents (got %s)\n', case when ok then 'PASS' else 'FAIL' end, r.net_cents);

  -- paid_at stays null when unknown
  ok := (select paid_at is null from public.qonto_documents where qonto_id = 't10-cn-1');
  failures := failures + (not ok)::int;
  report := report || format(E'%s paid_at stays null when Qonto has none\n', case when ok then 'PASS' else 'FAIL' end);

  -- constraints
  begin
    insert into public.qonto_documents (qonto_id, kind, status_qonto, status, issue_date, total_cents, vat_cents, raw)
      values ('t10-inv-1', 'invoice', 'paid', 'Incassata', date '2026-01-10', 1, 0, '{}');
    ok := false;
  exception when unique_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a second row with the same qonto_id is refused\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.qonto_documents (qonto_id, kind, status_qonto, status, issue_date, total_cents, vat_cents, raw)
      values ('t10-bad-status', 'invoice', 'late', 'Scaduta', date '2026-01-10', 1, 0, '{}');
    ok := false;
  exception when check_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s Scaduta cannot be stored\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.qonto_documents (qonto_id, kind, status_qonto, status, issue_date, total_cents, vat_cents, raw)
      values ('t10-bad-kind', 'quote', 'paid', 'Incassata', date '2026-01-10', 1, 0, '{}');
    ok := false;
  exception when check_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s kind is invoice or credit_note only\n', case when ok then 'PASS' else 'FAIL' end);

  -- staff read
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.qonto_documents where qonto_id like 't10-%';
  ok := n = 2 and (select count(*) from public.qonto_sync_runs) >= 1;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff read documents and sync runs (documents: %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  -- no write for staff (clients of the API)
  begin
    insert into public.qonto_documents (qonto_id, kind, status_qonto, status, issue_date, total_cents, vat_cents, raw)
      values ('t10-staff', 'invoice', 'paid', 'Incassata', date '2026-01-10', 1, 0, '{}');
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff cannot insert\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    update public.qonto_documents set total_cents = 0 where id = d1;
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff cannot update\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    delete from public.qonto_documents where id = d1;
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff cannot delete\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  -- partner sees nothing, writes nothing
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.qonto_documents;
  ok := n = 0 and (select count(*) from public.qonto_sync_runs) = 0;
  failures := failures + (not ok)::int;
  report := report || format(E'%s partner reads zero documents and zero sync runs (documents: %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  begin
    insert into public.qonto_documents (qonto_id, kind, status_qonto, status, issue_date, total_cents, vat_cents, raw)
      values ('t10-ref', 'invoice', 'paid', 'Incassata', date '2026-01-10', 1, 0, '{}');
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s partner cannot insert\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  -- anonymous
  set local role anon;
  begin
    perform count(*) from public.qonto_documents;
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s anonymous cannot read documents\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    perform count(*) from public.qonto_sync_runs;
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s anonymous cannot read sync runs\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.qonto_documents (qonto_id, kind, status_qonto, status, issue_date, total_cents, vat_cents, raw)
      values ('t10-anon', 'invoice', 'paid', 'Incassata', date '2026-01-10', 1, 0, '{}');
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s anonymous cannot insert\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
