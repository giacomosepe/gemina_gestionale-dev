-- Invoice views (migration invoice_views, PRDDISC-6): Scaduta derived on the due date, paid-without-date flagged, credit notes reduce VAT,
-- Annullata and removed documents left out of money views, security_invoker (partner and anonymous see nothing).
-- Same pattern as 001-011: one DO block, everything rolled back by the final RAISE. Seeded rows are dated 2027 so real documents never mix in.

do $$
declare
  u_s1     uuid := gen_random_uuid();
  u_ref    uuid := gen_random_uuid();
  org      uuid := (select id from public.organizations limit 1);
  p_ref    uuid;
  today    date := (now() at time zone 'Europe/Rome')::date;
  n        int;
  r        record;
  report   text := '';
  failures int := 0;
  ok       boolean;
  v        text;
begin
  insert into auth.users (id, email, aud, role) values
    (u_s1,  't12-s1@example.test',  'authenticated', 'authenticated'),
    (u_ref, 't12-ref@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't12-zite-s1' where id = u_s1;
  update public.profiles set role = 'partner' where id = u_ref;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t12-ref', 'Test referrer 12', 't12-ref@example.test', org) returning id into p_ref;
  insert into public.partner_members (partner_id, profile_id) values (p_ref, u_ref);

  -- structure: all views are security_invoker
  ok := (select count(*) from pg_class c join pg_namespace s on s.oid = c.relnamespace
          where s.nspname = 'public' and c.relname in ('invoice_status_v', 'invoice_payments_v', 'invoice_vat_v', 'invoice_vat_month_v', 'invoice_vat_quarter_v')
            and 'security_invoker=true' = any(c.reloptions)) = 5;
  failures := failures + (not ok)::int;
  report := report || format(E'%s all five views are security_invoker\n', case when ok then 'PASS' else 'FAIL' end);

  -- seed (2027 issue dates for VAT; due dates around today for the overdue flag)
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, paid_at, total_cents, vat_cents, raw) values
    ('t12-due-yday',   'invoice', 'T12-1', 'unpaid',   'Emessa',    date '2027-02-10', today - 1, null,              122000, 22000, '{}'),
    ('t12-due-today',  'invoice', 'T12-2', 'unpaid',   'Emessa',    date '2027-02-11', today,     null,              122000, 22000, '{}'),
    ('t12-due-future', 'invoice', 'T12-3', 'unpaid',   'Emessa',    date '2027-02-12', today + 1, null,              122000, 22000, '{}'),
    ('t12-no-due',     'invoice', 'T12-4', 'unpaid',   'Emessa',    date '2027-02-13', null,      null,              122000, 22000, '{}'),
    ('t12-late',       'invoice', 'T12-5', 'late',     'Emessa',    date '2027-02-14', today - 30, null,             122000, 22000, '{}'),
    ('t12-paid-old',   'invoice', 'T12-6', 'paid',     'Incassata', date '2027-02-15', today - 30, date '2027-02-20', 122000, 22000, '{}'),
    ('t12-paid-nodate','invoice', 'T12-7', 'paid',     'Incassata', date '2027-02-16', today - 30, null,             122000, 22000, '{}'),
    ('t12-cancelled',  'invoice', 'T12-8', 'canceled', 'Annullata', date '2027-02-17', today - 30, null,             122000, 22000, '{}'),
    ('t12-cn',         'credit_note', 'T12-NC', 'credit_note', 'Incassata', date '2027-03-05', date '2027-03-05', null, -12200, -2200, '{}'),
    ('t12-q2',         'invoice', 'T12-9', 'paid',     'Incassata', date '2027-04-01', date '2027-04-30', date '2027-04-10', 61000, 11000, '{}');
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, paid_at, total_cents, vat_cents, raw, removed_at)
    values ('t12-removed', 'invoice', 'T12-R', 'paid', 'Incassata', date '2027-03-06', date '2027-03-06', date '2027-03-07', 122000, 22000, '{}', now());

  -- staff reads the views
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- Scaduta on the day after the due date, not on it
  ok := (select status_visible from public.invoice_status_v where qonto_id = 't12-due-yday') = 'Scaduta'
        and (select is_overdue and days_overdue = 1 from public.invoice_status_v where qonto_id = 't12-due-yday')
        and (select status_visible from public.invoice_status_v where qonto_id = 't12-due-today') = 'Emessa'
        and (select status_visible from public.invoice_status_v where qonto_id = 't12-due-future') = 'Emessa'
        and (select status_visible from public.invoice_status_v where qonto_id = 't12-no-due') = 'Emessa'
        and (select status_visible from public.invoice_status_v where qonto_id = 't12-late') = 'Scaduta';
  failures := failures + (not ok)::int;
  report := report || format(E'%s Scaduta from the day after the due date; due today, in the future or without date stays Emessa\n', case when ok then 'PASS' else 'FAIL' end);

  ok := (select status_visible from public.invoice_status_v where qonto_id = 't12-paid-old') = 'Incassata'
        and (select status_visible from public.invoice_status_v where qonto_id = 't12-cancelled') = 'Annullata'
        and (select status_visible from public.invoice_status_v where qonto_id = 't12-cn') = 'Incassata'
        and not (select is_overdue from public.invoice_status_v where qonto_id = 't12-paid-old');
  failures := failures + (not ok)::int;
  report := report || format(E'%s paid, cancelled and credit notes are never Scaduta\n', case when ok then 'PASS' else 'FAIL' end);

  ok := (select removed from public.invoice_status_v where qonto_id = 't12-removed')
        and (select count(*) from public.invoice_status_v where qonto_id like 't12-%') = 11;
  failures := failures + (not ok)::int;
  report := report || format(E'%s the status view shows every document, removed ones flagged\n', case when ok then 'PASS' else 'FAIL' end);

  -- payments
  select count(*) into n from public.invoice_payments_v where qonto_id like 't12-%';
  ok := n = 3
        and (select not needs_review from public.invoice_payments_v where qonto_id = 't12-paid-old')
        and (select needs_review and review_reason is not null from public.invoice_payments_v where qonto_id = 't12-paid-nodate')
        and (select issue_date = date '2027-02-15' and paid_at = date '2027-02-20' from public.invoice_payments_v where qonto_id = 't12-paid-old')
        and not exists (select 1 from public.invoice_payments_v where qonto_id in ('t12-cn', 't12-cancelled', 't12-removed', 't12-due-yday'));
  failures := failures + (not ok)::int;
  report := report || format(E'%s payments: paid invoices only (not credit notes, removed, unpaid), null paid_at flagged for review (rows: %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  -- VAT
  select count(*) into n from public.invoice_vat_v where qonto_id like 't12-%';
  ok := n = 9 and not exists (select 1 from public.invoice_vat_v where qonto_id in ('t12-cancelled', 't12-removed'));
  failures := failures + (not ok)::int;
  report := report || format(E'%s VAT per document: cancelled and removed left out (rows: %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  select * into r from public.invoice_vat_quarter_v where issue_quarter_key = '2027-Q1';
  -- Q1 2027: 7 invoices at 22000 VAT / 100000 net + the credit note (-2200 / -10000)
  ok := r.documents = 8 and r.vat_cents = 7 * 22000 - 2200 and r.net_cents = 7 * 100000 - 10000 and r.total_cents = 7 * 122000 - 12200;
  failures := failures + (not ok)::int;
  report := report || format(E'%s the credit note reduces the quarter: VAT %s, net %s, total %s, documents %s\n', case when ok then 'PASS' else 'FAIL' end, r.vat_cents, r.net_cents, r.total_cents, r.documents);

  select * into r from public.invoice_vat_quarter_v where issue_quarter_key = '2027-Q2';
  ok := r.documents = 1 and r.vat_cents = 11000 and r.issue_year = 2027 and r.issue_quarter = 2;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a document in April goes to Q2\n', case when ok then 'PASS' else 'FAIL' end);

  select * into r from public.invoice_vat_month_v where issue_month = date '2027-03-01';
  ok := r.documents = 1 and r.vat_cents = -2200 and r.net_cents = -10000;
  failures := failures + (not ok)::int;
  report := report || format(E'%s the month of the credit note is negative (removed invoice of March not counted)\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  -- a partner sees nothing
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  ok := (select count(*) from public.invoice_status_v) = 0 and (select count(*) from public.invoice_payments_v) = 0
        and (select count(*) from public.invoice_vat_v) = 0 and (select count(*) from public.invoice_vat_month_v) = 0
        and (select count(*) from public.invoice_vat_quarter_v) = 0;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a partner reads zero rows from every view\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  -- anonymous
  set local role anon;
  foreach v in array array['invoice_status_v', 'invoice_payments_v', 'invoice_vat_v', 'invoice_vat_month_v', 'invoice_vat_quarter_v'] loop
    begin
      execute format('select count(*) from public.%I', v);
      ok := false;
    exception when insufficient_privilege then ok := true; end;
    failures := failures + (not ok)::int;
    report := report || format(E'%s anonymous cannot read %s\n', case when ok then 'PASS' else 'FAIL' end, v);
  end loop;
  reset role;

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
