-- Commission rebuild and triggers (migration commission_rebuild, PRDDISC-20): lines appear / follow / disappear on their own, percentage frozen, protected
-- lines untouched, matured_at once, idempotent, errors logged without breaking the save, admin repair. Same pattern as 001-018: one DO block, everything
-- rolled back by the final RAISE. Made-up rows only (2027 dates, own companies, partners and referrals).

do $$
declare
  org uuid := (select id from public.organizations limit 1);
  u_admin uuid := gen_random_uuid(); u_mgr uuid := gen_random_uuid(); u_part uuid := gen_random_uuid();
  pa uuid; pb uuid; cx uuid; cy uuid; cz uuid;
  prat_x uuid := gen_random_uuid(); prat_y uuid := gen_random_uuid(); prat_z uuid := gen_random_uuid();
  r_a uuid := gen_random_uuid(); r_b uuid := gen_random_uuid(); r_c uuid := gen_random_uuid(); r_d uuid := gen_random_uuid();
  d1 uuid; d2 uuid; d3 uuid; d4 uuid; d5 uuid; d6 uuid; d_credit uuid; d_cancel uuid; d_nopr uuid; d_nocomp uuid;
  n int; k int; ts timestamptz; ts2 timestamptz; snap1 text; snap2 text; res jsonb;
  report text := ''; failures int := 0; ok boolean;
