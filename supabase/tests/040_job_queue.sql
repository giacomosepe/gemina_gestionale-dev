-- Job queue (PM-151). One DO block, rolled back by the final RAISE. Needs an admin (the seed adds one).
do $$
declare
  id1 bigint; id2 bigint; m record; res text; n int; i int;
  report text := ''; failures int := 0;
begin
  -- 1. a job that fails twice and then succeeds ----------------------------------------------------------------------------------
  id1 := private.enqueue_job('test.flaky', '{"x":1}');
  for i in 1..2 loop
    select * into m from private.jobs_claim(10, 60) where msg_id = id1;
    res := private.job_fail(id1, 'boom ' || i);
    if m.msg_id is null or res <> 'retry' then failures := failures + 1; report := report || format(E'\nFAIL attempt %s: claimed=%s result=%s', i, m.msg_id is not null, res); end if;
    if exists (select 1 from private.jobs_claim(10, 60) where msg_id = id1) then failures := failures + 1; report := report || E'\nFAIL a failed job came back at once (no wait)'; end if;
    perform pgmq.set_vt('jobs', id1, 0);                                   -- skip the wait
  end loop;
  select * into m from private.jobs_claim(10, 60) where msg_id = id1;
  if m.msg_id is null or m.read_ct <> 3 then failures := failures + 1; report := report || E'\nFAIL third attempt not offered';
  else perform private.job_done(id1); report := report || E'\nok   failed twice, third attempt succeeded'; end if;
  select count(*) into n from pgmq.q_jobs where msg_id = id1;
  if n <> 0 then failures := failures + 1; report := report || E'\nFAIL finished job still in the queue'; end if;

  -- 2. a job that always fails goes dead after 5 attempts and raises the alert --------------------------------------------------
  id2 := private.enqueue_job('test.broken', '{}');
  for i in 1..5 loop
    select * into m from private.jobs_claim(10, 60) where msg_id = id2;
    res := private.job_fail(id2, 'always broken');
    perform pgmq.set_vt('jobs', id2, 0);
  end loop;
  if res <> 'dead' then failures := failures + 1; report := report || format(E'\nFAIL 5th failure returned %s', res); end if;
  if (select count(*) from pgmq.q_jobs where msg_id = id2) <> 0 then failures := failures + 1; report := report || E'\nFAIL dead job still in jobs'; end if;
  if (select count(*) from pgmq.q_jobs_dead where message ->> 'kind' = 'test.broken') <> 1 then failures := failures + 1; report := report || E'\nFAIL dead job not in jobs_dead'; end if;
  if (select count(*) from private.job_failures where msg_id = id2 and attempts = 5) <> 1 then failures := failures + 1; report := report || E'\nFAIL failure not recorded'; end if;
  if (select count(*) from pgmq.q_jobs where message ->> 'kind' = 'alert') <> 1 then failures := failures + 1; report := report || E'\nFAIL no alert job queued'; end if;
  if (select count(*) from public.notifications where event = 'jobs' and event_key like 'job-dead:' || id2 || '%') < 1 then failures := failures + 1; report := report || E'\nFAIL admins got no bell'; end if;
  report := report || E'\nok   always-failing job: 5 tries, dead letter, record, alert, bell';

  -- 3. a failed alert job never raises another alert
  perform pgmq.delete('jobs', (select msg_id from pgmq.q_jobs where message ->> 'kind' = 'alert'));
  id1 := private.enqueue_job('alert', '{"subject":"s","text":"t"}');
  for i in 1..5 loop
    perform * from private.jobs_claim(10, 60) where msg_id = id1;
    res := private.job_fail(id1, 'mail down');
    perform pgmq.set_vt('jobs', id1, 0);
  end loop;
  if res <> 'dead' or (select count(*) from pgmq.q_jobs where message ->> 'kind' = 'alert') <> 0 then failures := failures + 1; report := report || E'\nFAIL a dead alert raised another alert';
  else report := report || E'\nok   a dead alert raises nothing more'; end if;

  -- 4. the watchdog turns a failed cron run into one alert, once ------------------------------------------------------------------
  insert into cron.job_run_details (jobid, runid, job_pid, database, username, command, status, return_message, start_time, end_time)
    select jobid, 987654321, 1, 'postgres', 'postgres', 'select 1', 'failed', 'test failure', now(), now() from cron.job where jobname = 'message-emails-sweep';
  n := private.check_cron_failures();
  if n <> 1 or private.check_cron_failures() <> 0 then failures := failures + 1; report := report || format(E'\nFAIL watchdog gave %s then another run gave more', n);
  else report := report || E'\nok   watchdog: one alert per failed run'; end if;

  -- 5. nobody outside the database reaches the queue
  if has_function_privilege('authenticated', 'private.enqueue_job(text,jsonb,integer)', 'execute') or has_schema_privilege('authenticated', 'pgmq', 'usage')
     or has_function_privilege('anon', 'private.jobs_claim(integer,integer)', 'execute') then
    failures := failures + 1; report := report || E'\nFAIL signed-in or anonymous users reach the queue';
  else report := report || E'\nok   queue closed to API roles'; end if;

  raise exception 'TEST REPORT 040 job queue: % failure(s)%', failures, report;
end $$;
