-- Nightly Qonto sync and failure alert (migration qonto_sync_schedule, PRDDISC-5): the two cron jobs, when a sync is due (Rome clock,
-- winter and summer time, retries), and the admin bell (once per problem). Same pattern as 001-010: one DO block, everything rolled back
-- by the final RAISE; the message is the report. Dates in 2027 are used so real runs never interfere; the functions ignore runs after
-- the given "now". The request itself (pg_net) is not called here.

do $$
declare
  u_adm    uuid := gen_random_uuid();
  u_mgr    uuid := gen_random_uuid();
  n        int;
  lbl      text;
  report   text := '';
  failures int := 0;
  ok       boolean;
  t        timestamptz;
begin
  insert into auth.users (id, email, aud, role) values
    (u_adm, 't11-adm@example.test', 'authenticated', 'authenticated'),
    (u_mgr, 't11-mgr@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'admin',   zite_user_id = 't11-zite-adm' where id = u_adm;
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 't11-zite-mgr' where id = u_mgr;

  -- jobs
  ok := exists (select 1 from cron.job where jobname = 'qonto-sync-nightly' and schedule = '0 * * * *')
        and exists (select 1 from cron.job where jobname = 'qonto-sync-check' and schedule = '20 * * * *');
  failures := failures + (not ok)::int;
  report := report || format(E'%s jobs qonto-sync-nightly and qonto-sync-check are in cron.job\n', case when ok then 'PASS' else 'FAIL' end);

  ok := not has_function_privilege('authenticated', 'private.check_qonto_sync(timestamptz)', 'execute')
        and not has_function_privilege('authenticated', 'private.qonto_sync_nightly(timestamptz)', 'execute')
        and not has_function_privilege('anon', 'private.request_qonto_sync()', 'execute');
  failures := failures + (not ok)::int;
  report := report || format(E'%s signed-in users and anonymous cannot call the job functions\n', case when ok then 'PASS' else 'FAIL' end);

  -- when is the sync due (Rome clock)
  ok := not private.qonto_sync_due(timestamptz '2027-01-15 01:30 Europe/Rome')
        and private.qonto_sync_due(timestamptz '2027-01-15 02:30 Europe/Rome');
  failures := failures + (not ok)::int;
  report := report || format(E'%s before 02:00 Rome nothing; from 02:00 with no run today it is due\n', case when ok then 'PASS' else 'FAIL' end);

  insert into public.qonto_sync_runs (started_at, finished_at) values (timestamptz '2027-01-16 02:00:30 Europe/Rome', timestamptz '2027-01-16 02:01 Europe/Rome');
  ok := not private.qonto_sync_due(timestamptz '2027-01-16 02:30 Europe/Rome') and not private.qonto_sync_due(timestamptz '2027-01-16 05:00 Europe/Rome');
  failures := failures + (not ok)::int;
  report := report || format(E'%s a good run today: not due again\n', case when ok then 'PASS' else 'FAIL' end);
  ok := private.qonto_sync_due(timestamptz '2027-01-17 02:30 Europe/Rome');
  failures := failures + (not ok)::int;
  report := report || format(E'%s a good run yesterday does not count: due again today\n', case when ok then 'PASS' else 'FAIL' end);

  insert into public.qonto_sync_runs (started_at) values (timestamptz '2027-01-17 02:25 Europe/Rome');
  ok := not private.qonto_sync_due(timestamptz '2027-01-17 02:30 Europe/Rome') and private.qonto_sync_due(timestamptz '2027-01-17 03:30 Europe/Rome');
  failures := failures + (not ok)::int;
  report := report || format(E'%s a run still going is left alone; one that never finished is retried\n', case when ok then 'PASS' else 'FAIL' end);

  insert into public.qonto_sync_runs (started_at, finished_at, error) values (timestamptz '2027-01-18 02:00 Europe/Rome', timestamptz '2027-01-18 02:00:05 Europe/Rome', 'boom');
  ok := private.qonto_sync_due(timestamptz '2027-01-18 03:30 Europe/Rome');
  insert into public.qonto_sync_runs (started_at, finished_at, error) values
    (timestamptz '2027-01-18 03:00 Europe/Rome', timestamptz '2027-01-18 03:00:05 Europe/Rome', 'boom'),
    (timestamptz '2027-01-18 04:00 Europe/Rome', timestamptz '2027-01-18 04:00:05 Europe/Rome', 'boom');
  ok := ok and not private.qonto_sync_due(timestamptz '2027-01-18 05:30 Europe/Rome');
  failures := failures + (not ok)::int;
  report := report || format(E'%s a failed run is retried, at most 3 runs a day\n', case when ok then 'PASS' else 'FAIL' end);

  ok := not private.qonto_sync_due(timestamptz '2027-03-28 01:30 Europe/Rome') and private.qonto_sync_due(timestamptz '2027-03-28 03:30 Europe/Rome');
  failures := failures + (not ok)::int;
  report := report || format(E'%s the day summer time starts (02:00 does not exist): due from 03:00\n', case when ok then 'PASS' else 'FAIL' end);

  -- the check: silence
  perform private.check_qonto_sync(timestamptz '2027-01-01 00:00 UTC');
  select count(*) into n from public.notifications where recipient_id = u_adm and event = 'qonto-sync';
  ok := n = 1 and not exists (select 1 from public.notifications where recipient_id = u_mgr and event = 'qonto-sync');
  failures := failures + (not ok)::int;
  report := report || format(E'%s latest run older than 26 hours: one bell for the admin, none for a manager (got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  perform private.check_qonto_sync(timestamptz '2027-01-01 01:00 UTC');
  perform private.check_qonto_sync(timestamptz '2027-01-01 02:00 UTC');
  select count(*) into n from public.notifications where recipient_id = u_adm and event = 'qonto-sync';
  ok := n = 1;
  failures := failures + (not ok)::int;
  report := report || format(E'%s the check running again does not repeat the bell (got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  -- the check: error
  insert into public.qonto_sync_runs (started_at, finished_at, error) values (timestamptz '2027-02-01 03:00 UTC', timestamptz '2027-02-01 03:00:05 UTC', E'Qonto /client_invoices -> 401:\n  bad login');
  perform private.check_qonto_sync(timestamptz '2027-02-01 04:00 UTC');
  perform private.check_qonto_sync(timestamptz '2027-02-01 05:00 UTC');
  select count(*) into n from public.notifications where recipient_id = u_adm and event = 'qonto-sync';
  select label into lbl from public.notifications where recipient_id = u_adm and event_key like 'qonto-sync:error:%';
  ok := n = 2 and lbl = 'Sincronizzazione Qonto non riuscita: Qonto /client_invoices -> 401: bad login';
  failures := failures + (not ok)::int;
  report := report || format(E'%s an error run: exactly one bell for the admin, even if checked twice (got %s, "%s")\n', case when ok then 'PASS' else 'FAIL' end, n, lbl);

  insert into public.qonto_sync_runs (started_at, finished_at, error) values (timestamptz '2027-02-01 05:30 UTC', timestamptz '2027-02-01 05:30:05 UTC', 'again');
  perform private.check_qonto_sync(timestamptz '2027-02-01 06:00 UTC');
  select count(*) into n from public.notifications where recipient_id = u_adm and event = 'qonto-sync';
  ok := n = 3;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a new failing run is announced again (got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  -- the check: healthy, then silent again
  insert into public.qonto_sync_runs (started_at, finished_at) values (timestamptz '2027-02-02 03:00 UTC', timestamptz '2027-02-02 03:00:20 UTC');
  ok := private.check_qonto_sync(timestamptz '2027-02-02 04:00 UTC') = 0
        and private.check_qonto_sync(timestamptz '2027-02-03 04:00 UTC') = 0;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a good run less than 26 hours ago: no bell\n', case when ok then 'PASS' else 'FAIL' end);
  perform private.check_qonto_sync(timestamptz '2027-02-03 12:00 UTC');
  select count(*) into n from public.notifications where recipient_id = u_adm and event = 'qonto-sync';
  ok := n = 4;
  failures := failures + (not ok)::int;
  report := report || format(E'%s silence after a good run is announced once more (got %s)\n', case when ok then 'PASS' else 'FAIL' end, n);

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
