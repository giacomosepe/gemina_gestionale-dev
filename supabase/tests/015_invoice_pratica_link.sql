-- Invoice to pratica link and pratica payment status (migration invoice_pratica_link, PRDDISC-12). Same pattern as 001-014: one DO block, everything
-- rolled back by the final RAISE. Made-up rows only; every pratica gets its own company so real data never mixes in.

do $$
declare
  u_s1   uuid := gen_random_uuid();
  u_ref  uuid := gen_random_uuid();
  org    uuid := (select id from public.organizations limit 1);
  p_ref  uuid;
  ca uuid; cb uuid; cc uuid; cd uuid; ce uuid;
  pa_open uuid := gen_random_uuid(); pa_closed uuid := gen_random_uuid();
  pb_1 uuid := gen_random_uuid(); pb_2 uuid := gen_random_uuid();
  pc_only uuid := gen_random_uuid();
  pe_1 uuid := gen_random_uuid();
  d1 uuid; d2 uuid; d3 uuid; d4 uuid; d5 uuid; d6 uuid;
  r record;
  n int;
  report text := '';
  failures int := 0;
  ok boolean;
  v text;

  -- pratiche for the payment states
  s1 uuid := gen_random_uuid(); s2 uuid := gen_random_uuid(); s3 uuid := gen_random_uuid(); s4 uuid := gen_random_uuid();
  s5 uuid := gen_random_uuid(); s6 uuid := gen_random_uuid(); s7 uuid := gen_random_uuid(); s8 uuid := gen_random_uuid();
  s9 uuid := gen_random_uuid(); s10 uuid := gen_random_uuid(); s11 uuid := gen_random_uuid();
  cs uuid;
  k int := 0;
  sid uuid;
