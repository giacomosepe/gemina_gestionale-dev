-- Commission maturation notices (migration commission_notices, PRDDISC-22): the switch, exactly one portal message + one bell per team member + one email
-- request per line, nothing twice, nothing for a line born on a paid invoice, nothing when off, a failing notice never breaks the save. Same pattern as
-- 001-020: one DO block, everything rolled back by the final RAISE (also the switch). Made-up rows; placeholder emails only: nothing real is sent.
-- Note: the test turns the switch off/on itself; the shipped value ('off') is only reported in the first line.

do $$
declare
  org uuid := (select id from public.organizations limit 1);
  shipped text := (select value from private.settings where name = 'commission_notices');
  pa uuid; pb uuid; cx uuid;
  prat uuid := gen_random_uuid();
  r_a uuid := gen_random_uuid(); r_b uuid := gen_random_uuid();
  d1 uuid; d2 uuid; d3 uuid; d4 uuid; d5 uuid;
  l_a uuid; l_b uuid;
  staff_n int; n int; k int; v text; snap1 text; snap2 text;
  expected_body text := 'La provvigione sulla pratica T21-P è ora passata allo stato Maturata – Da Fatturare. Invia la tua fattura a Gemina Advisory per richiedere il pagamento della provvigione.';
  report text := ''; failures int := 0; ok boolean;
