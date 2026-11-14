-- Job queue with retries (Linear PM-151). pgmq holds the jobs; the Edge Function `jobs` runs them; this file holds the rules in SQL so they can be tested:
--   * a job that fails is tried again after a wait that doubles (30 s, 1 min, 2 min, 4 min), up to 5 tries;
--   * after the 5th failure it moves to the dead-letter queue `jobs_dead`, is recorded in private.job_failures, and every admin gets a bell;
--     an `alert` job also goes to the queue so that the runner can email it (a failed alert job never raises another alert);
--   * a watchdog turns failed pg_cron runs (the existing Qonto, message and reminder jobs) into the same alert.
-- The existing cron jobs are not touched: they keep calling their functions directly.

create extension if not exists pgmq;
select pgmq.create('jobs');
select pgmq.create('jobs_dead');

-- the queues are for the database and the runner only
revoke all on schema pgmq from public, anon, authenticated;
revoke all on all tables in schema pgmq from public, anon, authenticated;
revoke all on all functions in schema pgmq from public, anon, authenticated;

create table private.job_failures (
  id        bigint generated always as identity primary key,
  failed_at timestamptz not null default now(),
  msg_id    bigint not null,
  kind      text,
  attempts  int not null,
  error     text,
  payload   jsonb
);
alter table private.job_failures enable row level security;

-- Bell for every admin (the same shape as the Qonto sync check). Returns how many bells were new.
create function private.notify_admins(p_event text, p_label text, p_key text) returns integer
language plpgsql security definer set search_path = '' as $$
declare bells int;
begin
  insert into public.notifications (organization_id, recipient_id, kind, event, label, event_key)
  select p.organization_id, p.id, 'event', p_event, left(p_label, 300), left(p_key || ':' || p.id, 100)
    from public.profiles p where p.role = 'staff' and p.staff_role = 'admin'
  on conflict do nothing;
  get diagnostics bells = row_count;
  return bells;
end $$;

create function private.enqueue_job(p_kind text, p_payload jsonb default '{}', p_delay_seconds integer default 0) returns bigint
language sql security definer set search_path = '' as $$
  select pgmq.send('jobs', jsonb_build_object('kind', p_kind, 'payload', coalesce(p_payload, '{}'::jsonb)), p_delay_seconds)
$$;

create function private.job_max_attempts() returns integer language sql immutable set search_path = '' as $$ select 5 $$;
create function private.job_backoff_seconds(p_attempt integer) returns integer
language sql immutable set search_path = '' as $$ select least(30 * (2 ^ greatest(p_attempt - 1, 0))::int, 1800) $$;

-- The runner takes jobs here: they stay invisible for p_visible_seconds; a job not finished by then comes back.
create function private.jobs_claim(p_qty integer default 10, p_visible_seconds integer default 120) returns setof pgmq.message_record
language sql security definer set search_path = '' as $$
  select * from pgmq.read('jobs', p_visible_seconds, p_qty)
$$;

create function private.job_done(p_msg_id bigint) returns boolean
language sql security definer set search_path = '' as $$ select pgmq.delete('jobs', p_msg_id) $$;

-- A job failed: wait and retry, or give up. Returns 'retry', 'dead' or 'gone' (the job no longer exists).
create function private.job_fail(p_msg_id bigint, p_error text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  m record;
  kind text;
begin
  select * into m from pgmq.q_jobs where msg_id = p_msg_id;
  if not found then return 'gone'; end if;
  kind := m.message ->> 'kind';

  if m.read_ct < private.job_max_attempts() then
    perform pgmq.set_vt('jobs', p_msg_id, private.job_backoff_seconds(m.read_ct));
    return 'retry';
  end if;

  insert into private.job_failures (msg_id, kind, attempts, error, payload)
    values (p_msg_id, kind, m.read_ct, left(p_error, 2000), m.message -> 'payload');
  perform pgmq.send('jobs_dead', m.message || jsonb_build_object('error', left(p_error, 2000), 'attempts', m.read_ct));
  perform pgmq.delete('jobs', p_msg_id);
  if kind is distinct from 'alert' then
    perform private.notify_admins('jobs', format('Un lavoro in background non è riuscito: %s', coalesce(kind, 'sconosciuto')), 'job-dead:' || p_msg_id);
    perform private.enqueue_job('alert', jsonb_build_object('subject', format('Lavoro non riuscito: %s', coalesce(kind, '?')),
                                                            'text', format('Il lavoro "%s" non è riuscito dopo %s tentativi. Ultimo errore: %s', kind, m.read_ct, left(p_error, 500))));
  end if;
  return 'dead';
end $$;

-- Failed pg_cron runs in the last p_since become one alert each (once: the bell key holds the run).
create function private.check_cron_failures(p_since interval default interval '15 minutes') returns integer
language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0;
begin
  for r in
    select d.runid, j.jobname, d.start_time, left(coalesce(d.return_message, ''), 300) as msg
      from cron.job_run_details d join cron.job j on j.jobid = d.jobid
     where d.status = 'failed' and d.start_time > now() - p_since and j.jobname <> 'jobs-runner'
  loop
    if private.notify_admins('jobs', format('Lavoro pianificato non riuscito: %s', r.jobname), 'cron-failed:' || r.runid) > 0 then
      perform private.enqueue_job('alert', jsonb_build_object('subject', format('Lavoro pianificato non riuscito: %s', r.jobname),
                                                              'text', format('Il lavoro pianificato "%s" è fallito il %s: %s', r.jobname, r.start_time, r.msg)));
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- The tick: when a job is waiting, wake the runner (pg_net, address and secret from Vault, as the other jobs do).
create function private.jobs_tick() returns void
language plpgsql security definer set search_path = '' as $$
declare fn_url text; secret text; waiting bigint;
begin
  select queue_visible_length into waiting from pgmq.metrics('jobs');
  if coalesce(waiting, 0) = 0 then return; end if;
  select decrypted_secret into fn_url from vault.decrypted_secrets where name = 'functions_url';
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'jobs_secret';
  if fn_url is null or secret is null then return; end if;
  perform net.http_post(url := rtrim(fn_url, '/') || '/jobs', body := '{}'::jsonb,
                        headers := jsonb_build_object('content-type', 'application/json', 'x-jobs-secret', secret),
                        timeout_milliseconds := 120000);
exception when others then
  raise warning 'jobs_tick: %', sqlerrm;
end $$;

revoke all on function private.notify_admins(text, text, text), private.enqueue_job(text, jsonb, integer), private.job_max_attempts(),
  private.job_backoff_seconds(integer), private.jobs_claim(integer, integer), private.job_done(bigint), private.job_fail(bigint, text),
  private.check_cron_failures(interval), private.jobs_tick() from public, anon, authenticated;

-- The secret the runner checks. Generated here, per project; never in the repo.
select vault.create_secret(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'jobs_secret', 'Secret of the jobs Edge Function')
 where not exists (select 1 from vault.secrets where name = 'jobs_secret');

select cron.schedule('jobs-runner', '* * * * *', $cron$select private.jobs_tick()$cron$);
select cron.schedule('jobs-watchdog', '*/15 * * * *', $cron$select private.check_cron_failures()$cron$);
