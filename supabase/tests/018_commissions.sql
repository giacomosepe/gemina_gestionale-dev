-- Commissions table and stages (migration commissions, PRDDISC-16): the four stages, the rules (no line for a credit note, a cancelled or removed invoice,
-- or another partner's referral), half-up rounding, frozen percentage, unique line, and who can read. Same pattern as 001-017: one DO block, everything
-- rolled back by the final RAISE. Made-up rows only (2027 dates, own companies and partners).

do $$
declare
  org uuid := (select id from public.organizations limit 1);
  u_p uuid := gen_random_uuid(); u_staff uuid := gen_random_uuid(); u_client uuid := gen_random_uuid();
  pa uuid; pb uuid; cx uuid; cy uuid; cclient uuid;
  r_a uuid := gen_random_uuid(); r_b uuid := gen_random_uuid(); r_c uuid := gen_random_uuid();
  d_unpaid uuid; d_paid uuid; d_cancel uuid; d_credit uuid; d_gone uuid; d_inv uuid; d_rec uuid; d_blank uuid; d_half uuid;
  n int; v text; k int;
  report text := ''; failures int := 0; ok boolean;
  r record;
  v_base bigint; v_pct numeric; sample_ok boolean := true;
begin
  insert into auth.users (id, email, aud, role) values
    (u_p, 't18-p@example.test', 'authenticated', 'authenticated'), (u_staff, 't18-staff@example.test', 'authenticated', 'authenticated'),
    (u_client, 't18-client@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'partner' where id = u_p;
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't18-zite-staff' where id = u_staff;
  update public.profiles set role = 'client' where id = u_client;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t18-a', 'T18 A', 't18-p@example.test', org) returning id into pa;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t18-b', 'T18 B', 't18-b@example.test', org) returning id into pb;
  insert into public.partner_members (partner_id, profile_id) values (pa, u_p);
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T18 X', 't18-x', org) returning id into cx;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T18 Y', 't18-y', org) returning id into cy;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T18 client', 't18-client', org) returning id into cclient;
  insert into public.company_members (company_id, profile_id) values (cclient, u_client);
  perform private.sync_referrals(jsonb_build_array(
    jsonb_build_object('id', r_a, 'zite_segnalatore_id', 't18-a', 'zite_azienda_id', 't18-x', 'commission_pct', 5, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', false),
    jsonb_build_object('id', r_b, 'zite_segnalatore_id', 't18-b', 'zite_azienda_id', 't18-x', 'commission_pct', 10, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', false),
    jsonb_build_object('id', r_c, 'zite_segnalatore_id', 't18-a', 'zite_azienda_id', 't18-y', 'commission_pct', 5, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', false)));

  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, paid_at, total_cents, vat_cents, raw, company_id, removed_at) values
    ('t18-unpaid', 'invoice', 'U1', 'unpaid',   'Emessa',    date '2027-02-10', date '2027-03-10', null,              122000, 22000, '{}', cx, null),
    ('t18-paid',   'invoice', 'P1', 'paid',     'Incassata', date '2027-02-11', date '2027-03-11', date '2027-03-01', 122000, 22000, '{}', cx, null),
    ('t18-cancel', 'invoice', 'C1', 'canceled', 'Annullata', date '2027-02-12', date '2027-03-12', null,              122000, 22000, '{}', cx, null),
    ('t18-credit', 'credit_note', 'N1', 'credit_note', 'Incassata', date '2027-02-13', date '2027-02-13', null,       -12200, -2200, '{}', cx, null),
    ('t18-gone',   'invoice', 'G1', 'paid',     'Incassata', date '2027-02-14', date '2027-03-14', date '2027-03-02', 122000, 22000, '{}', cx, now()),
    ('t18-inv',    'invoice', 'I1', 'paid',     'Incassata', date '2027-02-15', date '2027-03-15', date '2027-03-03', 122000, 22000, '{}', cx, null),
    ('t18-rec',    'invoice', 'R1', 'paid',     'Incassata', date '2027-02-16', date '2027-03-16', date '2027-03-04', 122000, 22000, '{}', cx, null),
    ('t18-blank',  'invoice', 'B1', 'paid',     'Incassata', date '2027-02-17', date '2027-03-17', date '2027-03-05', 122000, 22000, '{}', cx, null),
    ('t18-half',   'invoice', 'H1', 'unpaid',   'Emessa',    date '2027-02-18', date '2027-03-18', null,              123210, 22210, '{}', cx, null);
  select id into d_unpaid from public.qonto_documents where qonto_id = 't18-unpaid';
  select id into d_paid   from public.qonto_documents where qonto_id = 't18-paid';
  select id into d_cancel from public.qonto_documents where qonto_id = 't18-cancel';
  select id into d_credit from public.qonto_documents where qonto_id = 't18-credit';
  select id into d_gone   from public.qonto_documents where qonto_id = 't18-gone';
  select id into d_inv    from public.qonto_documents where qonto_id = 't18-inv';
  select id into d_rec    from public.qonto_documents where qonto_id = 't18-rec';
  select id into d_blank  from public.qonto_documents where qonto_id = 't18-blank';
  select id into d_half   from public.qonto_documents where qonto_id = 't18-half';

  -- stages: one line per case
  insert into public.commissions (invoice_id, referral_id, partner_id, pct, base_cents, amount_cents, partner_invoice_number, partner_invoiced_on, paid_on) values
    (d_unpaid, r_a, pa, 5, 100000, 5000, null, null, null),
    (d_paid,   r_a, pa, 5, 100000, 5000, null, null, null),
    (d_inv,    r_a, pa, 5, 100000, 5000, 'FS-1', date '2027-03-20', null),
    (d_rec,    r_a, pa, 5, 100000, 5000, 'FS-2', date '2027-03-20', date '2027-04-01'),
    (d_blank,  r_a, pa, 5, 100000, 5000, '   ', null, null),
    (d_paid,   r_b, pb, 10, 100000, 10000, null, null, null);
  ok := (select stage from public.commission_stages_v where invoice_id = d_unpaid) = 'Provvigioni teoriche'
    and (select stage from public.commission_stages_v where invoice_id = d_paid and referral_id = r_a) = 'Provvigioni maturate'
    and (select stage from public.commission_stages_v where invoice_id = d_inv) = 'Provvigioni fatturate'
    and (select stage from public.commission_stages_v where invoice_id = d_rec) = 'Provvigioni ricevute'
    and (select stage from public.commission_stages_v where invoice_id = d_blank) = 'Provvigioni maturate'
    and (select stage_order from public.commission_stages_v where invoice_id = d_rec) = 4
    and (select stage_order from public.commission_stages_v where invoice_id = d_unpaid) = 1;
  failures := failures + (not ok)::int;
  report := report || format(E'%s stages: unpaid invoice = teoriche, paid = maturate, partner invoice number = fatturate, paid_on = ricevute (wins over the rest), blank number does not count\n', case when ok then 'PASS' else 'FAIL' end);

  -- the invoice paying moves the stage with no change on the line
  update public.qonto_documents set status = 'Incassata', paid_at = date '2027-03-09' where id = d_unpaid;
  ok := (select stage from public.commission_stages_v where invoice_id = d_unpaid) = 'Provvigioni maturate';
  failures := failures + (not ok)::int;
  report := report || format(E'%s a teoriche line becomes maturate by itself when its invoice is paid\n', case when ok then 'PASS' else 'FAIL' end);

  -- no line for a credit note, a cancelled or a removed invoice, nor for another partner's referral
  k := 0;
  begin insert into public.commissions (invoice_id, referral_id, partner_id, pct, base_cents, amount_cents) values (d_credit, r_a, pa, 5, 0, 0); exception when check_violation then k := k + 1; end;
  begin insert into public.commissions (invoice_id, referral_id, partner_id, pct, base_cents, amount_cents) values (d_cancel, r_a, pa, 5, 100000, 5000); exception when check_violation then k := k + 1; end;
  begin insert into public.commissions (invoice_id, referral_id, partner_id, pct, base_cents, amount_cents) values (d_gone, r_a, pa, 5, 100000, 5000); exception when check_violation then k := k + 1; end;
  begin insert into public.commissions (invoice_id, referral_id, partner_id, pct, base_cents, amount_cents) values (d_half, r_a, pb, 5, 100000, 5000); exception when check_violation then k := k + 1; end;
  begin insert into public.commissions (invoice_id, referral_id, partner_id, pct, base_cents, amount_cents) values (d_half, r_a, pa, 5, -100, -5); exception when check_violation then k := k + 1; end;
  begin insert into public.commissions (invoice_id, referral_id, partner_id, pct, base_cents, amount_cents) values (d_half, r_c, pa, 5, 100000, 5000); exception when check_violation then k := k + 1; end;
  ok := k = 6;
  failures := failures + (not ok)::int;
  report := report || format(E'%s refused: credit note, cancelled invoice, removed invoice, partner that is not the referral''s, negative base, referral of another company (%s of 6)\n', case when ok then 'PASS' else 'FAIL' end, k);

  -- rounding: half a cent goes up; the table refuses any other amount
  insert into public.commissions (invoice_id, referral_id, partner_id, pct, base_cents, amount_cents) values (d_half, r_a, pa, 5, 1010, 51);  -- 50.5 cents -> 51
  k := 0;
  begin insert into public.commissions (invoice_id, referral_id, partner_id, pct, base_cents, amount_cents) values (d_half, r_b, pb, 5, 1010, 50); exception when check_violation then k := k + 1; end;
  begin insert into public.commissions (invoice_id, referral_id, partner_id, pct, base_cents, amount_cents) values (d_half, r_b, pb, 5, 1010, 52); exception when check_violation then k := k + 1; end;
  -- same as Zite round2 on euros (Math.round(x * 100) / 100) for a spread of bases and percentages
  for v_base in select g from generate_series(1, 200000, 997) g loop
    foreach v_pct in array array[0, 1, 2.5, 5, 7.5, 10, 12.5, 15, 20, 33.33, 50, 100]::numeric[] loop
      if floor(v_base * v_pct / 100 + 0.5) <> round(((v_base / 100.0) * v_pct / 100.0) * 100) then sample_ok := false; end if;
    end loop;
  end loop;
  ok := k = 2 and sample_ok and (select amount_cents from public.commissions where invoice_id = d_half and referral_id = r_a) = 51;
  failures := failures + (not ok)::int;
  report := report || format(E'%s rounding: 1010 cents x 5%% = 50.5 -> 51; 50 and 52 are refused; %s over 2,400 samples\n', case when ok then 'PASS' else 'FAIL' end, case when sample_ok then 'equals Zite round2' else 'DIFFERS from Zite round2' end);

  -- unique line, frozen percentage, base may follow
  k := 0;
  begin insert into public.commissions (invoice_id, referral_id, partner_id, pct, base_cents, amount_cents) values (d_paid, r_a, pa, 5, 100000, 5000); exception when unique_violation then k := k + 1; end;
  begin update public.commissions set pct = 6, amount_cents = 6000 where invoice_id = d_paid and referral_id = r_a; exception when check_violation then k := k + 1; end;
  begin update public.commissions set invoice_id = d_unpaid where invoice_id = d_paid and referral_id = r_a; exception when check_violation then k := k + 1; end;
  begin update public.commissions set base_cents = 200000, amount_cents = 10000 where invoice_id = d_rec and referral_id = r_a; exception when check_violation then k := k + 1; end;
  update public.commissions set base_cents = 120000, amount_cents = 6000 where invoice_id = d_paid and referral_id = r_a;
  ok := k = 4 and (select pct from public.commissions where invoice_id = d_paid and referral_id = r_a) = 5
        and (select amount_cents from public.commissions where invoice_id = d_paid and referral_id = r_a) = 6000;
  failures := failures + (not ok)::int;
  report := report || format(E'%s one line per invoice and referral; the percentage and the links are frozen (%s of 4 refused, one of them a base change on a received line); the base and amount may follow a corrected invoice until the line is received\n', case when ok then 'PASS' else 'FAIL' end, k);

  -- structure and access
  ok := (select relrowsecurity from pg_class where oid = 'public.commissions'::regclass)
        and (select count(*) from pg_policies where tablename = 'commissions') = 1
        and not has_table_privilege('authenticated', 'public.commissions', 'insert') and not has_table_privilege('authenticated', 'public.commissions', 'update')
        and not has_table_privilege('authenticated', 'public.commissions', 'delete') and not has_table_privilege('anon', 'public.commissions', 'select')
        and not has_table_privilege('anon', 'public.commission_stages_v', 'select')
        and (select reloptions::text like '%security_invoker=true%' from pg_class where oid = 'public.commission_stages_v'::regclass);
  failures := failures + (not ok)::int;
  report := report || format(E'%s RLS on, one staff-only policy, no write for signed-in users, no anonymous read, the view is security_invoker\n', case when ok then 'PASS' else 'FAIL' end);

  -- partner, client: no rows; staff: all
  perform set_config('request.jwt.claims', json_build_object('sub', u_p, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select (select count(*) from public.commissions), (select count(*) from public.commission_stages_v) into n, k;
  reset role;
  ok := n = 0 and k = 0;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalatore login reads zero commission lines (table %s, view %s)\n', case when ok then 'PASS' else 'FAIL' end, n, k);

  perform set_config('request.jwt.claims', json_build_object('sub', u_client, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select (select count(*) from public.commissions), (select count(*) from public.commission_stages_v) into n, k;
  reset role;
  ok := n = 0 and k = 0;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a client login reads zero commission lines\n', case when ok then 'PASS' else 'FAIL' end);

  perform set_config('request.jwt.claims', json_build_object('sub', u_staff, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select (select count(*) from public.commissions where invoice_id in (d_unpaid, d_paid, d_inv, d_rec, d_blank, d_half)), (select count(*) from public.commission_stages_v where invoice_id in (d_unpaid, d_paid, d_inv, d_rec, d_blank, d_half)) into n, k;
  reset role;
  ok := n = 7 and k = 7;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff reads every line (table %s, view %s)\n', case when ok then 'PASS' else 'FAIL' end, n, k);

  raise exception E'TEST REPORT (018 commissions): % failure(s)\n%', failures, report;
end $$;
