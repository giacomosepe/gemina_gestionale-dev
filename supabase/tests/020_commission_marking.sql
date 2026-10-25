-- Mark commissions invoiced and paid (migration commission_marking, PRDDISC-21): the stage checks, all-or-none, who may call, the answers. Same pattern as
-- 001-019: one DO block, everything rolled back by the final RAISE. Made-up rows only. (Number 020: 019 is the commission rebuild test of PRDDISC-20.)
-- The lines are inserted directly, so the test does not depend on the rebuild triggers: the invoices have no pratica, so a rebuild would leave them alone.

do $$
declare
  org uuid := (select id from public.organizations limit 1);
  u_mgr uuid := gen_random_uuid(); u_part uuid := gen_random_uuid(); u_client uuid := gen_random_uuid();
  pa uuid; cx uuid; cclient uuid;
  rf uuid := gen_random_uuid();
  di_theo uuid; di_mat uuid; di_mat2 uuid; di_inv uuid; di_rec uuid;
  l_theo uuid; l_mat uuid; l_mat2 uuid; l_inv uuid; l_rec uuid;
  k int; n int; res record; ok boolean; v text;
  report text := ''; failures int := 0;
begin
  insert into auth.users (id, email, aud, role) values
    (u_mgr, 't20-mgr@example.test', 'authenticated', 'authenticated'), (u_part, 't20-part@example.test', 'authenticated', 'authenticated'),
    (u_client, 't20-client@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't20-z-mgr' where id = u_mgr;
  update public.profiles set role = 'partner' where id = u_part;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t20-a', 'T20 A', 't20-part@example.test', org) returning id into pa;
  insert into public.partner_members (partner_id, profile_id) values (pa, u_part);
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T20 X', 't20-x', org) returning id into cx;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T20 client', 't20-client', org) returning id into cclient;
  insert into public.company_members (company_id, profile_id) values (cclient, u_client);
  update public.profiles set role = 'client' where id = u_client;

  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, paid_at, total_cents, vat_cents, raw, company_id, pratica_link_source) values
    ('t20-theo', 'invoice', 'T1', 'unpaid', 'Emessa',    date '2027-02-01', date '2027-03-01', null,              122000, 22000, '{}', cx, 'manual'),
    ('t20-mat',  'invoice', 'T2', 'paid',   'Incassata', date '2027-02-02', date '2027-03-02', date '2027-02-20', 122000, 22000, '{}', cx, 'manual'),
    ('t20-mat2', 'invoice', 'T3', 'paid',   'Incassata', date '2027-02-03', date '2027-03-03', date '2027-02-21', 122000, 22000, '{}', cx, 'manual'),
    ('t20-inv',  'invoice', 'T4', 'paid',   'Incassata', date '2027-02-04', date '2027-03-04', date '2027-02-22', 122000, 22000, '{}', cx, 'manual'),
    ('t20-rec',  'invoice', 'T5', 'paid',   'Incassata', date '2027-02-05', date '2027-03-05', date '2027-02-23', 122000, 22000, '{}', cx, 'manual');
  select id into di_theo from public.qonto_documents where qonto_id = 't20-theo';
  select id into di_mat  from public.qonto_documents where qonto_id = 't20-mat';
  select id into di_mat2 from public.qonto_documents where qonto_id = 't20-mat2';
  select id into di_inv  from public.qonto_documents where qonto_id = 't20-inv';
  select id into di_rec  from public.qonto_documents where qonto_id = 't20-rec';
  perform private.sync_referrals(jsonb_build_array(
    jsonb_build_object('id', rf, 'zite_segnalatore_id', 't20-a', 'zite_azienda_id', 't20-x', 'commission_pct', 10, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', false)));
  insert into public.commissions (invoice_id, referral_id, partner_id, pct, base_cents, amount_cents, partner_invoice_number, partner_invoiced_on, paid_on) values
    (di_theo, rf, pa, 10, 100000, 10000, null, null, null),
    (di_mat,  rf, pa, 10, 100000, 10000, null, null, null),
    (di_mat2, rf, pa, 10, 100000, 10000, null, null, null),
    (di_inv,  rf, pa, 10, 100000, 10000, 'FS-9', date '2027-03-10', null),
    (di_rec,  rf, pa, 10, 100000, 10000, 'FS-8', date '2027-03-10', date '2027-04-01');
  select id into l_theo from public.commissions where invoice_id = di_theo;
  select id into l_mat  from public.commissions where invoice_id = di_mat;
  select id into l_mat2 from public.commissions where invoice_id = di_mat2;
  select id into l_inv  from public.commissions where invoice_id = di_inv;
  select id into l_rec  from public.commissions where invoice_id = di_rec;

  -- as a team member
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- 1. a matured line becomes invoiced; the answer is the line with its new stage
  select * into res from public.mark_commissions_invoiced(array[l_mat, l_mat], '  FS-1  ', date '2027-03-15');
  get diagnostics n = row_count;
  ok := n = 1 and res.id = l_mat and res.stage = 'Provvigioni fatturate' and res.partner_invoice_number = 'FS-1' and res.partner_invoiced_on = date '2027-03-15';
  failures := failures + (not ok)::int;
  report := report || format(E'%s a matured line is marked invoiced (number trimmed, repeated id counted once); the answer shows it in stage fatturate\n', case when ok then 'PASS' else 'FAIL' end);

  -- 2. refusals of the stage checks, each leaves the line as it was
  k := 0;
  begin perform public.mark_commissions_invoiced(array[l_theo], 'FS-2', date '2027-03-15'); exception when sqlstate '22023' then k := k + 1; end;
  begin perform public.mark_commissions_invoiced(array[l_inv], 'FS-2', date '2027-03-15'); exception when sqlstate '22023' then k := k + 1; end;
  begin perform public.mark_commissions_invoiced(array[l_rec], 'FS-2', date '2027-03-15'); exception when sqlstate '22023' then k := k + 1; end;
  begin perform public.mark_commissions_paid(array[l_theo], date '2027-04-02'); exception when sqlstate '22023' then k := k + 1; end;
  begin perform public.mark_commissions_paid(array[l_mat2], date '2027-04-02'); exception when sqlstate '22023' then k := k + 1; end;
  begin perform public.mark_commissions_paid(array[l_rec], date '2027-04-02'); exception when sqlstate '22023' then k := k + 1; end;
  ok := k = 6 and (select partner_invoice_number is null from public.commissions where id = l_theo)
        and (select partner_invoice_number = 'FS-9' from public.commissions where id = l_inv) and (select paid_on = date '2027-04-01' from public.commissions where id = l_rec)
        and (select paid_on is null from public.commissions where id = l_mat2 and partner_invoice_number is null);
  failures := failures + (not ok)::int;
  report := report || format(E'%s refused: invoiced on a theoretical, an invoiced or a received line; paid on a theoretical, a matured or a received line (%s of 6); nothing changed\n', case when ok then 'PASS' else 'FAIL' end, k);

  -- 3. an invoiced line is marked paid
  select * into res from public.mark_commissions_paid(array[l_inv], date '2027-04-05');
  ok := res.id = l_inv and res.stage = 'Provvigioni ricevute' and res.paid_on = date '2027-04-05';
  failures := failures + (not ok)::int;
  report := report || format(E'%s an invoiced line is marked paid; the answer shows stage ricevute\n', case when ok then 'PASS' else 'FAIL' end);

  -- 4. a mixed batch with one invalid line changes nothing
  k := 0;
  begin perform public.mark_commissions_invoiced(array[l_mat2, l_theo], 'FS-3', date '2027-03-16'); exception when sqlstate '22023' then k := 1; end;
  begin perform public.mark_commissions_paid(array[l_mat, l_mat2], date '2027-04-06'); exception when sqlstate '22023' then k := k + 1; end;
  ok := k = 2 and (select partner_invoice_number is null from public.commissions where id = l_mat2)
        and (select paid_on is null from public.commissions where id = l_mat) and (select partner_invoice_number = 'FS-1' from public.commissions where id = l_mat);
  failures := failures + (not ok)::int;
  report := report || format(E'%s a batch with one invalid line is refused as a whole: the valid lines in it are not marked either\n', case when ok then 'PASS' else 'FAIL' end);

  -- 5. input checks: empty number, empty list, unknown line
  k := 0;
  begin perform public.mark_commissions_invoiced(array[l_mat2], '   ', date '2027-03-16'); exception when others then if sqlerrm = 'Indica il numero della fattura del segnalatore.' then k := k + 1; end if; end;
  begin perform public.mark_commissions_invoiced(array[l_mat2], null, null); exception when sqlstate '22023' then k := k + 1; end;
  begin perform public.mark_commissions_invoiced(array[]::uuid[], 'FS-4', null); exception when sqlstate '22023' then k := k + 1; end;
  begin perform public.mark_commissions_paid(null, null); exception when sqlstate '22023' then k := k + 1; end;
  begin perform public.mark_commissions_invoiced(array[gen_random_uuid()], 'FS-4', null); exception when sqlstate '22023' then k := k + 1; end;
  ok := k = 5;
  failures := failures + (not ok)::int;
  report := report || format(E'%s refused: empty invoice number (Zite''s message), no line chosen, a line that does not exist (%s of 5)\n', case when ok then 'PASS' else 'FAIL' end, k);

  -- 6. the date: invoiced may have none; paid defaults to today in Rome
  select * into res from public.mark_commissions_invoiced(array[l_mat2], 'FS-5', null);
  ok := res.partner_invoiced_on is null and res.stage = 'Provvigioni fatturate';
  select * into res from public.mark_commissions_paid(array[l_mat2]);
  ok := ok and res.paid_on = (now() at time zone 'Europe/Rome')::date and res.stage = 'Provvigioni ricevute';
  failures := failures + (not ok)::int;
  report := report || format(E'%s invoice date can be empty; payment date defaults to today (Rome)\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  -- 7. a segnalatore, a client and an anonymous caller are refused
  k := 0;
  perform set_config('request.jwt.claims', json_build_object('sub', u_part, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.mark_commissions_invoiced(array[l_theo], 'X', null); exception when insufficient_privilege then k := k + 1; end;
  begin perform public.mark_commissions_paid(array[l_theo], null); exception when insufficient_privilege then k := k + 1; end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', u_client, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.mark_commissions_invoiced(array[l_theo], 'X', null); exception when insufficient_privilege then k := k + 1; end;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  set local role anon;
  begin perform public.mark_commissions_invoiced(array[l_theo], 'X', null); exception when insufficient_privilege then k := k + 1; end;
  begin perform public.mark_commissions_paid(array[l_theo], null); exception when insufficient_privilege then k := k + 1; end;
  reset role;
  ok := k = 5;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalatore, a client and an anonymous caller are refused (%s of 5)\n', case when ok then 'PASS' else 'FAIL' end, k);

  -- 8. structure
  ok := (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('mark_commissions_invoiced', 'mark_commissions_paid')
            and p.prosecdef and coalesce(p.proconfig, '{}') @> array['search_path=""']) = 2
        and has_function_privilege('authenticated', 'public.mark_commissions_invoiced(uuid[], text, date)', 'execute')
        and has_function_privilege('authenticated', 'public.mark_commissions_paid(uuid[], date)', 'execute')
        and not has_function_privilege('anon', 'public.mark_commissions_invoiced(uuid[], text, date)', 'execute')
        and not has_function_privilege('anon', 'public.mark_commissions_paid(uuid[], date)', 'execute');
  failures := failures + (not ok)::int;
  report := report || format(E'%s both functions are security definer with a fixed search path; execute for signed-in users only\n', case when ok then 'PASS' else 'FAIL' end);

  raise exception E'TEST REPORT (020 commission marking): % failure(s)\n%', failures, report;
end $$;
