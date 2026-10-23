-- What a segnalatore sees of the payments (migration partner_payments, PRDDISC-14): public.partner_payments(). Same pattern as 001-016: one DO block,
-- everything rolled back by the final RAISE. Made-up rows only (2027 dates, own companies and partners).
-- Three segnalatori: A (active referral on X, expired one on Y, a later one on Z, one on W shared with B), B (W; a removed referral on X), C (archived later).

do $$
declare
  org uuid := (select id from public.organizations limit 1);
  u_a uuid := gen_random_uuid(); u_b uuid := gen_random_uuid(); u_c uuid := gen_random_uuid();
  u_staff uuid := gen_random_uuid(); u_client uuid := gen_random_uuid();
  pa uuid; pb uuid; pc uuid;
  cx uuid; cy uuid; cz uuid; cw uuid; cclient uuid;
  prat uuid := gen_random_uuid();
  r_ax uuid := gen_random_uuid(); r_ay uuid := gen_random_uuid(); r_az uuid := gen_random_uuid(); r_aw uuid := gen_random_uuid();
  r_bw uuid := gen_random_uuid(); r_bx uuid := gen_random_uuid(); r_cx uuid := gen_random_uuid();
  n int; v text; cols text;
  report text := ''; failures int := 0; ok boolean;
  r record;
