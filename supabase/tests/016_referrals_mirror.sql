-- Referrals mirror (migration referrals_mirror, PRDDISC-13): private.sync_referrals (insert, update, removed, restored, mark missing), partner and company resolved,
-- private.referral_active_on (Zite attiva rule), staff-only read, no browser write. Same pattern as 001-015: rolled back by the final RAISE. Made-up rows only.

do $$
declare
  u_s1     uuid := gen_random_uuid();
  u_ref    uuid := gen_random_uuid();
  org      uuid := (select id from public.organizations limit 1);
  p_ref    uuid;
  p1       uuid;
  c1       uuid;
  ra       uuid := gen_random_uuid();   -- from 2026-09-01, no end
  rb       uuid := gen_random_uuid();   -- 2026-01-01 .. 2027-12-31
  rc       uuid := gen_random_uuid();   -- no start, ends 2026-06-30
  rd       uuid := gen_random_uuid();   -- unknown partner and azienda
  re       uuid := gen_random_uuid();
  res      jsonb;
  r        record;
  n        int;
  report   text := '';
  failures int := 0;
  ok       boolean;
begin
  insert into auth.users (id, email, aud, role) values
    (u_s1,  't16-s1@example.test',  'authenticated', 'authenticated'),
    (u_ref, 't16-ref@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't16-zite-s1' where id = u_s1;
  update public.profiles set role = 'partner' where id = u_ref;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t16-ref', 'Test referrer 16', 't16-ref@example.test', org) returning id into p_ref;
  insert into public.partner_members (partner_id, profile_id) values (p_ref, u_ref);
  p1 := p_ref;
  insert into public.companies (name, zite_azienda_id, organization_id) values ('Test company 16', 't16-azienda', org) returning id into c1;

  ok := (select relrowsecurity from pg_class where oid = 'public.referrals'::regclass)
        and (select data_type from information_schema.columns where table_schema = 'public' and table_name = 'referrals' and column_name = 'id') = 'uuid';
  failures := failures + (not ok)::int;
  report := report || format(E'%s RLS on; id is a uuid (the Zite record UUID)\n', case when ok then 'PASS' else 'FAIL' end);

  res := private.sync_referrals(jsonb_build_array(
    jsonb_build_object('id', ra, 'zite_segnalatore_id', 't16-ref', 'zite_azienda_id', 't16-azienda', 'commission_pct', 20, 'starts_on', '2026-09-01', 'duration_years', null, 'ends_on', null, 'removed', false),
    jsonb_build_object('id', rb, 'zite_segnalatore_id', 't16-ref', 'zite_azienda_id', 't16-azienda', 'commission_pct', 10.5, 'starts_on', '2026-01-01', 'duration_years', 2, 'ends_on', '2027-12-31', 'removed', false),
    jsonb_build_object('id', rc, 'zite_segnalatore_id', 't16-ref', 'zite_azienda_id', 't16-azienda', 'commission_pct', 15, 'starts_on', null, 'duration_years', 1, 'ends_on', '2026-06-30', 'removed', false),
    jsonb_build_object('id', rd, 'zite_segnalatore_id', 't16-unknown', 'zite_azienda_id', 't16-unknown', 'commission_pct', null, 'starts_on', null, 'duration_years', null, 'ends_on', null, 'removed', false)));
  select * into r from public.referrals where id = ra;
  ok := (res->>'inserted')::int = 4 and (res->>'updated')::int = 0 and r.partner_id = p1 and r.company_id = c1 and r.commission_pct = 20
        and r.starts_on = date '2026-09-01' and r.ends_on is null and r.removed_at is null
        and (select partner_id is null and company_id is null and commission_pct is null from public.referrals where id = rd)
        and (select commission_pct = 10.5 and duration_years = 2 and ends_on = date '2027-12-31' from public.referrals where id = rb);
  failures := failures + (not ok)::int;
  report := report || format(E'%s four referrals inserted; partner and company resolved (null when unknown); percentage, dates and duration as sent (%s)\n', case when ok then 'PASS' else 'FAIL' end, res);

  res := private.sync_referrals(jsonb_build_array(
    jsonb_build_object('id', ra, 'zite_segnalatore_id', 't16-ref', 'zite_azienda_id', 't16-azienda', 'commission_pct', 25, 'starts_on', '2026-09-01', 'duration_years', null, 'ends_on', null, 'removed', false)));
  ok := (res->>'inserted')::int = 0 and (res->>'updated')::int = 1 and (select commission_pct = 25 from public.referrals where id = ra);
  failures := failures + (not ok)::int;
  report := report || format(E'%s an edited percentage updates the same row (no duplicate)\n', case when ok then 'PASS' else 'FAIL' end);

  ok := (select partner_id is null from public.referrals where id = rd);
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t16-unknown', 'Test referrer 16b', 't16-refb@example.test', org);
  insert into public.companies (name, zite_azienda_id, organization_id) values ('Test company 16b', 't16-unknown', org);
  perform private.sync_referrals(jsonb_build_array(
    jsonb_build_object('id', rd, 'zite_segnalatore_id', 't16-unknown', 'zite_azienda_id', 't16-unknown', 'commission_pct', null, 'starts_on', null, 'duration_years', null, 'ends_on', null, 'removed', false)));
  ok := ok and (select partner_id is not null and company_id is not null from public.referrals where id = rd);
  failures := failures + (not ok)::int;
  report := report || format(E'%s a partner or company created later is picked up by the next sync\n', case when ok then 'PASS' else 'FAIL' end);

  -- the Zite rule (attiva): Dal <= date <= Scadenza, empty = open
  ok := private.referral_active_on(ra, date '2026-09-01') and not private.referral_active_on(ra, date '2026-08-31') and private.referral_active_on(ra, date '2099-01-01');
  failures := failures + (not ok)::int;
  report := report || format(E'%s from Dal on (inclusive), never before; no Scadenza = open end\n', case when ok then 'PASS' else 'FAIL' end);
  ok := private.referral_active_on(rb, date '2027-12-31') and not private.referral_active_on(rb, date '2028-01-01') and not private.referral_active_on(rb, date '2025-12-31') and private.referral_active_on(rb, date '2026-01-01');
  failures := failures + (not ok)::int;
  report := report || format(E'%s Scadenza is inclusive: active on the last day, not the day after\n', case when ok then 'PASS' else 'FAIL' end);
  ok := private.referral_active_on(rc, date '1999-01-01') and private.referral_active_on(rc, date '2026-06-30') and not private.referral_active_on(rc, date '2026-07-01');
  failures := failures + (not ok)::int;
  report := report || format(E'%s no Dal = open start\n', case when ok then 'PASS' else 'FAIL' end);
  ok := private.referral_active_on(rd, date '2026-10-01') and not private.referral_active_on(gen_random_uuid(), date '2026-10-01');
  failures := failures + (not ok)::int;
  report := report || format(E'%s no dates at all: always active; an unknown referral: never\n', case when ok then 'PASS' else 'FAIL' end);

  -- removed in Zite: kept, never active; then restored
  perform private.sync_referrals(jsonb_build_array(
    jsonb_build_object('id', ra, 'zite_segnalatore_id', 't16-ref', 'zite_azienda_id', 't16-azienda', 'commission_pct', 25, 'starts_on', '2026-09-01', 'duration_years', null, 'ends_on', null, 'removed', true)));
  ok := (select removed_at is not null from public.referrals where id = ra) and not private.referral_active_on(ra, date '2026-10-01');
  perform private.sync_referrals(jsonb_build_array(
    jsonb_build_object('id', ra, 'zite_segnalatore_id', 't16-ref', 'zite_azienda_id', 't16-azienda', 'commission_pct', 25, 'starts_on', '2026-09-01', 'duration_years', null, 'ends_on', null, 'removed', false)));
  ok := ok and (select removed_at is null from public.referrals where id = ra) and private.referral_active_on(ra, date '2026-10-01');
  failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalazione deleted in Zite is marked removed (never active), never deleted; it can come back\n', case when ok then 'PASS' else 'FAIL' end);

  -- repair: mark missing
  res := private.sync_referrals(jsonb_build_array(
    jsonb_build_object('id', ra, 'zite_segnalatore_id', 't16-ref', 'zite_azienda_id', 't16-azienda', 'commission_pct', 25, 'starts_on', '2026-09-01', 'duration_years', null, 'ends_on', null, 'removed', false)), true);
  ok := (select removed_at is not null from public.referrals where id = rb) and (select removed_at is null from public.referrals where id = ra) and (res->>'marked_removed')::int >= 1;
  failures := failures + (not ok)::int;
  report := report || format(E'%s the repair marks the segnalazioni missing from the list as removed and keeps the listed ones\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    perform private.sync_referrals('{"not":"array"}'::jsonb);
    ok := false;
  exception when invalid_parameter_value then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s anything but a json array is refused\n', case when ok then 'PASS' else 'FAIL' end);

  -- access
  perform set_config('request.jwt.claims', json_build_object('sub', u_s1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.referrals where id in (ra, rb, rc, rd);
  ok := n = 4;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff read the mirror (rows: %s)\n', case when ok then 'PASS' else 'FAIL' end, n);
  begin insert into public.referrals (id) values (re); ok := false; exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff cannot insert\n', case when ok then 'PASS' else 'FAIL' end);
  begin update public.referrals set commission_pct = 1 where id = ra; ok := false; exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff cannot update\n', case when ok then 'PASS' else 'FAIL' end);
  begin delete from public.referrals where id = ra; ok := false; exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff cannot delete\n', case when ok then 'PASS' else 'FAIL' end);
  begin perform private.sync_referrals('[]'::jsonb); ok := false; exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a signed-in user cannot call the sync function\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  ok := (select count(*) from public.referrals) = 0;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a partner reads zero rows\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  set local role anon;
  begin perform count(*) from public.referrals; ok := false; exception when insufficient_privilege then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s anonymous cannot read\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
