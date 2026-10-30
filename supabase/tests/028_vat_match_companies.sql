-- Match Qonto invoices to companies by VAT number, list "Fatture da collegare" and the staff choice (migration vat_match_companies, PRDDISC-34).
-- One DO block, everything rolled back by the final RAISE. Made-up VAT numbers (9000000xxxx) and names only.
-- The matching works on every unlinked invoice of the database, so the checks look at the test invoices only and never at absolute counts.
do $$
declare
  org uuid := (select id from public.organizations limit 1);
  u_mgr uuid := gen_random_uuid(); u_part uuid := gen_random_uuid(); u_client uuid := gen_random_uuid();
  pa uuid; cclient uuid; rf uuid := gen_random_uuid(); p_t uuid := gen_random_uuid();
  c_z1 uuid; c_z2 uuid; c_w uuid; dz uuid; dw1 uuid; dw2 uuid;
  c_a uuid; c_b uuid; c_c uuid; c_d1 uuid; c_d2 uuid; c_g uuid; c_h uuid; c_i uuid; c_t uuid; c_u0 uuid; c_v uuid; c_y1 uuid; c_y2 uuid; c_r uuid; c_s uuid; c_e uuid;
  da uuid; da2 uuid; db uuid; dc uuid; dd uuid; dd2 uuid; de uuid; df uuid; dg uuid; dh uuid; di uuid; dt uuid; du uuid; dr uuid; ds uuid;
  run1 uuid; run2 uuid; res jsonb; r record; k int; n int; msg text;
  report text := ''; failures int := 0; ok boolean;
  -- an invoice of a Qonto client with the given VAT fields (null = the field is absent)
  doc_vat text; doc_tax text;