begin
  insert into auth.users (id, email, aud, role) values
    (u_s1,  't15-s1@example.test',  'authenticated', 'authenticated'),
    (u_ref, 't15-ref@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't15-zite-s1' where id = u_s1;
  update public.profiles set role = 'partner' where id = u_ref;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t15-ref', 'Test referrer 15', 't15-ref@example.test', org) returning id into p_ref;
  insert into public.partner_members (partner_id, profile_id) values (p_ref, u_ref);

  ok := (select count(*) from pg_class c join pg_namespace s on s.oid = c.relnamespace
          where s.nspname = 'public' and c.relname in ('pratica_payment_status_v', 'review_invoices_v') and 'security_invoker=true' = any(c.reloptions)) = 2
        and private.fully_paid_tolerance_cents() = 1000;
  failures := failures + (not ok)::int;
  report := report || format(E'%s both views are security_invoker; the tolerance setting is 1000 cents\n', case when ok then 'PASS' else 'FAIL' end);

  ---------------------------------------------------------------- the link rule
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T15 A', 't15-a', org) returning id into ca;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T15 B', 't15-b', org) returning id into cb;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T15 C', 't15-c', org) returning id into cc;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T15 D', 't15-d', org) returning id into cd;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T15 E', 't15-e', org) returning id into ce;
  -- A: one open + one closed; B: two open; C: only one closed; D: none; E: later
  perform private.sync_pratiche(jsonb_build_array(
    jsonb_build_object('id', pa_open,   'code', 'T15-A1', 'zite_azienda_id', 't15-a', 'status', 'In lavorazione', 'is_open', true,  'total_fee_cents', 100000, 'removed', false),
    jsonb_build_object('id', pa_closed, 'code', 'T15-A2', 'zite_azienda_id', 't15-a', 'status', 'Fatturazione completata', 'is_open', false, 'total_fee_cents', 100000, 'removed', false),
    jsonb_build_object('id', pb_1,      'code', 'T15-B1', 'zite_azienda_id', 't15-b', 'status', 'In lavorazione', 'is_open', true,  'total_fee_cents', 100000, 'removed', false),
    jsonb_build_object('id', pb_2,      'code', 'T15-B2', 'zite_azienda_id', 't15-b', 'status', 'In lavorazione', 'is_open', true,  'total_fee_cents', 100000, 'removed', false),
    jsonb_build_object('id', pc_only,   'code', 'T15-C1', 'zite_azienda_id', 't15-c', 'status', 'Interrotta', 'is_open', false, 'total_fee_cents', 100000, 'removed', false)));

  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, total_cents, vat_cents, raw, company_id) values
    ('t15-da', 'invoice', 'T15-1', 'unpaid', 'Emessa', date '2027-01-10', 122000, 22000, '{}', ca),
    ('t15-db', 'invoice', 'T15-2', 'unpaid', 'Emessa', date '2027-01-11', 122000, 22000, '{}', cb),
    ('t15-dc', 'invoice', 'T15-3', 'unpaid', 'Emessa', date '2027-01-12', 122000, 22000, '{}', cc),
    ('t15-dd', 'invoice', 'T15-4', 'unpaid', 'Emessa', date '2027-01-13', 122000, 22000, '{}', cd),
    ('t15-dn', 'invoice', 'T15-5', 'unpaid', 'Emessa', date '2027-01-14', 122000, 22000, '{}', null),
    ('t15-dx', 'invoice', 'T15-6', 'canceled', 'Annullata', date '2027-01-15', 122000, 22000, '{}', cb);
  ok := (select pratica_id = pa_open and pratica_link_source = 'auto' and zite_pratica_id = pa_open::text from public.qonto_documents where qonto_id = 't15-da');
  failures := failures + (not ok)::int;
  report := report || format(E'%s one open pratica (and one closed): linked to the open one\n', case when ok then 'PASS' else 'FAIL' end);
  ok := (select pratica_id is null and pratica_link_source is null from public.qonto_documents where qonto_id = 't15-db');
  failures := failures + (not ok)::int;
  report := report || format(E'%s two open pratiche: left unlinked\n', case when ok then 'PASS' else 'FAIL' end);
  ok := (select pratica_id = pc_only from public.qonto_documents where qonto_id = 't15-dc');
  failures := failures + (not ok)::int;
  report := report || format(E'%s no open pratica but exactly one in total: linked to it\n', case when ok then 'PASS' else 'FAIL' end);
  ok := (select count(*) from public.qonto_documents where qonto_id in ('t15-dd', 't15-dn', 't15-dx') and pratica_id is null) = 3;
  failures := failures + (not ok)::int;
  report := report || format(E'%s no pratica / unknown company / cancelled: unlinked\n', case when ok then 'PASS' else 'FAIL' end);

  -- a pratica arrives later: the waiting invoice is linked by the next sync
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, total_cents, vat_cents, raw, company_id)
    values ('t15-de', 'invoice', 'T15-7', 'unpaid', 'Emessa', date '2027-01-16', 122000, 22000, '{}', ce);
  ok := (select pratica_id is null from public.qonto_documents where qonto_id = 't15-de');
  perform private.sync_pratiche(jsonb_build_array(
    jsonb_build_object('id', pe_1, 'code', 'T15-E1', 'zite_azienda_id', 't15-e', 'status', 'In lavorazione', 'is_open', true, 'total_fee_cents', 100000, 'removed', false)));
  ok := ok and (select pratica_id = pe_1 and pratica_link_source = 'auto' from public.qonto_documents where qonto_id = 't15-de');
  failures := failures + (not ok)::int;
  report := report || format(E'%s an invoice waiting for its pratica is linked when the pratica arrives\n', case when ok then 'PASS' else 'FAIL' end);

  -- an existing link is never changed by the rule (a second open pratica appears for A)
  perform private.sync_pratiche(jsonb_build_array(
    jsonb_build_object('id', gen_random_uuid(), 'code', 'T15-A3', 'zite_azienda_id', 't15-a', 'status', 'In lavorazione', 'is_open', true, 'total_fee_cents', 100000, 'removed', false)));
  ok := (select pratica_id = pa_open from public.qonto_documents where qonto_id = 't15-da');
  failures := failures + (not ok)::int;
  report := report || format(E'%s an existing link is not recomputed when another pratica appears\n', case when ok then 'PASS' else 'FAIL' end);

  -- review list
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  ok := (select reason_code from public.review_invoices_v where qonto_id = 't15-db') = 'ambiguous'
        and (select reason_code from public.review_invoices_v where qonto_id = 't15-dd') = 'no_pratica'
        and (select reason_code from public.review_invoices_v where qonto_id = 't15-dn') = 'company_unknown'
        and not exists (select 1 from public.review_invoices_v where qonto_id in ('t15-da', 't15-dc', 't15-de', 't15-dx'));
  failures := failures + (not ok)::int;
  report := report || format(E'%s the review list: ambiguous, no pratica, company unknown; linked and cancelled ones are not listed\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  -- manual link overrides and is never overwritten; unlinking on purpose stays
  select id into d2 from public.qonto_documents where qonto_id = 't15-db';
  perform private.set_invoice_pratica(d2, pb_2);
  perform private.sync_pratiche(jsonb_build_array(
    jsonb_build_object('id', gen_random_uuid(), 'code', 'T15-B3', 'zite_azienda_id', 't15-b', 'status', 'Interrotta', 'is_open', false, 'total_fee_cents', 100000, 'removed', false)));
  ok := (select pratica_id = pb_2 and pratica_link_source = 'manual' from public.qonto_documents where id = d2);
  select id into d1 from public.qonto_documents where qonto_id = 't15-da';
  perform private.set_invoice_pratica(d1, pa_closed);   -- staff overrides the rule
  update public.qonto_documents set synced_at = now() where id in (d1, d2);  -- a sync touching the rows
  ok := ok and (select pratica_id = pa_closed and pratica_link_source = 'manual' from public.qonto_documents where id = d1);
  perform private.set_invoice_pratica(d1, null);
  perform private.link_invoices_to_pratiche();
  ok := ok and (select pratica_id is null and pratica_link_source = 'manual' from public.qonto_documents where id = d1)
           and not exists (select 1 from public.review_invoices_v where id = d1);
  failures := failures + (not ok)::int;
  report := report || format(E'%s a manual link overrides the rule and survives; unlinked on purpose stays unlinked and leaves the review list\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    perform private.set_invoice_pratica(d2, gen_random_uuid());
    ok := false;
  exception when foreign_key_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s linking to a pratica that does not exist is refused\n', case when ok then 'PASS' else 'FAIL' end);

  -- company mismatch: an invoice of company C linked by hand to a pratica of company B
  select id into d3 from public.qonto_documents where qonto_id = 't15-dc';
  perform private.set_invoice_pratica(d3, pb_1);
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  ok := (select reason_code from public.review_invoices_v where id = d3) = 'company_mismatch' and (select pratica_id = pb_1 from public.review_invoices_v where id = d3);
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s an invoice linked to a pratica of another company is listed as company_mismatch\n', case when ok then 'PASS' else 'FAIL' end);

  ---------------------------------------------------------------- payment states (total 1,000,000 cents = 10,000 EUR)
  -- helper: each pratica of its own company, linked documents inserted with an explicit link (source zite)
  for sid, k in select * from (values (s1, 1), (s2, 2), (s3, 3), (s4, 4), (s5, 5), (s6, 6), (s7, 7), (s8, 8), (s9, 9), (s10, 10)) t(a, b) loop
    insert into public.companies (name, zite_azienda_id, organization_id) values ('T15 S' || k, 't15-s' || k, org) returning id into cs;
    perform private.sync_pratiche(jsonb_build_array(jsonb_build_object('id', sid, 'code', 'T15-S' || k, 'zite_azienda_id', 't15-s' || k,
      'status', 'Lavoro completato', 'is_open', true,
      'total_fee_cents', case when k = 8 then null when k = 9 then 0 else 1000000 end, 'removed', false)));
  end loop;
  -- helper rows: (pratica, net, status, kind)
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, paid_at, total_cents, vat_cents, raw, pratica_id, pratica_link_source) values
    -- s1: 500,000 paid + an unpaid invoice of 400,000 -> partial
    ('t15-s1a', 'invoice', 'S1a', 'paid', 'Incassata', date '2027-02-01', date '2027-02-05', 610000, 110000, '{}', s1, 'zite'),
    ('t15-s1b', 'invoice', 'S1b', 'unpaid', 'Emessa',  date '2027-02-02', null,             488000,  88000, '{}', s1, 'zite'),
    -- s2: paid exactly total - tolerance -> fully_paid
    ('t15-s2a', 'invoice', 'S2a', 'paid', 'Incassata', date '2027-02-01', date '2027-02-05', 999000 * 122 / 100, 999000 * 22 / 100, '{}', s2, 'zite'),
    -- s3: paid total + tolerance -> fully_paid
    ('t15-s3a', 'invoice', 'S3a', 'paid', 'Incassata', date '2027-02-01', date '2027-02-05', 1001000 * 122 / 100, 1001000 * 22 / 100, '{}', s3, 'zite'),
    -- s4: paid total + tolerance + 1 -> overpaid
    ('t15-s4a', 'invoice', 'S4a', 'paid', 'Incassata', date '2027-02-01', date '2027-02-05', 1001001 + 220220, 220220, '{}', s4, 'zite'),
    -- s5: 1,200,000 paid and a credit note of 200,000 -> 1,000,000 fully_paid
    ('t15-s5a', 'invoice', 'S5a', 'paid', 'Incassata', date '2027-02-01', date '2027-02-05', 1200000 + 264000, 264000, '{}', s5, 'zite'),
    ('t15-s5n', 'credit_note', 'S5n', 'credit_note', 'Incassata', date '2027-02-06', null, -(200000 + 44000), -44000, '{}', s5, 'zite'),
    -- s6: paid 1,000,000 and a cancelled invoice of 500,000 -> fully_paid, cancelled not counted
    ('t15-s6a', 'invoice', 'S6a', 'paid', 'Incassata', date '2027-02-01', date '2027-02-05', 1000000 + 220000, 220000, '{}', s6, 'zite'),
    ('t15-s6x', 'invoice', 'S6x', 'canceled', 'Annullata', date '2027-02-02', null, 500000 + 110000, 110000, '{}', s6, 'zite'),
    -- s7: only a credit note, nothing paid -> partial
    ('t15-s7n', 'credit_note', 'S7n', 'credit_note', 'Incassata', date '2027-02-06', null, -(100000 + 22000), -22000, '{}', s7, 'zite'),
    -- s8, s9: paid something but no total
    ('t15-s8a', 'invoice', 'S8a', 'paid', 'Incassata', date '2027-02-01', date '2027-02-05', 122000, 22000, '{}', s8, 'zite'),
    ('t15-s9a', 'invoice', 'S9a', 'paid', 'Incassata', date '2027-02-01', date '2027-02-05', 122000, 22000, '{}', s9, 'zite');
  -- s10: nothing at all

  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select * into r from public.pratica_payment_status_v where pratica_id = s1;
  ok := r.paid_net_cents = 500000 and r.invoiced_net_cents = 900000 and r.payment_state = 'partial' and r.outstanding_cents = 500000 and not r.needs_review and not r.archivable;
  failures := failures + (not ok)::int;
  report := report || format(E'%s paid 500,000 of 1,000,000 (an unpaid invoice does not count): partial, outstanding 500,000 (got %s/%s/%s)\n', case when ok then 'PASS' else 'FAIL' end, r.paid_net_cents, r.payment_state, r.outstanding_cents);

  select * into r from public.pratica_payment_status_v where pratica_id = s2;
  ok := r.paid_net_cents = 999000 and r.payment_state = 'fully_paid' and r.archivable and not r.needs_review;
  failures := failures + (not ok)::int;
  report := report || format(E'%s paid exactly total minus 10 EUR: fully_paid, archivable (got %s)\n', case when ok then 'PASS' else 'FAIL' end, r.payment_state);

  select * into r from public.pratica_payment_status_v where pratica_id = s3;
  ok := r.paid_net_cents = 1001000 and r.payment_state = 'fully_paid' and r.archivable;
  failures := failures + (not ok)::int;
  report := report || format(E'%s paid exactly total plus 10 EUR: still fully_paid (got %s)\n', case when ok then 'PASS' else 'FAIL' end, r.payment_state);

  select * into r from public.pratica_payment_status_v where pratica_id = s4;
  ok := r.payment_state = 'overpaid' and r.needs_review and r.review_reason = 'overpaid' and not r.archivable;
  failures := failures + (not ok)::int;
  report := report || format(E'%s above total plus 10 EUR: overpaid, needs_review, not archivable (got %s, paid %s)\n', case when ok then 'PASS' else 'FAIL' end, r.payment_state, r.paid_net_cents);

  select * into r from public.pratica_payment_status_v where pratica_id = s5;
  ok := r.paid_net_cents = 1000000 and r.payment_state = 'fully_paid';
  failures := failures + (not ok)::int;
  report := report || format(E'%s a credit note is subtracted from the paid net (got %s)\n', case when ok then 'PASS' else 'FAIL' end, r.paid_net_cents);

  select * into r from public.pratica_payment_status_v where pratica_id = s6;
  ok := r.paid_net_cents = 1000000 and r.invoiced_net_cents = 1000000 and r.payment_state = 'fully_paid';
  failures := failures + (not ok)::int;
  report := report || format(E'%s a cancelled invoice counts neither as invoiced nor as paid (invoiced %s)\n', case when ok then 'PASS' else 'FAIL' end, r.invoiced_net_cents);

  select * into r from public.pratica_payment_status_v where pratica_id = s7;
  ok := r.paid_net_cents = -100000 and r.payment_state = 'partial' and not r.archivable;
  failures := failures + (not ok)::int;
  report := report || format(E'%s only a credit note: partial, never fully_paid (paid %s)\n', case when ok then 'PASS' else 'FAIL' end, r.paid_net_cents);

  ok := (select payment_state is null and needs_review and review_reason = 'total_missing' and not archivable from public.pratica_payment_status_v where pratica_id = s8)
        and (select payment_state is null and needs_review and review_reason = 'total_missing' and not archivable from public.pratica_payment_status_v where pratica_id = s9);
  failures := failures + (not ok)::int;
  report := report || format(E'%s no total (null or 0): no state, needs_review, not archivable\n', case when ok then 'PASS' else 'FAIL' end);

  ok := (select payment_state = 'partial' and paid_net_cents = 0 and linked_documents = 0 from public.pratica_payment_status_v where pratica_id = s10);
  failures := failures + (not ok)::int;
  report := report || format(E'%s a pratica with no invoice at all: partial, 0 paid\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  ---------------------------------------------------------------- access
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  ok := (select count(*) from public.pratica_payment_status_v) = 0 and (select count(*) from public.review_invoices_v) = 0;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a partner reads zero rows from both views\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform private.set_invoice_pratica(d1, pa_open);
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  begin
    update public.qonto_documents set pratica_id = pa_open, pratica_link_source = 'manual' where id = d1;
    ok := false;
  exception when insufficient_privilege then ok := ok; end;
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff cannot link from a browser (no function call, no direct write)\n', case when ok then 'PASS' else 'FAIL' end);

  set local role anon;
  foreach v in array array['pratica_payment_status_v', 'review_invoices_v'] loop
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
