-- What a segnalatore sees of commissions and invoiced amounts (migration partner_commissions, PRDDISC-32): public.partner_commissions() and
-- public.partner_pratica_invoiced(). Same pattern as 017: one DO block, everything rolled back by the final RAISE. Made-up rows only (2027 dates).
-- Commission lines are created by the rebuild triggers (invoice or referral saved); the test only moves them to the stage it needs.
-- Referrals start a year before the run and W1 is issued 30 days before it, so they are active today whenever the test runs (the aggregate checks current_date);
-- ending B's W referral yesterday still covers W1's issue date, so its line stays. Segnalatori: A (active referral on X, pct 20), B (referral on X pct 10, and on W), C (archived later; referral on W). Staff, a client, anonymous.
-- NOT RUN when written (no database in the session): run it on production in its rolling-back transaction, then fix what it finds.

do $$
declare
  org uuid := (select id from public.organizations limit 1);
  u_a uuid := gen_random_uuid(); u_b uuid := gen_random_uuid(); u_c uuid := gen_random_uuid();
  u_staff uuid := gen_random_uuid(); u_client uuid := gen_random_uuid();
  pa uuid; pb uuid; pc uuid;
  cx uuid; cw uuid; cclient uuid;
  p_open uuid := gen_random_uuid(); p_closed uuid := gen_random_uuid(); p_w uuid := gen_random_uuid();
  r_ax uuid := gen_random_uuid(); r_bx uuid := gen_random_uuid(); r_bw uuid := gen_random_uuid(); r_cw uuid := gen_random_uuid();
  v text; v_expected text; cols text; n int;
  report text := ''; failures int := 0; ok boolean;
  r record;