begin
  insert into auth.users (id, email, aud, role) values
    (u_mgr, 't28-mgr@example.test', 'authenticated', 'authenticated'), (u_part, 't28-part@example.test', 'authenticated', 'authenticated'),
    (u_client, 't28-client@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't28-z-mgr' where id = u_mgr;
  update public.profiles set role = 'partner' where id = u_part;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t28-a', 'T28 A', 't28-part@example.test', org) returning id into pa;
  insert into public.partner_members (partner_id, profile_id) values (pa, u_part);
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T28 client', 't28-client', org) returning id into cclient;
  insert into public.company_members (company_id, profile_id) values (cclient, u_client);
  update public.profiles set role = 'client' where id = u_client;

  -- 1. the normalisation, in one place
  ok := private.vat_key('IT01122290032') = '01122290032' and private.vat_key('01122290032 ') = '01122290032' and private.vat_key(' it 011.222-90032 ') = '01122290032'
        and private.vat_key('FR12345678901') = 'FR12345678901' and private.vat_key('fr 123.456-78901') = 'FR12345678901'
        and private.vat_key('IT123') = 'IT123' and private.vat_key('IT011222900321') = 'IT011222900321' and private.vat_key('IT01122290032X') = 'IT01122290032X'
        and private.vat_key('') is null and private.vat_key('  ') is null and private.vat_key(null) is null and private.vat_key('-.') is null;
  failures := failures + (not ok)::int;
  report := report || format(E'%s vat_key: spaces, dots, dashes and case go; IT goes only before exactly 11 digits (not before 3, 12 or 11 digits + a letter); FR and other prefixes stay; empty is null\n', case when ok then 'PASS' else 'FAIL' end);

  -- companies (saved through the normal path: the trigger stores the key form)
  insert into public.companies (name, zite_azienda_id, organization_id, vat_number) values ('T28 Alfa', 't28-a', org, '90000000011') returning id into c_a;
  insert into public.companies (name, zite_azienda_id, organization_id, vat_number) values ('T28 Beta', 't28-b', org, 'IT90000000022') returning id into c_b;
  insert into public.companies (name, zite_azienda_id, organization_id, vat_number) values ('T28 Gamma', 't28-c', org, '90000000033 ') returning id into c_c;
  insert into public.companies (name, zite_azienda_id, organization_id, vat_number) values ('T28 Delta uno', 't28-d1', org, '90000000044') returning id into c_d1;
  insert into public.companies (name, zite_azienda_id, organization_id, vat_number) values ('T28 Delta due', 't28-d2', org, 'IT90000000044') returning id into c_d2;
  insert into public.companies (name, zite_azienda_id, organization_id, vat_number, qonto_client_id) values ('T28 Gigante', 't28-g', org, '90000000066', 'qc-other') returning id into c_g;
  insert into public.companies (name, zite_azienda_id, organization_id, vat_number) values ('T28 Francese', 't28-h', org, 'FR90000000077') returning id into c_h;
  insert into public.companies (name, zite_azienda_id, organization_id, vat_number) values ('T28 Italiana', 't28-i', org, '90000000088') returning id into c_i;
  insert into public.companies (name, zite_azienda_id, organization_id, vat_number) values ('T28 Tau', 't28-t', org, 'IT 900.000-00099') returning id into c_t;
  insert into public.companies (name, zite_azienda_id, organization_id, vat_number) values ('T28 Upsilon zero', 't28-u0', org, '90000000100') returning id into c_u0;
  insert into public.companies (name, zite_azienda_id, organization_id, vat_number) values ('T28 Upsilon vat', 't28-v', org, '90000000101') returning id into c_v;
  insert into public.companies (name, zite_azienda_id, organization_id, vat_number, qonto_client_id) values ('T28 Ypsilon uno', 't28-y1', org, '90000000110', 'qc-f') returning id into c_y1;
  insert into public.companies (name, zite_azienda_id, organization_id, vat_number) values ('T28 Ypsilon due', 't28-y2', org, '90000000111') returning id into c_y2;
  insert into public.companies (name, zite_azienda_id, organization_id, vat_number) values ('T28 Rho', 't28-r', org, 'IT90000000120') returning id into c_r;
  insert into public.companies (name, zite_azienda_id, organization_id, vat_number) values ('T28 Sigma', 't28-s', org, '90000000130') returning id into c_s;
  insert into public.companies (name, zite_azienda_id, organization_id, vat_number) values ('T28 Epsilon blank', 't28-e', org, '   ') returning id into c_e;
  insert into public.companies (name, zite_azienda_id, organization_id, vat_number) values ('T28 Zeta uno', 't28-z1', org, '90000000140') returning id into c_z1;
  insert into public.companies (name, zite_azienda_id, organization_id, vat_number, qonto_client_id) values ('T28 Zeta due', 't28-z2', org, '90000000141', 'qc-z') returning id into c_z2;
  insert into public.companies (name, zite_azienda_id, organization_id, vat_number) values ('T28 Omega', 't28-w', org, '90000000150') returning id into c_w;
  ok := (select vat_number from public.companies where id = c_a) = '90000000011' and (select vat_number from public.companies where id = c_b) = '90000000022'
        and (select vat_number from public.companies where id = c_c) = '90000000033' and (select vat_number from public.companies where id = c_d2) = '90000000044'
        and (select vat_number from public.companies where id = c_t) = '90000000099' and (select vat_number from public.companies where id = c_h) = 'FR90000000077'
        and (select vat_number is null from public.companies where id = c_e);
  update public.companies set vat_number = ' it 900.000-00033 ' where id = c_c;
  ok := ok and (select vat_number from public.companies where id = c_c) = '90000000033';
  failures := failures + (not ok)::int;
  report := report || format(E'%s a company saved with IT, spaces, dots or dashes is stored in its key form (insert and update); a blank number is stored as null; FR stays\n', case when ok then 'PASS' else 'FAIL' end);

  -- the invoices: Qonto client id, VAT and tax id as Qonto sends them
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, total_cents, vat_cents, raw, qonto_client_id)
  select v.q, 'invoice', v.num, 'unpaid', 'Emessa', date '2027-02-01', date '2027-03-01', 122000, 22000,
         jsonb_build_object('client', jsonb_strip_nulls(jsonb_build_object('id', v.cid, 'name', v.nm, 'vat_number', v.vat, 'tax_identification_number', v.tax))), v.cid
    from (values
      ('t28-a',  'V1',  'qc-a',  'Alfa Testing Srl',      'IT90000000011', '90000000011'),   -- company 90000000011
      ('t28-a2', 'V1b', 'qc-a',  'Alfa Testing Srl',      'IT90000000011', '90000000011'),   -- same Qonto client, same group
      ('t28-b',  'V2',  'qc-b',  'Beta Testing Srl',      'IT90000000022', '90000000022'),   -- company was typed with IT
      ('t28-c',  'V3',  'qc-c',  'Gamma Testing Srl',     null,            '90000000033'),   -- only the tax id
      ('t28-d',  'V4',  'qc-d',  'Delta Testing Srl',     'IT90000000044', '90000000044'),   -- two companies
      ('t28-d2', 'V4b', 'qc-d',  'Delta Testing Srl',     'IT90000000044', '90000000044'),
      ('t28-e',  'V5',  'qc-e',  'Senza Partita Srl',     null,            null),            -- no VAT at all
      ('t28-f',  'V6',  'qc-f',  'Ypsilon Nessuna Srl',      'IT90000000055', '90000000055'),   -- nobody has it
      ('t28-g',  'V7',  'qc-g',  'Gigante Testing Srl',   'IT90000000066', '90000000066'),   -- company has another Qonto id
      ('t28-h',  'V8',  'qc-h',  'Francese Testing Srl',  'fr 90000000077', null),          -- foreign, with prefix
      ('t28-i',  'V9',  'qc-i',  'Italiana Testing Srl',  'FR90000000088', null),           -- foreign VAT, company has the digits only
      ('t28-t',  'V10', 'qc-t',  'Tau Testing Srl',       'IT90000000099', '90000000099')    -- trigger path (pratica, referral)
    ) as v(q, num, cid, nm, vat, tax);
  select id into da from public.qonto_documents where qonto_id = 't28-a'; select id into da2 from public.qonto_documents where qonto_id = 't28-a2';
  select id into db from public.qonto_documents where qonto_id = 't28-b'; select id into dc from public.qonto_documents where qonto_id = 't28-c';
  select id into dd from public.qonto_documents where qonto_id = 't28-d'; select id into dd2 from public.qonto_documents where qonto_id = 't28-d2';
  select id into de from public.qonto_documents where qonto_id = 't28-e'; select id into df from public.qonto_documents where qonto_id = 't28-f';
  select id into dg from public.qonto_documents where qonto_id = 't28-g'; select id into dh from public.qonto_documents where qonto_id = 't28-h';
  select id into di from public.qonto_documents where qonto_id = 't28-i'; select id into dt from public.qonto_documents where qonto_id = 't28-t';
  -- the Qonto client of dz is already held by ANOTHER company (c_z2) while the VAT points to c_z1; dw1/dw2 are two Qonto clients without VAT
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, total_cents, vat_cents, raw, qonto_client_id)
    values ('t28-z', 'invoice', 'V15', 'unpaid', 'Emessa', date '2027-02-01', date '2027-03-01', 122000, 22000,
            jsonb_build_object('client', jsonb_build_object('id', 'qc-z', 'name', 'Zeta Testing', 'vat_number', 'IT90000000140')), 'qc-z'),
           ('t28-w1', 'invoice', 'V16', 'unpaid', 'Emessa', date '2027-02-01', date '2027-03-01', 122000, 22000, jsonb_build_object('client', jsonb_build_object('id', 'qc-w1', 'name', 'Omega primo')), 'qc-w1'),
           ('t28-w2', 'invoice', 'V17', 'unpaid', 'Emessa', date '2027-02-01', date '2027-03-01', 122000, 22000, jsonb_build_object('client', jsonb_build_object('id', 'qc-w2', 'name', 'Omega secondo')), 'qc-w2');
  select id into dz from public.qonto_documents where qonto_id = 't28-z'; select id into dw1 from public.qonto_documents where qonto_id = 't28-w1';
  select id into dw2 from public.qonto_documents where qonto_id = 't28-w2';
  -- an invoice that already has a company (of another VAT): the matching must not touch it
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, total_cents, vat_cents, raw, qonto_client_id, company_id)
    values ('t28-u', 'invoice', 'V11', 'unpaid', 'Emessa', date '2027-02-01', date '2027-03-01', 122000, 22000,
            jsonb_build_object('client', jsonb_build_object('id', 'qc-u', 'name', 'Upsilon', 'vat_number', 'IT90000000101')), 'qc-u', c_u0) returning id into du;

  -- the trigger path needs a pratica and a referral for company Tau
  perform private.sync_pratiche(jsonb_build_array(
    jsonb_build_object('id', p_t, 'code', 'T28-T', 'zite_azienda_id', 't28-t', 'status', 'In lavorazione', 'is_open', true, 'total_fee_cents', 500000, 'removed', false)));
  perform private.sync_referrals(jsonb_build_array(
    jsonb_build_object('id', rf, 'zite_segnalatore_id', 't28-a', 'zite_azienda_id', 't28-t', 'commission_pct', 10, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', false)));
  ok := not exists (select 1 from public.commissions where invoice_id = dt) and (select company_id is null and pratica_id is null from public.qonto_documents where id = dt);
  failures := failures + (not ok)::int;
  report := report || format(E'%s before the matching: all the test invoices have no company; the invoice of Tau has no commission line\n', case when ok then 'PASS' else 'FAIL' end);

  -- 2. the matching
  res := private.link_invoices_to_companies_by_vat();
  -- linked: IT01122290032-style vs plain, company typed with IT, tax id only, the sibling invoice of the same client, FR with prefix, the Tau invoice
  ok := (select company_id = c_a from public.qonto_documents where id = da) and (select company_id = c_a from public.qonto_documents where id = da2)
        and (select company_id = c_b from public.qonto_documents where id = db) and (select company_id = c_c from public.qonto_documents where id = dc)
        and (select company_id = c_h from public.qonto_documents where id = dh) and (select company_id = c_t from public.qonto_documents where id = dt)
        and (select qonto_client_id = 'qc-a' from public.companies where id = c_a) and (select qonto_client_id = 'qc-b' from public.companies where id = c_b)
        and (select qonto_client_id = 'qc-c' from public.companies where id = c_c) and (select qonto_client_id = 'qc-h' from public.companies where id = c_h)
        and (res->>'linked')::int >= 6;
  failures := failures + (not ok)::int;
  report := report || format(E'%s linked: Qonto IT90000000011 / company 90000000011, company typed with IT, tax id only, two invoices of one client, fr 90000000077 / FR90000000077; the company gets the Qonto client id\n', case when ok then 'PASS' else 'FAIL' end);

  ok := (select company_id is null from public.qonto_documents where id = dd) and (select company_id is null from public.qonto_documents where id = dd2)
        and (select company_id is null from public.qonto_documents where id = de) and (select company_id is null from public.qonto_documents where id = df)
        and (select company_id is null from public.qonto_documents where id = dg) and (select company_id is null from public.qonto_documents where id = di)
        and (select qonto_client_id is null from public.companies where id in (c_d1) ) and (select qonto_client_id is null from public.companies where id = c_d2)
        and (select qonto_client_id = 'qc-other' from public.companies where id = c_g) and (select qonto_client_id is null from public.companies where id = c_i)
        and (res->>'ambiguous')::int >= 2 and (res->>'no_vat')::int >= 1 and (res->>'no_company')::int >= 2 and (res->>'other_qonto_client')::int >= 1;
  failures := failures + (not ok)::int;
  report := report || format(E'%s not linked, nothing changed: two companies with the same key, no VAT on the Qonto client, a VAT nobody has, a company with another Qonto id (not overwritten), FR90000000088 vs 90000000088 (prefix kept)\n', case when ok then 'PASS' else 'FAIL' end);

  -- trigger path: the pratica of the company and the commission line of the referral follow from the existing triggers
  ok := (select pratica_id = p_t from public.qonto_documents where id = dt)
        and (select count(*) from public.commissions where invoice_id = dt and referral_id = rf and amount_cents = 10000) = 1;
  failures := failures + (not ok)::int;
  report := report || format(E'%s after the link the invoice gets the pratica of its company and the commission line of the referral (existing triggers)\n', case when ok then 'PASS' else 'FAIL' end);

  -- an invoice that already has a company is never touched, and a second run changes nothing
  res := private.link_invoices_to_companies_by_vat();
  ok := (select company_id = c_u0 from public.qonto_documents where id = du) and (res->>'linked')::int = 0 and (res->>'companies_updated')::int = 0
        and (select company_id = c_a from public.qonto_documents where id = da);
  failures := failures + (not ok)::int;
  report := report || format(E'%s an invoice that already has a company (even if its VAT names another) is left alone; a second run links nothing\n', case when ok then 'PASS' else 'FAIL' end);

  -- 3. the list, for staff
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  set local role authenticated;
  ok := (select reason_code from public.invoices_to_link_v where id = dd) = 'ambiguous' and (select reason_code from public.invoices_to_link_v where id = de) = 'no_vat'
        and (select reason_code from public.invoices_to_link_v where id = df) = 'no_company' and (select reason_code from public.invoices_to_link_v where id = dg) = 'other_qonto_client'
        and (select reason_code from public.invoices_to_link_v where id = di) = 'no_company'
        and not exists (select 1 from public.invoices_to_link_v where id in (da, da2, db, dc, dh, dt, du));
  select * into r from public.invoices_to_link_v where id = dd;
  ok := ok and r.number = 'V4' and r.net_cents = 100000 and r.qonto_client_name = 'Delta Testing Srl' and r.qonto_vat = 'IT90000000044' and r.vat_key = '90000000044' and r.issue_date = date '2027-02-01'
        and jsonb_array_length(r.candidates) = 2 and (r.candidates->0->>'match') = 'vat';
  select * into r from public.invoices_to_link_v where id = di;
  ok := ok and exists (select 1 from jsonb_array_elements(r.candidates) c where (c->>'company_id')::uuid = c_i and c->>'match' = 'vat_close');
  select * into r from public.invoices_to_link_v where id = df;
  ok := ok and exists (select 1 from jsonb_array_elements(r.candidates) c where (c->>'company_id')::uuid = c_y1 and c->>'match' = 'name');
  failures := failures + (not ok)::int;
  report := report || format(E'%s the list shows the unlinked invoices with number, date, net, Qonto client name and VAT, the reason, and the candidates (same VAT first, then a close VAT or a name in common); linked ones are not listed\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  -- a segnalatore, a client and an anonymous caller see nothing of it
  k := 0; n := 0;
  perform set_config('request.jwt.claims', json_build_object('sub', u_part, 'role', 'authenticated')::text, true);
  set local role authenticated;
  n := n + (select count(*) from public.invoices_to_link_v);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', u_client, 'role', 'authenticated')::text, true);
  set local role authenticated;
  n := n + (select count(*) from public.invoices_to_link_v);
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  set local role anon;
  begin perform count(*) from public.invoices_to_link_v; exception when insufficient_privilege then k := 1; end;
  reset role;
  ok := n = 0 and k = 1;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalatore and a client see no row of the list; anonymous is refused\n', case when ok then 'PASS' else 'FAIL' end);

  -- 4. the staff choice
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.link_invoice_to_company(dd, c_d1);
  ok := n = 2 and (select company_id = c_d1 from public.qonto_documents where id = dd) and (select company_id = c_d1 from public.qonto_documents where id = dd2)
        and (select qonto_client_id = 'qc-d' from public.companies where id = c_d1) and not exists (select 1 from public.invoices_to_link_v where id in (dd, dd2));
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff picks a company for an ambiguous invoice: it and the other unlinked invoice of the same Qonto client are linked, the company gets the Qonto client id, the list no longer shows them\n', case when ok then 'PASS' else 'FAIL' end);

  k := 0;
  begin perform public.link_invoice_to_company(dg, c_g); exception when sqlstate '22023' then if sqlerrm like 'L''azienda è già collegata a un altro cliente Qonto%' then k := k + 1; end if; end;
  begin perform public.link_invoice_to_company(da, c_b); exception when sqlstate '22023' then if sqlerrm like 'La fattura ha già un''azienda%' then k := k + 1; end if; end;
  begin perform public.link_invoice_to_company(df, c_y2); exception when sqlstate '22023' then if sqlerrm like 'Questo cliente Qonto è già collegato a un''altra azienda%' then k := k + 1; end if; end;
  begin perform public.link_invoice_to_company(gen_random_uuid(), c_a); exception when sqlstate '22023' then k := k + 1; end;
  begin perform public.link_invoice_to_company(de, gen_random_uuid()); exception when sqlstate '22023' then k := k + 1; end;
  ok := k = 5 and (select company_id is null from public.qonto_documents where id in (dg)) and (select company_id is null from public.qonto_documents where id = df)
        and (select qonto_client_id = 'qc-other' from public.companies where id = c_g) and (select qonto_client_id is null from public.companies where id = c_y2)
        and (select company_id = c_a from public.qonto_documents where id = da);
  failures := failures + (not ok)::int;
  report := report || format(E'%s refused: a company with another Qonto id (not replaced), an invoice that already has a company, a Qonto client already held by another company, an unknown invoice, an unknown company (%s of 5); nothing changed\n', case when ok then 'PASS' else 'FAIL' end, k);

  -- the Qonto client is held by another company: the matching did not link it (and did not take the id), the list says so, the staff action refuses
  k := 0;
  begin perform public.link_invoice_to_company(dz, c_z1); exception when sqlstate '22023' then if sqlerrm like 'Questo cliente Qonto è già collegato a un''altra azienda%' then k := 1; end if; end;
  ok := k = 1 and (select company_id is null from public.qonto_documents where id = dz) and (select qonto_client_id is null from public.companies where id = c_z1)
        and (select qonto_client_id = 'qc-z' from public.companies where id = c_z2)
        and (select reason_code from public.invoices_to_link_v where id = dz) = 'other_qonto_client';
  failures := failures + (not ok)::int;
  report := report || format(E'%s a Qonto client already held by another company: not linked, the company does not take the id, the list says other_qonto_client (not "to_be_linked"), the staff action refuses\n', case when ok then 'PASS' else 'FAIL' end);

  -- an empty company takes the first Qonto client linked to it; a second Qonto client is refused afterwards (the lock makes this hold under concurrency too)
  select count(*) into n from public.link_invoice_to_company(dw1, c_w);
  k := 0;
  begin perform public.link_invoice_to_company(dw2, c_w); exception when sqlstate '22023' then if sqlerrm like 'L''azienda è già collegata a un altro cliente Qonto%' then k := 1; end if; end;
  ok := n = 1 and k = 1 and (select qonto_client_id = 'qc-w1' from public.companies where id = c_w) and (select company_id = c_w from public.qonto_documents where id = dw1)
        and (select company_id is null from public.qonto_documents where id = dw2);
  failures := failures + (not ok)::int;
  report := report || format(E'%s an empty company takes the Qonto client of the first invoice linked to it; an invoice of a second Qonto client is then refused and stays unlinked\n', case when ok then 'PASS' else 'FAIL' end);

  -- an invoice with no Qonto client id: only that invoice is linked, no id is written
  reset role;
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, total_cents, vat_cents, raw, qonto_client_id)
    values ('t28-n', 'invoice', 'V12', 'unpaid', 'Emessa', date '2027-02-01', date '2027-03-01', 122000, 22000, '{}'::jsonb, null);
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.link_invoice_to_company((select id from public.qonto_documents where qonto_id = 't28-n'), c_s);
  ok := n = 1 and (select qonto_client_id is null from public.companies where id = c_s) and (select company_id = c_s from public.qonto_documents where qonto_id = 't28-n');
  failures := failures + (not ok)::int;
  report := report || format(E'%s an invoice with no Qonto client id is linked alone and no Qonto id is written on the company\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  -- non-staff are refused
  k := 0;
  perform set_config('request.jwt.claims', json_build_object('sub', u_part, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.link_invoice_to_company(de, c_a); exception when insufficient_privilege then k := k + 1; end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', u_client, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.link_invoice_to_company(de, c_a); exception when insufficient_privilege then k := k + 1; end;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  set local role anon;
  begin perform public.link_invoice_to_company(de, c_a); exception when insufficient_privilege then k := k + 1; end;
  reset role;
  ok := k = 3 and (select company_id is null from public.qonto_documents where id = de);
  failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalatore, a client and an anonymous caller are refused (%s of 3)\n', case when ok then 'PASS' else 'FAIL' end, k);

  -- 5. at the end of a sync run
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, total_cents, vat_cents, raw, qonto_client_id)
    values ('t28-r', 'invoice', 'V13', 'unpaid', 'Emessa', date '2027-02-01', date '2027-03-01', 122000, 22000,
            jsonb_build_object('client', jsonb_build_object('id', 'qc-r', 'name', 'Rho Testing', 'vat_number', 'IT90000000120')), 'qc-r'),
           ('t28-s', 'invoice', 'V14', 'unpaid', 'Emessa', date '2027-02-01', date '2027-03-01', 122000, 22000,
            jsonb_build_object('client', jsonb_build_object('id', 'qc-s2', 'name', 'Sigma Testing', 'vat_number', 'IT90000000130')), 'qc-s2');
  select id into dr from public.qonto_documents where qonto_id = 't28-r'; select id into ds from public.qonto_documents where qonto_id = 't28-s';
  insert into public.qonto_sync_runs default values returning id into run1;
  insert into public.qonto_sync_runs default values returning id into run2;
  -- a run that fails does not link anything and keeps the count the Edge Function wrote
  update public.qonto_sync_runs set finished_at = now(), error = 'boom', unmatched_count = 77 where id = run2;
  ok := (select company_id is null from public.qonto_documents where id = dr) and (select unmatched_count = 77 from public.qonto_sync_runs where id = run2);
  -- a run that finishes without error links, and the count is the one AFTER the linking
  update public.qonto_sync_runs set finished_at = now(), unmatched_count = 77 where id = run1;
  select count(*) into n from public.qonto_documents where company_id is null and removed_at is null;
  ok := ok and (select company_id = c_r from public.qonto_documents where id = dr) and (select qonto_client_id = 'qc-r' from public.companies where id = c_r)
        and (select unmatched_count = n from public.qonto_sync_runs where id = run1);
  -- c_s already holds no Qonto id through the earlier manual link (none written): the invoice of qc-s2 links and the company takes qc-s2
  ok := ok and (select company_id = c_s from public.qonto_documents where id = ds) and (select qonto_client_id = 'qc-s2' from public.companies where id = c_s);
  failures := failures + (not ok)::int;
  report := report || format(E'%s the end of a sync run (no error) links what it can and writes the unmatched count after the linking; a run that ended with an error links nothing and keeps its count\n', case when ok then 'PASS' else 'FAIL' end);

  -- 6. structure
  ok := not has_function_privilege('authenticated', 'private.link_invoices_to_companies_by_vat()', 'execute')
        and not has_function_privilege('authenticated', 'private.qonto_run_finished()', 'execute')
        and not has_function_privilege('authenticated', 'private.companies_vat_key()', 'execute')
        and has_function_privilege('authenticated', 'public.link_invoice_to_company(uuid, uuid)', 'execute')
        and not has_function_privilege('anon', 'public.link_invoice_to_company(uuid, uuid)', 'execute')
        and has_function_privilege('authenticated', 'private.vat_key(text)', 'execute')
        and (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'link_invoice_to_company' and p.prosecdef
               and coalesce(p.proconfig, '{}') @> array['search_path=""']) = 1
        and (select coalesce(reloptions, '{}') @> array['security_invoker=true'] from pg_class where oid = 'public.invoices_to_link_v'::regclass)
        and has_table_privilege('authenticated', 'public.invoices_to_link_v', 'select') and not has_table_privilege('anon', 'public.invoices_to_link_v', 'select')
        and exists (select 1 from pg_trigger where tgrelid = 'public.companies'::regclass and tgname = 'companies_vat_key' and not tgisinternal)
        and exists (select 1 from pg_trigger where tgrelid = 'public.qonto_sync_runs'::regclass and tgname = 'qonto_sync_runs_link_companies' and not tgisinternal);
  failures := failures + (not ok)::int;
  report := report || format(E'%s structure: the matching and the two triggers are not callable by signed-in users; link_invoice_to_company is security definer with a fixed search path, signed-in users only; the list is security_invoker, staff only through the view\n', case when ok then 'PASS' else 'FAIL' end);

  raise exception E'TEST REPORT (028 vat match companies): % failure(s)\n%', failures, report;
end $$;