begin
  insert into auth.users (id, email, aud, role) values
    (u_a, 't17-a@example.test', 'authenticated', 'authenticated'), (u_b, 't17-b@example.test', 'authenticated', 'authenticated'),
    (u_c, 't17-c@example.test', 'authenticated', 'authenticated'), (u_staff, 't17-staff@example.test', 'authenticated', 'authenticated'),
    (u_client, 't17-client@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'partner' where id in (u_a, u_b, u_c);
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't17-zite-staff' where id = u_staff;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t17-a', 'T17 A', 't17-a@example.test', org) returning id into pa;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t17-b', 'T17 B', 't17-b@example.test', org) returning id into pb;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t17-c', 'T17 C', 't17-c@example.test', org) returning id into pc;
  insert into public.partner_members (partner_id, profile_id) values (pa, u_a), (pb, u_b), (pc, u_c);
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T17 X', 't17-x', org) returning id into cx;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T17 Y', 't17-y', org) returning id into cy;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T17 Z', 't17-z', org) returning id into cz;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T17 W', 't17-w', org) returning id into cw;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T17 client', 't17-client', org) returning id into cclient;
  insert into public.company_members (company_id, profile_id) values (cclient, u_client);
  update public.profiles set role = 'client' where id = u_client;

  perform private.sync_pratiche(jsonb_build_array(jsonb_build_object('id', prat, 'code', 'T17-P1', 'zite_azienda_id', 't17-x', 'status', 'In lavorazione', 'is_open', true, 'total_fee_cents', 500000, 'removed', false)));
  perform private.sync_referrals(jsonb_build_array(
    jsonb_build_object('id', r_ax, 'zite_segnalatore_id', 't17-a', 'zite_azienda_id', 't17-x', 'commission_pct', 20, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', false),
    jsonb_build_object('id', r_ay, 'zite_segnalatore_id', 't17-a', 'zite_azienda_id', 't17-y', 'commission_pct', 20, 'starts_on', '2026-01-01', 'duration_years', 1, 'ends_on', '2026-12-31', 'removed', false),
    jsonb_build_object('id', r_az, 'zite_segnalatore_id', 't17-a', 'zite_azienda_id', 't17-z', 'commission_pct', 20, 'starts_on', '2027-06-01', 'duration_years', null, 'ends_on', null, 'removed', false),
    jsonb_build_object('id', r_aw, 'zite_segnalatore_id', 't17-a', 'zite_azienda_id', 't17-w', 'commission_pct', 20, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', false),
    jsonb_build_object('id', r_bw, 'zite_segnalatore_id', 't17-b', 'zite_azienda_id', 't17-w', 'commission_pct', 10, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', false),
    jsonb_build_object('id', r_bx, 'zite_segnalatore_id', 't17-b', 'zite_azienda_id', 't17-x', 'commission_pct', 10, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', true),
    jsonb_build_object('id', r_cx, 'zite_segnalatore_id', 't17-c', 'zite_azienda_id', 't17-x', 'commission_pct', 5, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', false)));

  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, paid_at, total_cents, vat_cents, raw, company_id, pratica_id, pratica_link_source, removed_at) values
    -- X: referral of A (and C) active from 2027-01-01
    ('t17-x-paid',   'invoice', 'X1', 'paid',     'Incassata', date '2027-02-10', date '2027-03-10', date '2027-03-01', 122000, 22000, '{}', cx, prat, 'zite', null),
    ('t17-x-nodate', 'invoice', 'X2', 'paid',     'Incassata', date '2027-02-11', date '2027-03-11', null,              122000, 22000, '{}', cx, null, null, null),
    ('t17-x-unpaid', 'invoice', 'X3', 'unpaid',   'Emessa',    date '2027-02-12', date '2027-03-12', null,              122000, 22000, '{}', cx, null, null, null),
    ('t17-x-late',   'invoice', 'X4', 'late',     'Emessa',    date '2027-02-13', date '2027-02-20', null,              122000, 22000, '{}', cx, null, null, null),
    ('t17-x-cancel', 'invoice', 'X5', 'canceled', 'Annullata', date '2027-02-14', date '2027-03-14', null,              122000, 22000, '{}', cx, null, null, null),
    ('t17-x-credit', 'credit_note', 'X6', 'credit_note', 'Incassata', date '2027-02-15', date '2027-02-15', null,       -12200, -2200, '{}', cx, null, null, null),
    ('t17-x-gone',   'invoice', 'X7', 'paid',     'Incassata', date '2027-02-16', date '2027-03-16', date '2027-03-02', 122000, 22000, '{}', cx, null, null, now()),
    ('t17-x-before', 'invoice', 'X8', 'paid',     'Incassata', date '2026-12-31', date '2027-01-30', date '2027-01-10', 122000, 22000, '{}', cx, null, null, null),
    -- Y: A's referral ended 2026-12-31; Z: A's referral starts 2027-06-01; W: A and B
    ('t17-y-paid',   'invoice', 'Y1', 'paid',     'Incassata', date '2027-02-10', date '2027-03-10', date '2027-03-01', 122000, 22000, '{}', cy, null, null, null),
    ('t17-z-before', 'invoice', 'Z1', 'paid',     'Incassata', date '2027-05-31', date '2027-06-30', date '2027-06-05', 122000, 22000, '{}', cz, null, null, null),
    ('t17-z-after',  'invoice', 'Z2', 'paid',     'Incassata', date '2027-06-01', date '2027-07-01', date '2027-06-10', 122000, 22000, '{}', cz, null, null, null),
    ('t17-w-paid',   'invoice', 'W1', 'paid',     'Incassata', date '2027-02-20', date '2027-03-20', date '2027-03-05', 244000, 44000, '{}', cw, null, null, null),
    -- no company at all
    ('t17-nocomp',   'invoice', 'N1', 'paid',     'Incassata', date '2027-02-20', date '2027-03-20', date '2027-03-05', 122000, 22000, '{}', null, null, null, null);

  -- structure: no amount in the answer; nothing changed on the tables
  select string_agg(a, ',' order by o) into cols from unnest((select proargnames from pg_proc where oid = 'public.partner_payments()'::regprocedure)) with ordinality t(a, o);
  ok := cols = 'invoice_id,invoice_number,company_name,pratica_code,paid_at'
        and has_function_privilege('authenticated', 'public.partner_payments()', 'execute')
        and not has_function_privilege('anon', 'public.partner_payments()', 'execute');
  failures := failures + (not ok)::int;
  report := report || format(E'%s the function returns number, company, pratica code, payment date and no amount (%s); authenticated may call it, anonymous not\n', case when ok then 'PASS' else 'FAIL' end, cols);
  ok := not has_table_privilege('authenticated', 'public.qonto_documents', 'insert') and not has_table_privilege('authenticated', 'public.qonto_documents', 'update')
        and not has_table_privilege('anon', 'public.qonto_documents', 'select') and not has_table_privilege('authenticated', 'public.referrals', 'insert')
        and (select count(*) from pg_policies where tablename = 'qonto_documents') = 1;
  failures := failures + (not ok)::int;
  report := report || format(E'%s qonto_documents and referrals are untouched: no write for signed-in users, no anonymous read, still one staff-only policy\n', case when ok then 'PASS' else 'FAIL' end);

  -- A
  perform set_config('request.jwt.claims', json_build_object('sub', u_a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  ok := (select array_agg(invoice_number order by invoice_number) from public.partner_payments()) = array['W1', 'X1', 'Z2'];
  select string_agg(invoice_number, ',' order by invoice_number) into v from public.partner_payments();
  failures := failures + (not ok)::int;
  report := report || format(E'%s A sees only the paid invoices of A''s active referrals: W1, X1, Z2 (got %s)\n', case when ok then 'PASS' else 'FAIL' end, v);
  select * into r from public.partner_payments() where invoice_number = 'X1';
  ok := r.company_name = 'T17 X' and r.pratica_code = 'T17-P1' and r.paid_at = date '2027-03-01'
        and (select pratica_code is null from public.partner_payments() where invoice_number = 'W1');
  failures := failures + (not ok)::int;
  report := report || format(E'%s a row carries company, pratica code (null when unlinked) and the payment date\n', case when ok then 'PASS' else 'FAIL' end);
  ok := not exists (select 1 from public.partner_payments() where invoice_number in ('X2', 'X3', 'X4', 'X5', 'X6', 'X7', 'X8', 'Y1', 'Z1', 'N1'));
  failures := failures + (not ok)::int;
  report := report || format(E'%s never: paid without date, unpaid, overdue, cancelled, credit note, removed in Qonto, before the referral started, after it ended, no company\n', case when ok then 'PASS' else 'FAIL' end);
  ok := (select count(*) from public.qonto_documents) = 0 and (select count(*) from public.referrals) = 0 and (select count(*) from public.invoice_status_v) = 0
        and (select count(*) from public.invoice_payments_v) = 0 and (select count(*) from public.pratica_payment_status_v) = 0 and (select count(*) from public.review_invoices_v) = 0;
  begin insert into public.qonto_documents (qonto_id, kind, status_qonto, status, issue_date, total_cents, vat_cents, raw) values ('t17-hack', 'invoice', 'paid', 'Incassata', date '2027-01-01', 1, 0, '{}'); ok := false;
  exception when insufficient_privilege then null; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s A reads nothing directly (documents, referrals, views: zero rows) and cannot write\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  -- B: W1 yes (own referral); X1 no (own referral on X is removed)
  perform set_config('request.jwt.claims', json_build_object('sub', u_b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select string_agg(invoice_number, ',' order by invoice_number) into v from public.partner_payments();
  ok := v = 'W1';
  failures := failures + (not ok)::int;
  report := report || format(E'%s B sees W1 (also B''s client) and nothing of A''s other clients; B''s removed referral shows nothing (got %s)\n', case when ok then 'PASS' else 'FAIL' end, v);
  reset role;

  -- C: referral on X active: X1 yes; then archived -> zero at once
  perform set_config('request.jwt.claims', json_build_object('sub', u_c, 'role', 'authenticated')::text, true);
  set local role authenticated;
  ok := (select count(*) from public.partner_payments()) = 1 and (select invoice_number from public.partner_payments()) = 'X1';
  reset role;
  update public.partners set archived = true where id = pc;
  set local role authenticated;
  ok := ok and (select count(*) from public.partner_payments()) = 0;
  reset role;
  update public.partners set archived = false where id = pc;
  delete from public.partner_members where partner_id = pc;
  set local role authenticated;
  ok := ok and (select count(*) from public.partner_payments()) = 0;
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalatore sees X1, and zero rows at once when archived or removed from partner_members\n', case when ok then 'PASS' else 'FAIL' end);

  -- a referral removed in Zite stops showing
  perform private.sync_referrals(jsonb_build_array(jsonb_build_object('id', r_ax, 'zite_segnalatore_id', 't17-a', 'zite_azienda_id', 't17-x', 'commission_pct', 20, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', true)));
  perform set_config('request.jwt.claims', json_build_object('sub', u_a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select string_agg(invoice_number, ',' order by invoice_number) into v from public.partner_payments();
  ok := v = 'W1,Z2';
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalazione deleted in Zite stops showing its invoices (got %s)\n', case when ok then 'PASS' else 'FAIL' end, v);

  -- staff, client, anonymous
  perform set_config('request.jwt.claims', json_build_object('sub', u_staff, 'role', 'authenticated')::text, true);
  set local role authenticated;
  ok := (select count(*) from public.partner_payments()) = 0;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', u_client, 'role', 'authenticated')::text, true);
  set local role authenticated;
  ok := ok and (select count(*) from public.partner_payments()) = 0;
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff and a client get zero rows from the function\n', case when ok then 'PASS' else 'FAIL' end);

  set local role anon;
  begin perform count(*) from public.partner_payments(); ok := false; exception when insufficient_privilege then ok := true; end;
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s anonymous cannot call it\n', case when ok then 'PASS' else 'FAIL' end);

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
