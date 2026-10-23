-- Invoice review list (migration invoice_review_view): Emessa without due date and Incassata without payment date are listed once each,
-- credit notes and removed documents are not, partner and anonymous see nothing. Same pattern as 001-012: rolled back by the final RAISE.

do $$
declare
  u_s1     uuid := gen_random_uuid();
  u_ref    uuid := gen_random_uuid();
  org      uuid := (select id from public.organizations limit 1);
  p_ref    uuid;
  report   text := '';
  failures int := 0;
  ok       boolean;
begin
  insert into auth.users (id, email, aud, role) values
    (u_s1,  't13-s1@example.test',  'authenticated', 'authenticated'),
    (u_ref, 't13-ref@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't13-zite-s1' where id = u_s1;
  update public.profiles set role = 'partner' where id = u_ref;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t13-ref', 'Test referrer 13', 't13-ref@example.test', org) returning id into p_ref;
  insert into public.partner_members (partner_id, profile_id) values (p_ref, u_ref);

  ok := (select 'security_invoker=true' = any(reloptions) from pg_class where oid = 'public.invoice_review_v'::regclass);
  failures := failures + (not ok)::int;
  report := report || format(E'%s the view is security_invoker\n', case when ok then 'PASS' else 'FAIL' end);

  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, paid_at, total_cents, vat_cents, raw, removed_at) values
    ('t13-no-due',    'invoice',     'T13-1', 'unpaid',      'Emessa',    date '2027-02-10', null,             null,             122000, 22000, '{}', null),
    ('t13-ok-due',    'invoice',     'T13-2', 'unpaid',      'Emessa',    date '2027-02-11', date '2027-03-11', null,            122000, 22000, '{}', null),
    ('t13-paid-nodt', 'invoice',     'T13-3', 'paid',        'Incassata', date '2027-02-12', date '2027-02-12', null,            122000, 22000, '{}', null),
    ('t13-paid-ok',   'invoice',     'T13-4', 'paid',        'Incassata', date '2027-02-13', date '2027-02-13', date '2027-02-20', 122000, 22000, '{}', null),
    ('t13-cn',        'credit_note', 'T13-NC', 'credit_note', 'Incassata', date '2027-02-14', date '2027-02-14', null,            -12200, -2200, '{}', null),
    ('t13-cancel',    'invoice',     'T13-5', 'canceled',    'Annullata', date '2027-02-15', null,             null,             122000, 22000, '{}', null),
    ('t13-removed',   'invoice',     'T13-6', 'unpaid',      'Emessa',    date '2027-02-16', null,             null,             122000, 22000, '{}', now());

  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  ok := (select count(*) from public.invoice_review_v where qonto_id like 't13-%') = 2
        and (select reason_code from public.invoice_review_v where qonto_id = 't13-no-due') = 'due_date_missing'
        and (select reason_code from public.invoice_review_v where qonto_id = 't13-paid-nodt') = 'paid_at_missing';
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff see exactly the two review cases (missing due date, paid without date)\n', case when ok then 'PASS' else 'FAIL' end);

  ok := not exists (select 1 from public.invoice_review_v where qonto_id in ('t13-ok-due', 't13-paid-ok', 't13-cn', 't13-cancel', 't13-removed'));
  failures := failures + (not ok)::int;
  report := report || format(E'%s complete invoices, credit notes, cancelled and removed documents are not review cases\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  ok := (select count(*) from public.invoice_review_v) = 0;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a partner reads zero rows\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  set local role anon;
  begin
    perform count(*) from public.invoice_review_v;
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s anonymous cannot read the view\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
