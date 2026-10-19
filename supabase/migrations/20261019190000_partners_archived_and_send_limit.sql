-- Fix the mismatch between portal-bridge v2 and the schema (found 2026-10-19).
-- 1. portal-bridge reads partners.archived: add it.
-- 2. portal-bridge maps SQLSTATE P0429 to "rate_limited": add the send limit.

-- 1. Archived referrers ------------------------------------------------------------
-- Set to true when the segnalatore is archived in Zite. The bridge then removes
-- the referrer's membership at their next login and refuses new sessions.
alter table public.partners
  add column if not exists archived boolean not null default false;

-- 2. Send limit on messages --------------------------------------------------------
-- Protects against floods (a bug in a page, a compromised account). Generous for
-- real use: 20 messages per minute and 300 per hour per sender, everyone included.
create index if not exists messages_sender_id_created_at_idx
  on public.messages (sender_id, created_at);
drop index if exists public.messages_sender_id_idx;  -- covered by the index above

create function private.enforce_message_send_limit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  last_minute int;
  last_hour   int;
begin
  if new.sender_id is null then
    return new;
  end if;
  select count(*) filter (where created_at > now() - interval '1 minute'),
         count(*)
    into last_minute, last_hour
    from public.messages
   where sender_id = new.sender_id
     and created_at > now() - interval '1 hour';
  if last_minute >= 20 or last_hour >= 300 then
    raise exception 'message send limit reached' using errcode = 'P0429';
  end if;
  return new;
end $$;

revoke execute on function private.enforce_message_send_limit() from public, anon, authenticated;

create trigger messages_send_limit
  before insert on public.messages
  for each row execute function private.enforce_message_send_limit();
