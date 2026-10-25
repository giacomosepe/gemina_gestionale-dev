-- Staff link of an invoice to a pratica (migration invoice_pratica_link, PRDDISC-23) and the commission_lines_v view (PRDDISC-24).
-- Same pattern as 001-021: one DO block, everything rolled back by the final RAISE. Made-up rows only.

do $$
declare
  org uuid := (select id from public.organizations limit 1);
  u_mgr uuid := gen_random_uuid(); u_part uuid := gen_random_uuid(); u_client uuid := gen_random_uuid();
  pa uuid; cx uuid; cy uuid; cclient uuid;
  p_x1 uuid := gen_random_uuid(); p_x2 uuid := gen_random_uuid(); p_y uuid := gen_random_uuid();
  rf uuid := gen_random_uuid();
  d1 uuid; d_nocomp uuid; d_paid uuid;
  res record; k int; n int;
  report text := ''; failures int := 0; ok boolean;
begin
  insert into auth.users (id, email, aud, role) values
    (u_mgr, 't22-mgr@example.test', 'authenticated', 'authenticated'), (u_part, 't22-part@example.test', 'authenticated', 'authenticated'),
    (u_client, 't22-client@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't22-z-mgr' where id = u_mgr;
  update public.profiles set role = 'partner' where id = u_part;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t22-a', 'T22 A', 't22-part@example.test', org) returning id into pa;
  insert into public.partner_members (partner_id, profile_id) values (pa, u_part);
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T22 X', 't22-x', org) returning id into cx;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T22 Y', 't22-y', org) returning id into cy;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T22 client', 't22-client', org) returning id into cclient;
  insert into public.company_members (company_id, profile_id) values (cclient, u_client);
  update public.profiles set role = 'client' where id = u_client;
  perform private.sync_pratiche(jsonb_build_array(
    jsonb_build_object('id', p_x1, 'code', 'T22-X1', 'zite_azienda_id', 't22-x', 'status', 'In lavorazione', 'is_open', true, 'total_fee_cents', 500000, 'removed', false),
    jsonb_build_object('id', p_x2, 'code', 'T22-X2', 'zite_azienda_id', 't22-x', 'status', 'In lavorazione', 'is_open', true, 'total_fee_cents', 500000, 'removed', false),
    jsonb_build_object('id', p_y,  'code', 'T22-Y',  'zite_azienda_id', 't22-y', 'status', 'In lavorazione', 'is_open', true, 'total_fee_cents', 500000, 'removed', false)));
  perform private.sync_referrals(jsonb_build_array(
    jsonb_build_object('id', rf, 'zite_segnalatore_id', 't22-a', 'zite_azienda_id', 't22-x', 'commission_pct', 10, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', false)));

  -- two pratiche for X make the automatic rule ambiguous, so the invoices below stay unlinked
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, total_cents, vat_cents, raw, company_id) values
    ('t22-1', 'invoice', 'L1', 'unpaid', 'Emessa', date '2027-02-01', date '2027-03-01', 122000, 22000, '{}', cx),
    ('t22-nocomp', 'invoice', 'L2', 'unpaid', 'Emessa', date '2027-02-02', date '2027-03-02', 122000, 22000, '{}', null);
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, paid_at, total_cents, vat_cents, raw, company_id) values
    ('t22-paid', 'invoice', 'L3', 'paid', 'Incassata', date '2027-02-03', date '2027-03-03', date '2027-02-20', 122000, 22000, '{}', cx);
  select id into d1 from public.qonto_documents where qonto_id = 't22-1';
  select id into d_nocomp from public.qonto_documents where qonto_id = 't22-nocomp';
  select id into d_paid from public.qonto_documents where qonto_id = 't22-paid';

  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- 1. starting point: unlinked, in the review list, no lines
  ok := (select pratica_id is null from public.qonto_documents where id = d1) and exists (select 1 from public.review_invoices_v where id = d1)
        and not exists (select 1 from public.commissions where invoice_id = d1);
  failures := failures + (not ok)::int;
  report := report || format(E'%s the test invoice starts unlinked, listed for review, with no commission line\n', case when ok then 'PASS' else 'FAIL' end);

  -- 2. options: same azienda first, the other azienda flagged, nothing linked yet
  select count(*) into n from public.invoice_pratica_options(d1) where same_company;
  ok := n = 2 and (select count(*) from public.invoice_pratica_options(d1) where code like 'T22-%' and not same_company) = 1
        and (select bool_and(same_company) from (select same_company from public.invoice_pratica_options(d1) limit 2) f)
        and not exists (select 1 from public.invoice_pratica_options(d1) where linked);
  failures := failures + (not ok)::int;
  report := report || format(E'%s options: the two pratiche of the invoice''s azienda come first, the other azienda''s is flagged, none is linked\n', case when ok then 'PASS' else 'FAIL' end);

  -- 3. link: manual, leaves the review list, the commission line appears
  select * into res from public.link_invoice_to_pratica(d1, p_x1);
  ok := res.invoice_id = d1 and res.pratica_id = p_x1 and res.pratica_link_source = 'manual'
        and not exists (select 1 from public.review_invoices_v where id = d1)
        and (select count(*) from public.commissions where invoice_id = d1 and referral_id = rf) = 1
        and (select linked from public.invoice_pratica_options(d1) where pratica_id = p_x1);
  failures := failures + (not ok)::int;
  report := report || format(E'%s link: source manual, the invoice leaves the review list, one commission line appears, the option shows as linked\n', case when ok then 'PASS' else 'FAIL' end);

  -- 4. the line shows in commission_lines_v with the Zite ids and the pratica code
  select * into res from public.commission_lines_v where invoice_id = d1;
  ok := res.zite_segnalatore_id = 't22-a' and res.zite_azienda_id = 't22-x' and res.pratica_code = 'T22-X1' and res.stage = 'Provvigioni teoriche'
        and res.invoice_net_cents = 100000 and res.invoice_kind = 'invoice';
  failures := failures + (not ok)::int;
  report := report || format(E'%s commission_lines_v: Zite ids of segnalatore and azienda, pratica code, stage, invoice net\n', case when ok then 'PASS' else 'FAIL' end);

  -- 5. relink to the other pratica of the azienda: the link moves, still one line
  select * into res from public.link_invoice_to_pratica(d1, p_x2);
  ok := res.pratica_id = p_x2 and (select count(*) from public.commissions where invoice_id = d1) = 1
        and (select pratica_code from public.commission_lines_v where invoice_id = d1) = 'T22-X2';
  failures := failures + (not ok)::int;
  report := report || format(E'%s relink to another pratica of the same azienda: link moves, still one line, now on the new pratica\n', case when ok then 'PASS' else 'FAIL' end);

  -- 6. refusals
  k := 0;
  begin perform public.link_invoice_to_pratica(d1, p_y); exception when sqlstate '22023' then if sqlerrm like 'La pratica è di un''altra azienda%' then k := k + 1; end if; end;
  begin perform public.link_invoice_to_pratica(d_nocomp, p_x1); exception when sqlstate '22023' then if sqlerrm like 'La fattura non ha ancora un''azienda%' then k := k + 1; end if; end;
  begin perform public.link_invoice_to_pratica(d1, gen_random_uuid()); exception when sqlstate '22023' then k := k + 1; end;
  begin perform public.link_invoice_to_pratica(gen_random_uuid(), p_x1); exception when sqlstate '22023' then k := k + 1; end;
  begin perform public.unlink_invoice_pratica(gen_random_uuid()); exception when sqlstate '22023' then k := k + 1; end;
  begin perform public.invoice_pratica_options(gen_random_uuid()); exception when sqlstate '22023' then k := k + 1; end;
  ok := k = 6 and (select pratica_id = p_x2 from public.qonto_documents where id = d1) and (select pratica_id is null from public.qonto_documents where id = d_nocomp);
  failures := failures + (not ok)::int;
  report := report || format(E'%s refused: pratica of another azienda, invoice without azienda, unknown pratica, unknown invoice (link, unlink, options) (%s of 6); nothing changed\n', case when ok then 'PASS' else 'FAIL' end, k);

  -- 7. a manual link is not touched by the automatic rule: the rule only fills documents with no link source
  ok := (select pratica_link_source = 'manual' from public.qonto_documents where id = d1);
  reset role;
  perform private.link_invoices_to_pratiche();
  set local role authenticated;
  ok := ok and (select pratica_id = p_x2 and pratica_link_source = 'manual' from public.qonto_documents where id = d1);
  failures := failures + (not ok)::int;
  report := report || format(E'%s the automatic link rule run again leaves the manual link as it is\n', case when ok then 'PASS' else 'FAIL' end);

  -- 8. unlink: an unpaid, un-invoiced line goes; a received/invoiced line stays
  select * into res from public.unlink_invoice_pratica(d1);
  ok := res.pratica_id is null and res.pratica_link_source = 'manual' and not exists (select 1 from public.commissions where invoice_id = d1);
  reset role;
  update public.qonto_documents set pratica_id = p_x1, pratica_link_source = 'manual' where id = d_paid;
  update public.commissions set partner_invoice_number = 'FS-22', partner_invoiced_on = date '2027-03-10' where invoice_id = d_paid;
  set local role authenticated;
  perform public.unlink_invoice_pratica(d_paid);
  ok := ok and (select count(*) from public.commissions where invoice_id = d_paid and partner_invoice_number = 'FS-22') = 1;
  failures := failures + (not ok)::int;
  report := report || format(E'%s unlink: the unpaid line goes, the line already invoiced to the segnalatore stays\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  -- 9. a segnalatore, a client and an anonymous caller are refused; the segnalatore and the client see no commission_lines_v rows of others
  k := 0;
  perform set_config('request.jwt.claims', json_build_object('sub', u_part, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.link_invoice_to_pratica(d1, p_x1); exception when insufficient_privilege then k := k + 1; end;
  begin perform public.unlink_invoice_pratica(d1); exception when insufficient_privilege then k := k + 1; end;
  begin perform public.invoice_pratica_options(d1); exception when insufficient_privilege then k := k + 1; end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', u_client, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.link_invoice_to_pratica(d1, p_x1); exception when insufficient_privilege then k := k + 1; end;
  n := (select count(*) from public.commission_lines_v);
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  set local role anon;
  begin perform public.link_invoice_to_pratica(d1, p_x1); exception when insufficient_privilege then k := k + 1; end;
  reset role;
  ok := k = 5 and n = 0 and (select pratica_id is null from public.qonto_documents where id = d1);
  failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalatore, a client and an anonymous caller are refused (%s of 5); a client sees no commission lines\n', case when ok then 'PASS' else 'FAIL' end, k);

  -- 10. structure
  ok := (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('invoice_pratica_options', 'link_invoice_to_pratica', 'unlink_invoice_pratica')
            and p.prosecdef and coalesce(p.proconfig, '{}') @> array['search_path=""']) = 3
        and has_function_privilege('authenticated', 'public.link_invoice_to_pratica(uuid, uuid)', 'execute')
        and not has_function_privilege('anon', 'public.link_invoice_to_pratica(uuid, uuid)', 'execute')
        and not has_function_privilege('anon', 'public.unlink_invoice_pratica(uuid)', 'execute')
        and not has_function_privilege('anon', 'public.invoice_pratica_options(uuid)', 'execute')
        and has_table_privilege('authenticated', 'public.commission_lines_v', 'select') and not has_table_privilege('anon', 'public.commission_lines_v', 'select')
        and (select coalesce(reloptions, '{}') @> array['security_invoker=true'] from pg_class where oid = 'public.commission_lines_v'::regclass);
  failures := failures + (not ok)::int;
  report := report || format(E'%s the three functions are security definer with a fixed search path, signed-in users only; commission_lines_v is security_invoker, signed-in users only\n', case when ok then 'PASS' else 'FAIL' end);

  raise exception E'TEST REPORT (022 invoice pratica link): % failure(s)\n%', failures, report;
end $$;