begin
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t21-a', 'T21 A', 't21-a@example.test', org) returning id into pa;
  insert into public.partners (zite_segnalatore_id, name, email, archived, organization_id) values ('t21-b', 'T21 B', 't21-b@example.test', true, org) returning id into pb;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('T21 X', 't21-x', org) returning id into cx;
  perform private.sync_pratiche(jsonb_build_array(
    jsonb_build_object('id', prat, 'code', 'T21-P', 'zite_azienda_id', 't21-x', 'status', 'In lavorazione', 'is_open', true, 'total_fee_cents', 500000, 'removed', false)));
  perform private.sync_referrals(jsonb_build_array(
    jsonb_build_object('id', r_a, 'zite_segnalatore_id', 't21-a', 'zite_azienda_id', 't21-x', 'commission_pct', 10, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', false),
    jsonb_build_object('id', r_b, 'zite_segnalatore_id', 't21-b', 'zite_azienda_id', 't21-x', 'commission_pct', 5, 'starts_on', '2027-01-01', 'duration_years', null, 'ends_on', null, 'removed', false)));
  select count(*) into staff_n from public.profiles where role = 'staff';

  report := report || format(E'INFO the switch as shipped: %L (the test sets it itself); %s staff profiles receive the team bell\n', shipped, staff_n);

  -- 1. switch off: a paid invoice matures its lines and NOTHING else happens
  update private.settings set value = 'off' where name = 'commission_notices';
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, total_cents, vat_cents, raw, company_id, pratica_id, pratica_link_source) values
    ('t21-1', 'invoice', 'D1', 'unpaid', 'Emessa', date '2027-02-10', date '2027-03-10', 122000, 22000, '{}', cx, prat, 'zite');
  select id into d1 from public.qonto_documents where qonto_id = 't21-1';
  update public.qonto_documents set status = 'Incassata', paid_at = date '2027-02-20' where id = d1;
  ok := (select count(*) from public.commissions where invoice_id = d1 and matured_at is not null) = 2
        and (select count(*) from public.commission_notices) = 0
        and (select count(*) from public.messages m join public.conversations c on c.id = m.conversation_id where c.partner_id in (pa, pb)) = 0
        and (select count(*) from public.notifications where event = 'provvigione-maturata' and event_key like 'cm:%') = 0
        and not private.setting_on('commission_notices');
  failures := failures + (not ok)::int;
  report := report || format(E'%s with the switch off the lines mature but nothing is recorded, sent or written\n', case when ok then 'PASS' else 'FAIL' end);

  -- 2. switch on: an invoice turning paid = one message, one bell per team member, one email request, per line
  update private.settings set value = 'on' where name = 'commission_notices';
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, total_cents, vat_cents, raw, company_id, pratica_id, pratica_link_source) values
    ('t21-2', 'invoice', 'D2', 'unpaid', 'Emessa', date '2027-03-10', date '2027-04-10', 122000, 22000, '{}', cx, prat, 'zite');
  select id into d2 from public.qonto_documents where qonto_id = 't21-2';
  select id into l_a from public.commissions where invoice_id = d2 and referral_id = r_a;
  select id into l_b from public.commissions where invoice_id = d2 and referral_id = r_b;
  ok := (select count(*) from public.commission_notices) = 0;   -- unpaid: nothing yet
  update public.qonto_documents set status = 'Incassata', paid_at = date '2027-03-20' where id = d2;
  ok := ok and (select count(*) from public.commission_notices where commission_id in (l_a, l_b)) = 2
        -- the segnalatore's portal message: once, signed by nobody (automatic), Zite's text, subject = conversation title
        and (select count(*) from public.messages m join public.conversations c on c.id = m.conversation_id
              where c.partner_id = pa and c.title = 'Provvigione maturata: T21-P' and m.automatic and m.sender_id is null and m.body = expected_body) = 1
        and (select message_id is not null from public.commission_notices where commission_id = l_a)
        -- the archived segnalatore: no message
        and (select count(*) from public.messages m join public.conversations c on c.id = m.conversation_id where c.partner_id = pb) = 0
        and (select message_id is null from public.commission_notices where commission_id = l_b)
        -- the team: one bell per staff profile and line, Zite's text, kind event, link to the pratica
        and (select count(*) from public.notifications where event = 'provvigione-maturata' and event_key like 'cm:' || l_a::text || ':%') = staff_n
        and (select count(*) from public.notifications where event = 'provvigione-maturata' and event_key like 'cm:' || l_b::text || ':%') = staff_n
        and (select bool_and(kind = 'event' and link = 'pratica:' || prat::text and actor_id is null
                             and label = 'Provvigione maturata per T21 A sulla pratica T21-P: T21 A può fatturare a Gemina.')
               from public.notifications where event_key like 'cm:' || l_a::text || ':%')
        and (select bells = staff_n from public.commission_notices where commission_id = l_a)
        -- the email: asked once, text recorded, not sent yet (the function does it)
        and (select title = 'Provvigione maturata: T21-P' and body = expected_body and emailed_at is null and email_claimed_at is null from public.commission_notices where commission_id = l_a);
  failures := failures + (not ok)::int;
  report := report || format(E'%s switch on: a paid invoice gives, per line, one portal message (Zite''s text, none for an archived segnalatore), one bell for each of the %s staff profiles and one email request\n', case when ok then 'PASS' else 'FAIL' end, staff_n);

  -- 3. nothing twice: rebuilds, saves, paid -> unpaid -> paid, the whole repair
  select string_agg(format('%s|%s|%s', commission_id, message_id, bells), ';' order by commission_id) into snap1 from public.commission_notices;
  select count(*) into n from public.notifications where event = 'provvigione-maturata';
  select count(*) into k from public.messages where automatic;
  perform private.rebuild_commissions(d2);
  update public.qonto_documents set paid_at = date '2027-03-21' where id = d2;
  update public.qonto_documents set status = 'Emessa', paid_at = null where id = d2;
  update public.qonto_documents set status = 'Incassata', paid_at = date '2027-03-22' where id = d2;
  update public.commissions set partner_invoice_number = 'FS-1', partner_invoiced_on = date '2027-03-25' where id = l_a;
  perform private.rebuild_all_commissions();
  select string_agg(format('%s|%s|%s', commission_id, message_id, bells), ';' order by commission_id) into snap2 from public.commission_notices;
  ok := snap1 = snap2 and (select count(*) from public.notifications where event = 'provvigione-maturata') = n and (select count(*) from public.messages where automatic) = k
        and (select count(*) from public.commission_notices) = 2;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a rebuild, a re-save, paid -> unpaid -> paid, a partner invoice number and the whole repair create no second notice\n', case when ok then 'PASS' else 'FAIL' end);

  -- 4. a line born on an invoice that is already paid sends nothing (Zite never did)
  select count(*) into n from public.commission_notices;
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, paid_at, total_cents, vat_cents, raw, company_id, pratica_id, pratica_link_source) values
    ('t21-3', 'invoice', 'D3', 'paid', 'Incassata', date '2027-04-10', date '2027-05-10', date '2027-04-12', 122000, 22000, '{}', cx, prat, 'zite');
  select id into d3 from public.qonto_documents where qonto_id = 't21-3';
  ok := (select count(*) from public.commissions where invoice_id = d3 and matured_at is not null) = 2 and (select count(*) from public.commission_notices) = n;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a line created on an already paid invoice is born matured and notifies nobody\n', case when ok then 'PASS' else 'FAIL' end);

  -- 5. a maturation that happened while the switch was off is never notified later
  update private.settings set value = 'off' where name = 'commission_notices';
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, total_cents, vat_cents, raw, company_id, pratica_id, pratica_link_source) values
    ('t21-4', 'invoice', 'D4', 'unpaid', 'Emessa', date '2027-04-15', date '2027-05-15', 122000, 22000, '{}', cx, prat, 'zite');
  select id into d4 from public.qonto_documents where qonto_id = 't21-4';
  select count(*) into n from public.commission_notices;
  update public.qonto_documents set status = 'Incassata', paid_at = date '2027-04-20' where id = d4;
  update private.settings set value = 'on' where name = 'commission_notices';
  update public.qonto_documents set status = 'Emessa', paid_at = null where id = d4;
  update public.qonto_documents set status = 'Incassata', paid_at = date '2027-04-21' where id = d4;
  perform private.rebuild_all_commissions();
  ok := (select count(*) from public.commission_notices) = n;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a line that matured while the switch was off is not notified when it is switched on\n', case when ok then 'PASS' else 'FAIL' end);

  -- 6. a failing notice never breaks the save: it is logged, the line still matures
  alter table public.commission_notices add constraint t21_always_fails check (false) not valid;
  insert into public.qonto_documents (qonto_id, kind, number, status_qonto, status, issue_date, due_date, total_cents, vat_cents, raw, company_id, pratica_id, pratica_link_source) values
    ('t21-5', 'invoice', 'D5', 'unpaid', 'Emessa', date '2027-04-25', date '2027-05-25', 122000, 22000, '{}', cx, prat, 'zite');
  select id into d5 from public.qonto_documents where qonto_id = 't21-5';
  select count(*) into n from public.commission_notices;
  update public.qonto_documents set status = 'Incassata', paid_at = date '2027-04-26' where id = d5;
  ok := (select status from public.qonto_documents where id = d5) = 'Incassata'
        and (select count(*) from public.commissions where invoice_id = d5 and matured_at is not null) = 2
        and (select count(*) from public.commission_notices) = n
        and (select count(*) from public.commission_rebuild_errors where invoice_id = d5 and message like 'notice:%') = 2;
  alter table public.commission_notices drop constraint t21_always_fails;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a failing notice is written to commission_rebuild_errors; the invoice still saves and the line still matures\n', case when ok then 'PASS' else 'FAIL' end);

  -- 7. structure and access
  ok := exists (select 1 from pg_trigger where tgrelid = 'public.commissions'::regclass and tgname = 'commissions_matured_notice' and not tgisinternal)
        and not exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
                         where s.nspname = 'private' and p.proname in ('commission_matured_notice', 'setting_on') and not (coalesce(p.proconfig, '{}') @> array['search_path=""']))
        and not has_table_privilege('authenticated', 'private.settings', 'select') and not has_table_privilege('anon', 'private.settings', 'select')
        and not has_function_privilege('authenticated', 'private.setting_on(text)', 'execute')
        and has_table_privilege('authenticated', 'public.commission_notices', 'select') and not has_table_privilege('authenticated', 'public.commission_notices', 'insert')
        and not has_table_privilege('anon', 'public.commission_notices', 'select')
        and (select count(*) from pg_policies where tablename = 'commission_notices') = 1;
  failures := failures + (not ok)::int;
  report := report || format(E'%s the trigger exists; the functions have a fixed search path; the settings are not reachable from outside; the outbox is staff-read only\n', case when ok then 'PASS' else 'FAIL' end);

  raise exception E'TEST REPORT (021 commission notices): % failure(s)\n%', failures, report;
end $$;
