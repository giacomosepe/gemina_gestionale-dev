-- Correct a commission marking (migration commission_corrections, PRDDISC-31). One DO block, everything rolled back by the final RAISE. Made-up rows only.
-- The lines are inserted directly (like test 020), so the test does not depend on the rebuild triggers.
do $$
declare
  org uuid := (select id from public.organizations limit 1);
  u_mgr uuid := gen_random_uuid(); u_part uuid := gen_random_uuid(); u_client uuid := gen_random_uuid();
  pa uuid; cx uuid; cclient uuid; rf uuid := gen_random_uuid();
  d_mat uuid; d_inv uuid; d_rec uuid; d_inv2 uuid;
  l_mat uuid; l_inv uuid; l_rec uuid; l_inv2 uuid;
  res record; k int; n int;
  report text := ''; failures int := 0; ok boolean;
begin
  insert into auth.users (id, email, aud, role) values
    (u_mgr, 't24-mgr@example.test', 'authenticated', 'authenticated'), (u_part, 't24-part@example.test', 'authenticated', 'authenticated'),
    (u_client, 't24-client@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't24-z-mgr' where id = u_mgr;
  update public.profiles set role = 'partner' where id = u_part;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t24-a', 'T24 A', 't24-part@example.test', org) returning id into pa;
  insert into public.partner_members (partner_id, profile_id) values (pa, u_part);
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T24 X', 't24-x', org) returning id into cx;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T24 client', 't24-client', org) returning id into cclient;
  insert into public.company_members (company_id, profile_id) values (cclient, u_client);
  update public.profiles set role = 'client' where id = u_client;
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, paid_at, total_cents, vat_cents, raw, company_id, pratica_link_source) values
    ('t24-mat',  'invoice', 'C1', 'paid', 'Incassata', date '2027-02-02', date '2027-03-02', date '2027-02-20', 122000, 22000, '{}', cx, 'manual'),
    ('t24-inv',  'invoice', 'C2', 'paid', 'Incassata', date '2027-02-03', date '2027-03-03', date '2027-02-21', 122000, 22000, '{}', cx, 'manual'),
    ('t24-rec',  'invoice', 'C3', 'paid', 'Incassata', date '2027-02-04', date '2027-03-04', date '2027-02-22', 122000, 22000, '{}', cx, 'manual'),
    ('t24-inv2', 'invoice', 'C4', 'paid', 'Incassata', date '2027-02-05', date '2027-03-05', date '2027-02-23', 122000, 22000, '{}', cx, 'manual');
  select id into d_mat from public.qonto_documents where qonto_id = 't24-mat';
  select id into d_inv from public.qonto_documents where qonto_id = 't24-inv';
  select id into d_rec from public.qonto_documents where qonto_id = 't24-rec';
  select id into d_inv2 from public.qonto_documents where qonto_id = 't24-inv2';
  perform private.sync_referrals(jsonb_build_array(
    jsonb_build_object('id', rf, 'zite_segnalatore_id', 't24-a', 'zite_azienda_id', 't24-x', 'commission_pct', 10, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', false)));
  insert into public.commissions (invoice_id, referral_id, partner_id, pct, base_cents, amount_cents, partner_invoice_number, partner_invoiced_on, paid_on) values
    (d_mat,  rf, pa, 10, 100000, 10000, null, null, null),
    (d_inv,  rf, pa, 10, 100000, 10000, 'FS-WRONG', date '2027-03-10', null),
    (d_rec,  rf, pa, 10, 100000, 10000, 'FS-8', date '2027-03-10', date '2027-04-01'),
    (d_inv2, rf, pa, 10, 100000, 10000, 'FS-9', date '2027-03-11', null);
  select id into l_mat from public.commissions where invoice_id = d_mat;
  select id into l_inv from public.commissions where invoice_id = d_inv;
  select id into l_rec from public.commissions where invoice_id = d_rec;
  select id into l_inv2 from public.commissions where invoice_id = d_inv2;

  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- 1. wrong number corrected on an invoiced line
  select * into res from public.correct_commission_invoice(array[l_inv, l_inv], '  FS-1  ', date '2027-03-12');
  ok := res.id = l_inv and res.stage = 'Provvigioni fatturate' and res.partner_invoice_number = 'FS-1' and res.partner_invoiced_on = date '2027-03-12'
        and res.amount_cents = 10000 and res.base_cents = 100000
        and (select count(*) from public.commission_corrections where commission_id = l_inv) = 1
        and exists (select 1 from public.commission_corrections where commission_id = l_inv and action = 'correct_invoice'
                      and old_invoice_number = 'FS-WRONG' and new_invoice_number = 'FS-1' and old_invoiced_on = date '2027-03-10' and new_invoiced_on = date '2027-03-12'
                      and old_stage = 'Provvigioni fatturate' and new_stage = 'Provvigioni fatturate' and done_by = u_mgr);
  failures := failures + (not ok)::int;
  report := report || format(E'%s a wrong number is corrected on an invoiced line (trimmed, repeated id counted once); amount unchanged; one correction row with old and new, and who\n', case when ok then 'PASS' else 'FAIL' end);

  -- 2. refused on matured and received lines, and on bad input
  k := 0;
  begin perform public.correct_commission_invoice(array[l_mat], 'X', null); exception when sqlstate '22023' then k := k + 1; end;
  begin perform public.correct_commission_invoice(array[l_rec], 'X', null); exception when sqlstate '22023' then k := k + 1; end;
  begin perform public.correct_commission_invoice(array[l_inv], '   ', null); exception when sqlstate '22023' then k := k + 1; end;
  begin perform public.correct_commission_invoice(array[]::uuid[], 'X', null); exception when sqlstate '22023' then k := k + 1; end;
  begin perform public.correct_commission_invoice(array[gen_random_uuid()], 'X', null); exception when sqlstate '22023' then k := k + 1; end;
  ok := k = 5 and (select partner_invoice_number = 'FS-8' from public.commissions where id = l_rec) and (select partner_invoice_number is null from public.commissions where id = l_mat)
        and (select count(*) from public.commission_corrections) = 1;
  failures := failures + (not ok)::int;
  report := report || format(E'%s correction refused on a matured and on a received line, with an empty number, no line, an unknown line (%s of 5); nothing changed, nothing logged\n', case when ok then 'PASS' else 'FAIL' end, k);

  -- 3. paid undone, then redone
  select * into res from public.unmark_commissions_paid(array[l_rec]);
  ok := res.id = l_rec and res.stage = 'Provvigioni fatturate' and res.paid_on is null and res.partner_invoice_number = 'FS-8' and res.amount_cents = 10000
        and exists (select 1 from public.commission_corrections where commission_id = l_rec and action = 'unmark_paid' and old_paid_on = date '2027-04-01' and new_paid_on is null
                      and old_stage = 'Provvigioni ricevute' and new_stage = 'Provvigioni fatturate');
  select * into res from public.mark_commissions_paid(array[l_rec], date '2027-04-03');
  ok := ok and res.stage = 'Provvigioni ricevute' and res.paid_on = date '2027-04-03';
  failures := failures + (not ok)::int;
  report := report || format(E'%s "paid" undone (back to fatturate, number kept, logged) and marked paid again with the normal function\n', case when ok then 'PASS' else 'FAIL' end);

  -- 4. invoiced undone: refused while paid, allowed after paid is undone; then marked again
  k := 0;
  begin perform public.unmark_commissions_invoiced(array[l_rec]); exception when sqlstate '22023' then if sqlerrm like '%prima annulla il pagamento%' then k := 1; end if; end;
  ok := k = 1 and (select partner_invoice_number = 'FS-8' from public.commissions where id = l_rec);
  perform public.unmark_commissions_paid(array[l_rec]);
  select * into res from public.unmark_commissions_invoiced(array[l_rec]);
  ok := ok and res.stage = 'Provvigioni maturate' and res.partner_invoice_number is null and res.partner_invoiced_on is null
        and exists (select 1 from public.commission_corrections where commission_id = l_rec and action = 'unmark_invoiced' and old_invoice_number = 'FS-8' and new_invoice_number is null
                      and old_stage = 'Provvigioni fatturate' and new_stage = 'Provvigioni maturate');
  select * into res from public.mark_commissions_invoiced(array[l_rec], 'FS-8B', date '2027-03-20');
  ok := ok and res.stage = 'Provvigioni fatturate' and res.partner_invoice_number = 'FS-8B';
  failures := failures + (not ok)::int;
  report := report || format(E'%s "invoiced" undone: refused while the line is received (message says to undo the payment first), allowed after; back to matured, logged; can be marked again\n', case when ok then 'PASS' else 'FAIL' end);

  -- 5. other wrong stages are refused
  k := 0;
  begin perform public.unmark_commissions_paid(array[l_mat]); exception when sqlstate '22023' then k := k + 1; end;
  begin perform public.unmark_commissions_paid(array[l_inv]); exception when sqlstate '22023' then k := k + 1; end;
  begin perform public.unmark_commissions_invoiced(array[l_mat]); exception when sqlstate '22023' then k := k + 1; end;
  begin perform public.unmark_commissions_invoiced(array[]::uuid[]); exception when sqlstate '22023' then k := k + 1; end;
  ok := k = 4;
  failures := failures + (not ok)::int;
  report := report || format(E'%s undo refused on lines that are not in the right stage and with no line chosen (%s of 4)\n', case when ok then 'PASS' else 'FAIL' end, k);

  -- 6. a call with one bad line changes nothing and logs nothing
  select count(*) into n from public.commission_corrections;
  k := 0;
  begin perform public.correct_commission_invoice(array[l_inv, l_inv2, l_mat], 'FS-BATCH', null); exception when sqlstate '22023' then k := 1; end;
  begin perform public.unmark_commissions_invoiced(array[l_inv, l_inv2, l_mat]); exception when sqlstate '22023' then k := k + 1; end;
  ok := k = 2 and (select partner_invoice_number = 'FS-1' from public.commissions where id = l_inv) and (select partner_invoice_number = 'FS-9' from public.commissions where id = l_inv2)
        and (select count(*) from public.commission_corrections) = n;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a call with one bad line changes nothing and logs nothing (both functions)\n', case when ok then 'PASS' else 'FAIL' end);

  -- 7. one correction row per line per call
  select count(*) into n from public.commission_corrections;
  perform public.correct_commission_invoice(array[l_inv, l_inv2, l_inv2], 'FS-TWO', date '2027-03-13');
  ok := (select count(*) from public.commission_corrections) = n + 2;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a call over two lines (one repeated) leaves exactly two correction rows\n', case when ok then 'PASS' else 'FAIL' end);

  -- 8. staff read the log; direct writes are refused
  ok := (select count(*) from public.commission_corrections) > 0;
  k := 0;
  begin insert into public.commission_corrections (commission_id, action, old_stage, new_stage) values (l_inv, 'unmark_paid', 'a', 'b'); exception when insufficient_privilege then k := 1; end;
  begin delete from public.commission_corrections; exception when insufficient_privilege then k := k + 1; end;
  ok := ok and k = 2;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff read the correction log; nobody signed in can write or delete it directly\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  -- 9. a segnalatore, a client and an anonymous caller are refused; a client reads no correction rows
  k := 0;
  perform set_config('request.jwt.claims', json_build_object('sub', u_part, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.correct_commission_invoice(array[l_inv], 'X', null); exception when insufficient_privilege then k := k + 1; end;
  begin perform public.unmark_commissions_paid(array[l_rec]); exception when insufficient_privilege then k := k + 1; end;
  begin perform public.unmark_commissions_invoiced(array[l_inv]); exception when insufficient_privilege then k := k + 1; end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', u_client, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.unmark_commissions_invoiced(array[l_inv]); exception when insufficient_privilege then k := k + 1; end;
  n := (select count(*) from public.commission_corrections);
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  set local role anon;
  begin perform public.correct_commission_invoice(array[l_inv], 'X', null); exception when insufficient_privilege then k := k + 1; end;
  reset role;
  ok := k = 5 and n = 0 and (select partner_invoice_number = 'FS-TWO' from public.commissions where id = l_inv);
  failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalatore, a client and an anonymous caller are refused (%s of 5); a client reads no correction rows\n', case when ok then 'PASS' else 'FAIL' end, k);

  -- 10. amounts never changed; lines never deleted
  ok := (select count(*) from public.commissions where invoice_id in (d_mat, d_inv, d_rec, d_inv2) and amount_cents = 10000 and base_cents = 100000) = 4;
  failures := failures + (not ok)::int;
  report := report || format(E'%s all four lines still exist with their original base and amount\n', case when ok then 'PASS' else 'FAIL' end);

  -- 11. structure
  ok := (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('correct_commission_invoice', 'unmark_commissions_paid', 'unmark_commissions_invoiced')
            and p.prosecdef and coalesce(p.proconfig, '{}') @> array['search_path=""']) = 3
        and has_function_privilege('authenticated', 'public.correct_commission_invoice(uuid[], text, date)', 'execute')
        and has_function_privilege('authenticated', 'public.unmark_commissions_paid(uuid[])', 'execute')
        and has_function_privilege('authenticated', 'public.unmark_commissions_invoiced(uuid[])', 'execute')
        and not has_function_privilege('anon', 'public.correct_commission_invoice(uuid[], text, date)', 'execute')
        and not has_function_privilege('anon', 'public.unmark_commissions_paid(uuid[])', 'execute')
        and not has_function_privilege('anon', 'public.unmark_commissions_invoiced(uuid[])', 'execute')
        and not has_function_privilege('authenticated', 'private.commission_correction_lines(uuid[], text, text, text)', 'execute');
  failures := failures + (not ok)::int;
  report := report || format(E'%s the three functions are security definer with a fixed search path, signed-in users only; the helper is not callable\n', case when ok then 'PASS' else 'FAIL' end);

  raise exception E'TEST REPORT (024 commission corrections): % failure(s)\n%', failures, report;
end $$;