begin
  insert into auth.users (id, email, aud, role) values
    (u_admin, 't19-admin@example.test', 'authenticated', 'authenticated'), (u_mgr, 't19-mgr@example.test', 'authenticated', 'authenticated'),
    (u_part, 't19-part@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'admin', zite_user_id = 't19-z-admin' where id = u_admin;
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't19-z-mgr' where id = u_mgr;
  update public.profiles set role = 'partner' where id = u_part;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t19-a', 'T19 A', 't19-a@example.test', org) returning id into pa;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t19-b', 'T19 B', 't19-b@example.test', org) returning id into pb;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T19 X', 't19-x', org) returning id into cx;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T19 Y', 't19-y', org) returning id into cy;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T19 Z', 't19-z', org) returning id into cz;
  perform private.sync_pratiche(jsonb_build_array(
    jsonb_build_object('id', prat_x, 'code', 'T19-X', 'zite_azienda_id', 't19-x', 'status', 'In lavorazione', 'is_open', true, 'total_fee_cents', 500000, 'removed', false),
    jsonb_build_object('id', prat_y, 'code', 'T19-Y', 'zite_azienda_id', 't19-y', 'status', 'In lavorazione', 'is_open', true, 'total_fee_cents', 500000, 'removed', false),
    jsonb_build_object('id', prat_z, 'code', 'T19-Z', 'zite_azienda_id', 't19-z', 'status', 'In lavorazione', 'is_open', true, 'total_fee_cents', 500000, 'removed', false)));
  -- X: A 10% open ended from 2027-01-01; B 5% from 2027-01-01 to 2027-02-28 (ended before the March invoices)
  perform private.sync_referrals(jsonb_build_array(
    jsonb_build_object('id', r_a, 'zite_segnalatore_id', 't19-a', 'zite_azienda_id', 't19-x', 'commission_pct', 10, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', false),
    jsonb_build_object('id', r_b, 'zite_segnalatore_id', 't19-b', 'zite_azienda_id', 't19-x', 'commission_pct', 5, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', '2027-02-28', 'removed', false)));

  -- 1. paid invoice, one active referral (B ended before it): one line, 10% of the whole net amount, matured at creation
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, paid_at, total_cents, vat_cents, raw, company_id, pratica_id, pratica_link_source) values
    ('t19-1', 'invoice', 'D1', 'paid', 'Incassata', date '2027-03-01', date '2027-03-31', date '2027-03-10', 122000, 22000, '{}', cx, prat_x, 'zite');
  select id into d1 from public.qonto_documents where qonto_id = 't19-1';
  select count(*) into n from public.commissions where invoice_id = d1;
  ok := n = 1 and (select referral_id from public.commissions where invoice_id = d1) = r_a
        and (select pct from public.commissions where invoice_id = d1) = 10 and (select base_cents from public.commissions where invoice_id = d1) = 100000
        and (select amount_cents from public.commissions where invoice_id = d1) = 10000
        and (select matured_at from public.commissions where invoice_id = d1) = (select created_at from public.commissions where invoice_id = d1);
  failures := failures + (not ok)::int;
  report := report || format(E'%s paid invoice + one active referral = one line (10%% of the whole net amount, no exclusion); the referral that ended before is left out; matured_at = created_at (born paid) (%s lines)\n', case when ok then 'PASS' else 'FAIL' end, n);

  -- 2. unpaid invoice in February: both referrals were active: two lines, not matured
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, total_cents, vat_cents, raw, company_id, pratica_id, pratica_link_source) values
    ('t19-2', 'invoice', 'D2', 'unpaid', 'Emessa', date '2027-02-10', date '2027-03-10', 122000, 22000, '{}', cx, prat_x, 'zite');
  select id into d2 from public.qonto_documents where qonto_id = 't19-2';
  ok := (select count(*) from public.commissions where invoice_id = d2) = 2 and (select count(*) from public.commissions where invoice_id = d2 and matured_at is null) = 2
        and (select amount_cents from public.commissions where invoice_id = d2 and referral_id = r_b) = 5000;
  failures := failures + (not ok)::int;
  report := report || format(E'%s an unpaid February invoice gets both referrals active that day (10%% and 5%%), not matured\n', case when ok then 'PASS' else 'FAIL' end);

  -- 3. the referral's percentage changes: existing lines keep theirs, a new invoice takes the new one
  perform private.sync_referrals(jsonb_build_array(
    jsonb_build_object('id', r_a, 'zite_segnalatore_id', 't19-a', 'zite_azienda_id', 't19-x', 'commission_pct', 20, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', false)));
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, total_cents, vat_cents, raw, company_id, pratica_id, pratica_link_source) values
    ('t19-3', 'invoice', 'D3', 'unpaid', 'Emessa', date '2027-03-05', date '2027-04-05', 244000, 44000, '{}', cx, prat_x, 'zite');
  select id into d3 from public.qonto_documents where qonto_id = 't19-3';
  ok := (select pct from public.commissions where invoice_id = d1) = 10 and (select pct from public.commissions where invoice_id = d2 and referral_id = r_a) = 10
        and (select pct from public.commissions where invoice_id = d3) = 20 and (select amount_cents from public.commissions where invoice_id = d3) = 40000;
  failures := failures + (not ok)::int;
  report := report || format(E'%s changing the referral percentage (10 -> 20) leaves existing lines at 10%%; the next invoice gets 20%%\n', case when ok then 'PASS' else 'FAIL' end);

  -- 4. credit note, cancelled invoice, invoice with no pratica, invoice with no company: no lines
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, paid_at, total_cents, vat_cents, raw, company_id, pratica_id, pratica_link_source) values
    ('t19-cn', 'credit_note', 'N1', 'credit_note', 'Incassata', date '2027-03-06', date '2027-03-06', null, -12200, -2200, '{}', cx, prat_x, 'zite'),
    ('t19-cx', 'invoice', 'C1', 'canceled', 'Annullata', date '2027-03-06', date '2027-04-06', null, 122000, 22000, '{}', cx, prat_x, 'zite'),
    ('t19-np', 'invoice', 'P0', 'paid', 'Incassata', date '2027-03-06', date '2027-04-06', date '2027-03-07', 122000, 22000, '{}', cx, null, 'manual'),
    ('t19-nc', 'invoice', 'K0', 'paid', 'Incassata', date '2027-03-06', date '2027-04-06', date '2027-03-07', 122000, 22000, '{}', null, null, 'manual');
  select count(*) into n from public.commissions c join public.qonto_documents q on q.id = c.invoice_id where q.qonto_id in ('t19-cn', 't19-cx', 't19-np', 't19-nc');
  ok := n = 0;
  failures := failures + (not ok)::int;
  report := report || format(E'%s credit note, cancelled invoice, invoice with no pratica and invoice with no company get no lines (%s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  -- 5. idempotent: a second run (all invoices) changes nothing, not even updated_at
  select string_agg(format('%s|%s|%s|%s|%s|%s', id, base_cents, amount_cents, matured_at, updated_at, pct), ';' order by id) into snap1 from public.commissions;
  res := private.rebuild_all_commissions();
  select string_agg(format('%s|%s|%s|%s|%s|%s', id, base_cents, amount_cents, matured_at, updated_at, pct), ';' order by id) into snap2 from public.commissions;
  ok := snap1 = snap2 and (res->>'inserted')::int = 0 and (res->>'updated')::int = 0 and (res->>'deleted')::int = 0 and (res->>'matured')::int = 0 and (res->>'errors')::int = 0;
  failures := failures + (not ok)::int;
  report := report || format(E'%s running the whole rebuild again changes nothing (%s)\n', case when ok then 'PASS' else 'FAIL' end, res::text);

  -- 6. matured_at: set the first time the invoice is paid, never again
  update public.qonto_documents set status = 'Incassata', paid_at = date '2027-03-20' where id = d3;
  select matured_at into ts from public.commissions where invoice_id = d3;
  update public.qonto_documents set status = 'Emessa', paid_at = null where id = d3;
  perform pg_sleep(0.01);
  update public.qonto_documents set status = 'Incassata', paid_at = date '2027-03-25' where id = d3;
  select matured_at into ts2 from public.commissions where invoice_id = d3;
  ok := ts is not null and ts = ts2 and ts > (select created_at from public.commissions where invoice_id = d3);
  failures := failures + (not ok)::int;
  report := report || format(E'%s an unpaid invoice that gets paid matures its line once (after creation); paid -> unpaid -> paid keeps the first time\n', case when ok then 'PASS' else 'FAIL' end);

  -- 7. the base follows a corrected invoice on a free line, not on an invoiced or a received one
  update public.commissions set partner_invoice_number = 'FS-1', partner_invoiced_on = date '2027-03-30' where invoice_id = d2 and referral_id = r_a;
  update public.qonto_documents set total_cents = 244000, vat_cents = 44000 where id = d2;   -- net 100000 -> 200000
  ok := (select base_cents from public.commissions where invoice_id = d2 and referral_id = r_b) = 200000
        and (select amount_cents from public.commissions where invoice_id = d2 and referral_id = r_b) = 10000
        and (select base_cents from public.commissions where invoice_id = d2 and referral_id = r_a) = 100000
        and (select pct from public.commissions where invoice_id = d2 and referral_id = r_b) = 5;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a corrected invoice amount moves the base and amount of free lines only; an invoiced line stays as it was\n', case when ok then 'PASS' else 'FAIL' end);

  -- 8. cancelling the invoice removes the free line and keeps the invoiced one
  update public.qonto_documents set status = 'Annullata' where id = d2;
  ok := (select count(*) from public.commissions where invoice_id = d2) = 1 and (select referral_id from public.commissions where invoice_id = d2) = r_a;
  failures := failures + (not ok)::int;
  report := report || format(E'%s cancelling an invoice deletes its free lines and keeps the invoiced one\n', case when ok then 'PASS' else 'FAIL' end);

  -- 9. referral changes: a new referral creates lines on that company's invoices; ending or removing it deletes the free ones, keeps the received ones
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, total_cents, vat_cents, raw, company_id, pratica_id, pratica_link_source) values
    ('t19-5', 'invoice', 'D5', 'unpaid', 'Emessa', date '2027-04-01', date '2027-05-01', 122000, 22000, '{}', cy, prat_y, 'zite'),
    ('t19-5b', 'invoice', 'D5b', 'unpaid', 'Emessa', date '2027-04-02', date '2027-05-02', 122000, 22000, '{}', cy, prat_y, 'zite');
  select id into d5 from public.qonto_documents where qonto_id = 't19-5';
  select count(*) into k from public.commissions where invoice_id in (select id from public.qonto_documents where qonto_id in ('t19-5', 't19-5b'));
  perform private.sync_referrals(jsonb_build_array(
    jsonb_build_object('id', r_c, 'zite_segnalatore_id', 't19-a', 'zite_azienda_id', 't19-y', 'commission_pct', 7, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', false)));
  select count(*) into n from public.commissions where referral_id = r_c;
  update public.commissions set paid_on = date '2027-06-01' where invoice_id = d5 and referral_id = r_c;   -- received
  perform private.sync_referrals(jsonb_build_array(
    jsonb_build_object('id', r_c, 'zite_segnalatore_id', 't19-a', 'zite_azienda_id', 't19-y', 'commission_pct', 7, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', true)));
  ok := k = 0 and n = 2 and (select count(*) from public.commissions where referral_id = r_c) = 1 and (select paid_on from public.commissions where referral_id = r_c) is not null;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a new referral gives lines to that company''s invoices (%s); removing it deletes the free line and keeps the received one\n', case when ok then 'PASS' else 'FAIL' end, n);

  -- 10. a failing rebuild is logged and the invoice still saves (percentage above 100 breaks the table check)
  perform private.sync_referrals(jsonb_build_array(
    jsonb_build_object('id', r_d, 'zite_segnalatore_id', 't19-b', 'zite_azienda_id', 't19-z', 'commission_pct', 150, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', false)));
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, total_cents, vat_cents, raw, company_id, pratica_id, pratica_link_source) values
    ('t19-6', 'invoice', 'D6', 'unpaid', 'Emessa', date '2027-04-03', date '2027-05-03', 122000, 22000, '{}', cz, prat_z, 'zite');
  select id into d6 from public.qonto_documents where qonto_id = 't19-6';
  ok := d6 is not null and (select count(*) from public.commissions where invoice_id = d6) = 0
        and (select count(*) from public.commission_rebuild_errors where invoice_id = d6) >= 1
        and (select sqlstate from public.commission_rebuild_errors where invoice_id = d6 order by created_at limit 1) = '23514';
  failures := failures + (not ok)::int;
  report := report || format(E'%s an error in a rebuild (percentage 150) is logged in commission_rebuild_errors and the invoice and the referral still save\n', case when ok then 'PASS' else 'FAIL' end);

  -- 11. structure
  ok := (select count(*) from pg_trigger where tgrelid = 'public.qonto_documents'::regclass and tgname like 'qonto_documents_rebuild_commissions%' and not tgisinternal) = 2
        and (select count(*) from pg_trigger where tgrelid = 'public.referrals'::regclass and tgname = 'referrals_rebuild_commissions' and not tgisinternal) = 1
        and not exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
                         where s.nspname in ('private', 'public') and p.proname in ('rebuild_commissions', 'rebuild_commissions_safe', 'commissions_after_document', 'commissions_after_referral', 'rebuild_all_commissions')
                           and not (coalesce(p.proconfig, '{}') @> array['search_path=""']))
        and not has_function_privilege('authenticated', 'private.rebuild_commissions(uuid)', 'execute')
        and has_function_privilege('authenticated', 'public.rebuild_all_commissions()', 'execute') and not has_function_privilege('anon', 'public.rebuild_all_commissions()', 'execute');
  failures := failures + (not ok)::int;
  report := report || format(E'%s triggers on invoices (insert, relevant update) and referrals; every function has a fixed search path; the private ones are not callable from outside; the repair is for signed-in callers only\n', case when ok then 'PASS' else 'FAIL' end);

  -- 12. who can run the repair
  k := 0;
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.rebuild_all_commissions(); exception when insufficient_privilege then k := k + 1; end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', u_part, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.rebuild_all_commissions(); exception when insufficient_privilege then k := k + 1; end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  res := public.rebuild_all_commissions();
  reset role;
  ok := k = 2 and (res->>'invoices')::int >= 6;
  failures := failures + (not ok)::int;
  report := report || format(E'%s the repair refuses a manager and a segnalatore and runs for an administrator (%s)\n', case when ok then 'PASS' else 'FAIL' end, res::text);

  raise exception E'TEST REPORT (019 commission rebuild): % failure(s)\n%', failures, report;
end $$;