begin
  insert into auth.users (id, email, aud, role) values
    (u_a, 't27-a@example.test', 'authenticated', 'authenticated'), (u_b, 't27-b@example.test', 'authenticated', 'authenticated'),
    (u_c, 't27-c@example.test', 'authenticated', 'authenticated'), (u_staff, 't27-staff@example.test', 'authenticated', 'authenticated'),
    (u_client, 't27-client@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'partner' where id in (u_a, u_b, u_c);
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't27-zite-staff' where id = u_staff;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t27-a', 'T27 A', 't27-a@example.test', org) returning id into pa;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t27-b', 'T27 B', 't27-b@example.test', org) returning id into pb;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t27-c', 'T27 C', 't27-c@example.test', org) returning id into pc;
  insert into public.partner_members (partner_id, profile_id) values (pa, u_a), (pb, u_b), (pc, u_c);
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T27 X', 't27-x', org) returning id into cx;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T27 W', 't27-w', org) returning id into cw;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T27 client', 't27-client', org) returning id into cclient;
  insert into public.company_members (company_id, profile_id) values (cclient, u_client);
  update public.profiles set role = 'client' where id = u_client;

  perform private.sync_pratiche(jsonb_build_array(
    jsonb_build_object('id', p_open,   'code', 'T27-OPEN',   'title', 'Titolo aperto', 'zite_azienda_id', 't27-x', 'status', 'In lavorazione', 'is_open', true,  'total_fee_cents', 500000, 'removed', false),
    jsonb_build_object('id', p_closed, 'code', 'T27-CLOSED', 'zite_azienda_id', 't27-x', 'status', 'Chiusa', 'is_open', false, 'total_fee_cents', 100000, 'removed', false),
    jsonb_build_object('id', p_w,      'code', 'T27-W',      'zite_azienda_id', 't27-w', 'status', 'In lavorazione', 'is_open', true,  'total_fee_cents', 300000, 'removed', false)));
  perform private.sync_referrals(jsonb_build_array(
    jsonb_build_object('id', r_ax, 'zite_segnalatore_id', 't27-a', 'zite_azienda_id', 't27-x', 'commission_pct', 20, 'starts_on', (current_date - 365)::text, 'duration_years', null, 'ends_on', null, 'removed', false),
    jsonb_build_object('id', r_bx, 'zite_segnalatore_id', 't27-b', 'zite_azienda_id', 't27-x', 'commission_pct', 10, 'starts_on', (current_date - 365)::text, 'duration_years', null, 'ends_on', null, 'removed', false),
    jsonb_build_object('id', r_bw, 'zite_segnalatore_id', 't27-b', 'zite_azienda_id', 't27-w', 'commission_pct', 10, 'starts_on', (current_date - 365)::text, 'duration_years', null, 'ends_on', null, 'removed', false),
    jsonb_build_object('id', r_cw, 'zite_segnalatore_id', 't27-c', 'zite_azienda_id', 't27-w', 'commission_pct', 5,  'starts_on', (current_date - 365)::text, 'duration_years', null, 'ends_on', null, 'removed', false)));

  -- X (A 20%, B 10%): X1 unpaid (teoriche), X2 paid (maturate), X3 paid + partner invoice (fatturate), X4 paid + partner invoice + paid_on (ricevute),
  --                   X5 paid + partner invoice, then cancelled; X6 paid + partner invoice, then removed in Qonto; XC a credit note (no line);
  --                   X7 on the closed pratica. W (B 10%, C 5%): W1 paid.
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, paid_at, total_cents, vat_cents, raw, company_id, pratica_id, pratica_link_source) values
    ('t27-x1', 'invoice', 'X1', 'unpaid', 'Emessa',    date '2027-02-01', date '2027-03-01', null,              122000, 22000, '{}', cx, p_open,   'zite'),
    ('t27-x2', 'invoice', 'X2', 'paid',   'Incassata', date '2027-02-02', date '2027-03-02', date '2027-03-01', 122000, 22000, '{}', cx, p_open,   'zite'),
    ('t27-x3', 'invoice', 'X3', 'paid',   'Incassata', date '2027-02-03', date '2027-03-03', date '2027-03-02', 122000, 22000, '{}', cx, p_open,   'zite'),
    ('t27-x4', 'invoice', 'X4', 'paid',   'Incassata', date '2027-02-04', date '2027-03-04', date '2027-03-03', 122000, 22000, '{}', cx, p_open,   'zite'),
    ('t27-x5', 'invoice', 'X5', 'paid',   'Incassata', date '2027-02-05', date '2027-03-05', date '2027-03-04', 122000, 22000, '{}', cx, p_open,   'zite'),
    ('t27-x6', 'invoice', 'X6', 'paid',   'Incassata', date '2027-02-06', date '2027-03-06', date '2027-03-05', 122000, 22000, '{}', cx, p_open,   'zite'),
    ('t27-xc', 'credit_note', 'XC', 'credit_note', 'Incassata', date '2027-02-07', date '2027-02-07', null,     -12200, -2200, '{}', cx, p_open,   'zite'),
    ('t27-x7', 'invoice', 'X7', 'unpaid', 'Emessa',    date '2027-02-08', date '2027-03-08', null,               61000, 11000, '{}', cx, p_closed, 'zite'),
    ('t27-w1', 'invoice', 'W1', 'paid',   'Incassata', current_date - 30, current_date, current_date - 20, 244000, 44000, '{}', cw, p_w,      'zite');

  -- put each line in its stage (the rebuild created the lines when the invoices were saved)
  update public.commissions c set partner_invoice_number = 'FP-3', partner_invoiced_on = date '2027-03-10'
    from public.qonto_documents d where d.id = c.invoice_id and d.qonto_id in ('t27-x3', 't27-x4', 't27-x5', 't27-x6');
  update public.commissions c set paid_on = date '2027-03-20' from public.qonto_documents d where d.id = c.invoice_id and d.qonto_id = 't27-x4';
  update public.qonto_documents set status = 'Annullata', status_qonto = 'canceled' where qonto_id = 't27-x5';
  update public.qonto_documents set removed_at = now() where qonto_id = 't27-x6';

  -- structure: columns, grants, nothing staff-only
  select string_agg(a, ',' order by o) into cols from unnest((select proargnames from pg_proc where oid = 'public.partner_commissions()'::regprocedure)) with ordinality t(a, o);
  ok := cols = 'id,invoice_id,invoice_number,invoice_issue_date,invoice_paid_at,invoice_net_cents,pratica_id,pratica_code,pratica_title,pct,base_cents,amount_cents,partner_invoice_number,partner_invoiced_on,paid_on,stage,stage_order,zite_azienda_id,company_name,invoice_cancelled'
        and cols !~ 'partner_id|partner_name|referral_id|qonto_id|invoice_status|raw|vat|total'
        and has_function_privilege('authenticated', 'public.partner_commissions()', 'execute') and not has_function_privilege('anon', 'public.partner_commissions()', 'execute')
        and has_function_privilege('authenticated', 'public.partner_pratica_invoiced()', 'execute') and not has_function_privilege('anon', 'public.partner_pratica_invoiced()', 'execute');
  failures := failures + (not ok)::int;
  report := report || format(E'%s columns are the agreed ones and no staff-only column (%s); authenticated may call both functions, anonymous neither\n', case when ok then 'PASS' else 'FAIL' end, cols);
  ok := (select count(*) from pg_policies where tablename = 'commissions') = 1 and not has_table_privilege('authenticated', 'public.commissions', 'insert')
        and not has_table_privilege('anon', 'public.commissions', 'select');
  failures := failures + (not ok)::int;
  report := report || format(E'%s commissions is untouched: still one staff-only policy, no write for signed-in users, no anonymous read\n', case when ok then 'PASS' else 'FAIL' end);

  -- expected stages of A's lines, read as the table owner (commission_stages_v is staff-only for a signed-in segnalatore)
  select string_agg(s.id || ':' || s.stage || ':' || s.stage_order, ',' order by s.id) into v_expected
    from public.commission_stages_v s join public.qonto_documents d on d.id = s.invoice_id
   where s.partner_id = pa;

  -- A: only A's lines, stage as commission_stages_v says, cancelled and removed left out
  perform set_config('request.jwt.claims', json_build_object('sub', u_a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select string_agg(invoice_number, ',' order by invoice_number) into v from public.partner_commissions();
  ok := v = 'X1,X2,X3,X4,X5,X6,X7';
  failures := failures + (not ok)::int;
  report := report || format(E'%s A sees only A''s lines: X1..X7 (got %s): X5 (cancelled) and X6 (removed) stay because already invoiced; not W1 (not A''s client), nor B''s lines\n', case when ok then 'PASS' else 'FAIL' end, v);
  select string_agg(invoice_number || '=' || stage, ',' order by invoice_number) into v from public.partner_commissions();
  ok := v = 'X1=Provvigioni teoriche,X2=Provvigioni maturate,X3=Provvigioni fatturate,X4=Provvigioni ricevute,X5=Provvigioni fatturate,X6=Provvigioni fatturate,X7=Provvigioni teoriche';
  failures := failures + (not ok)::int;
  report := report || format(E'%s the four stages come out right (got %s)\n', case when ok then 'PASS' else 'FAIL' end, v);
  ok := v_expected is not null and v_expected = (select string_agg(f.id || ':' || f.stage || ':' || f.stage_order, ',' order by f.id) from public.partner_commissions() f);
  failures := failures + (not ok)::int;
  report := report || format(E'%s the stage of each returned line equals the one of commission_stages_v\n', case when ok then 'PASS' else 'FAIL' end);
  select * into r from public.partner_commissions() where invoice_number = 'X4';
  ok := r.pratica_code = 'T27-OPEN' and r.pratica_title = 'Titolo aperto' and r.company_name = 'T27 X' and r.zite_azienda_id = 't27-x' and r.pct = 20
        and r.base_cents = 100000 and r.invoice_net_cents = 100000 and r.amount_cents = 20000
        and r.partner_invoice_number = 'FP-3' and r.partner_invoiced_on = date '2027-03-10' and r.paid_on = date '2027-03-20'
        and r.invoice_issue_date = date '2027-02-04' and r.invoice_paid_at = date '2027-03-03' and r.stage_order = 4 and not r.invoice_cancelled
        and (select invoice_cancelled from public.partner_commissions() where invoice_number = 'X5') and (select invoice_cancelled from public.partner_commissions() where invoice_number = 'X6')
        and not (select invoice_cancelled from public.partner_commissions() where invoice_number = 'X1');
  failures := failures + (not ok)::int;
  report := report || format(E'%s a line carries company, pratica code and title, percentage, base, amount, invoice and own-invoice dates, paid_on\n', case when ok then 'PASS' else 'FAIL' end);
  ok := (select count(*) from public.commissions) = 0 and (select count(*) from public.commission_lines_v) = 0 and (select count(*) from public.pratica_payment_status_v) = 0;
  begin insert into public.commissions (invoice_id, referral_id, partner_id, pct, base_cents, amount_cents) values (gen_random_uuid(), r_ax, pa, 20, 0, 0); ok := false;
  exception when insufficient_privilege then null; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s A reads nothing directly (commissions, the views: zero rows) and cannot write; the functions are the only path\n', case when ok then 'PASS' else 'FAIL' end);

  -- A: invoiced net of the open pratiche of A's clients, credit note subtracted, nothing else
  select string_agg(pratica_id::text || '=' || invoiced_net_cents, ',') into v from public.partner_pratica_invoiced();
  ok := v = p_open::text || '=' || (4 * 100000 - 10000);     -- X1..X4 (X5 cancelled, X6 removed in Qonto), the credit note XC -10000; X7 is on the closed pratica
  failures := failures + (not ok)::int;
  report := report || format(E'%s A gets the invoiced net of the open pratica of X only (cancelled and removed invoices do not count, credit note subtracted; got %s)\n', case when ok then 'PASS' else 'FAIL' end, v);
  reset role;

  -- B: own lines only (X lines at 10%, W1); C and A see none of them
  perform set_config('request.jwt.claims', json_build_object('sub', u_b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select string_agg(invoice_number || ':' || pct, ',' order by invoice_number) into v from public.partner_commissions();
  ok := v = 'W1:10,X1:10,X2:10,X3:10,X4:10,X5:10,X6:10,X7:10';
  failures := failures + (not ok)::int;
  report := report || format(E'%s B sees B''s own lines at B''s percentage (got %s)\n', case when ok then 'PASS' else 'FAIL' end, v);
  select count(*) into n from public.partner_pratica_invoiced();
  ok := n = 2;
  failures := failures + (not ok)::int;
  report := report || format(E'%s B gets the aggregates of the two open pratiche of B''s clients (got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  reset role;

  -- a referral that stops being active today leaves the aggregate (not the lines)
  update public.referrals set ends_on = current_date - 1 where id = r_bw;
  perform set_config('request.jwt.claims', json_build_object('sub', u_b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  ok := (select count(*) from public.partner_pratica_invoiced()) = 1 and exists (select 1 from public.partner_commissions() where invoice_number = 'W1');
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a referral that is no longer active drops its pratica from the aggregate, its stored lines stay\n', case when ok then 'PASS' else 'FAIL' end);

  -- C: W1 at 5%; archived -> zero at once; removed from partner_members -> zero
  perform set_config('request.jwt.claims', json_build_object('sub', u_c, 'role', 'authenticated')::text, true);
  set local role authenticated;
  ok := (select count(*) from public.partner_commissions()) = 1 and (select pct from public.partner_commissions()) = 5;
  reset role;
  update public.partners set archived = true where id = pc;
  set local role authenticated;
  ok := ok and (select count(*) from public.partner_commissions()) = 0 and (select count(*) from public.partner_pratica_invoiced()) = 0;
  reset role;
  update public.partners set archived = false where id = pc;
  update public.partner_members set profile_id = u_client where partner_id = pc;   -- an update, not a delete: the SQL connector holds back DELETE statements
  set local role authenticated;
  ok := ok and (select count(*) from public.partner_commissions()) = 0;
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalatore sees their line, and zero rows at once when archived or removed from partner_members\n', case when ok then 'PASS' else 'FAIL' end);

  -- staff: zero rows
  perform set_config('request.jwt.claims', json_build_object('sub', u_staff, 'role', 'authenticated')::text, true);
  set local role authenticated;
  ok := (select count(*) from public.partner_commissions()) = 0 and (select count(*) from public.partner_pratica_invoiced()) = 0;
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff get zero rows from both functions\n', case when ok then 'PASS' else 'FAIL' end);

  set local role anon;
  begin perform count(*) from public.partner_commissions(); ok := false; exception when insufficient_privilege then ok := true; end;
  begin perform count(*) from public.partner_pratica_invoiced(); ok := false; exception when insufficient_privilege then null; end;
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s anonymous cannot call either\n', case when ok then 'PASS' else 'FAIL' end);

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
