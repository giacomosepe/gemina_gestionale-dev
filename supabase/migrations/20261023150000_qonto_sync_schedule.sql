-- Nightly Qonto sync and failure alert (Linear PRDDISC-5, milestone M1). Additive: new functions and two new cron jobs.
--
-- 1. Job qonto-sync-nightly (every hour at :00). The Zite sync runs daily at 02:00 Europe/Rome; like pratica-reminders, the job
--    runs every hour and the function waits for the Rome clock (summer and winter time alike): from 02:00 Rome on it starts the
--    sync once a day. If that run fails (or never finishes), it is tried again at the next hours, up to 3 runs a day. If the
--    database was down at 02:00 the first tick after it starts the day's run.
--    The call is the same as message-emails-sweep: pg_net, the address 'functions_url' and the secret 'qonto_sync_secret' from
--    Vault (no secret in this file); until both exist nothing is called.
-- 2. Job qonto-sync-check (every hour at :20): if the latest qonto_sync_runs row failed (error, or started and never finished
--    for 15 minutes) or started more than 26 hours ago, every admin (profiles.staff_role = 'admin') gets one bell notification
--    (kind 'event', event 'qonto-sync'). event_key holds the problem, the run and the admin, so a problem is announced once
--    however many hours the check runs; a new failure (new run) or a new silence (after a new good run) is announced again.
--    No email. With no run at all there is nothing to compare: the check stays quiet.

-- 1. Request ----------------------------------------------------------------------------------------------------------------------
create function private.request_qonto_sync() returns void
language plpgsql security definer set search_path = '' as $$
declare
  fn_url text;
  secret text;
begin
  select decrypted_secret into fn_url from vault.decrypted_secrets where name = 'functions_url';
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'qonto_sync_secret';
  if fn_url is null or secret is null then
    return;  -- not configured on this project yet: nothing to do
  end if;
  perform net.http_post(
    url := rtrim(fn_url, '/') || '/qonto-sync',
    body := '{}'::jsonb,
    headers := jsonb_build_object('content-type', 'application/json', 'x-sync-secret', secret),
    timeout_milliseconds := 120000);
exception when others then
  raise warning 'request_qonto_sync: %', sqlerrm;
end $$;

-- 2. Is today's sync due? ---------------------------------------------------------------------------------------------------------
create function private.qonto_sync_due(p_now timestamptz default now()) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  rome_now  timestamp := p_now at time zone 'Europe/Rome';
  day_start timestamptz := (date_trunc('day', rome_now) + interval '2 hours') at time zone 'Europe/Rome';
  runs      int;
  last_run  public.qonto_sync_runs%rowtype;
begin
  if extract(hour from rome_now) < 2 then
    return false;
  end if;
  select count(*) into runs from public.qonto_sync_runs where started_at >= day_start and started_at <= p_now;
  if runs = 0 then
    return true;
  end if;
  select * into last_run from public.qonto_sync_runs
   where started_at >= day_start and started_at <= p_now order by started_at desc limit 1;
  if last_run.finished_at is null and last_run.started_at > p_now - interval '15 minutes' then
    return false;  -- still running
  end if;
  -- failed (error, or never finished): try again, at most 3 runs a day
  return (last_run.error is not null or last_run.finished_at is null) and runs < 3;
end $$;

create function private.qonto_sync_nightly(p_now timestamptz default now()) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if private.qonto_sync_due(p_now) then
    perform private.request_qonto_sync();
    return true;
  end if;
  return false;
end $$;

-- 3. The check: a bell for admins when the sync failed or went silent ----------------------------------------------------------
create function private.check_qonto_sync(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  last_run public.qonto_sync_runs%rowtype;
  problem  text;
  label    text;
  bells    int;
begin
  select * into last_run from public.qonto_sync_runs where started_at <= p_now order by started_at desc limit 1;
  if not found then
    return 0;
  end if;
  if last_run.error is not null or (last_run.finished_at is null and last_run.started_at < p_now - interval '15 minutes') then
    problem := 'error';
    label := 'Sincronizzazione Qonto non riuscita'
             || coalesce(': ' || left(regexp_replace(last_run.error, '\s+', ' ', 'g'), 150), '');
  elsif last_run.started_at < p_now - interval '26 hours' then
    problem := 'stale';
    label := format('Sincronizzazione Qonto ferma: ultimo aggiornamento il %s',
                    to_char(last_run.started_at at time zone 'Europe/Rome', 'DD/MM/YYYY HH24:MI'));
  else
    return 0;
  end if;

  insert into public.notifications (organization_id, recipient_id, kind, event, label, event_key)
  select p.organization_id, p.id, 'event', 'qonto-sync', left(label, 300),
         left(format('qonto-sync:%s:%s:%s', problem, last_run.id, p.id), 100)
    from public.profiles p
   where p.role = 'staff' and p.staff_role = 'admin'
  on conflict do nothing;
  get diagnostics bells = row_count;
  return bells;
end $$;

revoke execute on function private.request_qonto_sync() from public, anon, authenticated;
revoke execute on function private.qonto_sync_due(timestamptz) from public, anon, authenticated;
revoke execute on function private.qonto_sync_nightly(timestamptz) from public, anon, authenticated;
revoke execute on function private.check_qonto_sync(timestamptz) from public, anon, authenticated;

-- 4. Jobs -------------------------------------------------------------------------------------------------------------------------
select cron.schedule('qonto-sync-nightly', '0 * * * *', $cron$select private.qonto_sync_nightly()$cron$);
select cron.schedule('qonto-sync-check', '20 * * * *', $cron$select private.check_qonto_sync()$cron$);
