-- Step 6, stage 1 (2026-10-21): referrer messages (segnalatori) move from Zite to Supabase.
-- Plan: claude/2026-10-21-piano-step6-messaggi.md (revision 2) in the project folder.
--
-- What changes:
-- 1. A referrer conversation is identified by its subject: one per referrer and subject (Zite threads are grouped by subject,
--    and files in Zite point at a thread by that text).
-- 2. Recipients = the colleagues taking part (conversation_members), as the trigger already did. The colleague the referrer
--    chooses is added as a member when the conversation starts (bridge v6, start_partner_conversation), so "every staff member"
--    stays only for the rare case where nobody of the team is left in the conversation.
-- 3. Referrers no longer create conversations straight from a browser: the portal's Zite endpoint checks the colleague, pratica
--    and azienda, then the bridge creates it. Messages inside their own conversations are still written directly.
-- 4. Read state is per side, not per person: read by anyone at Gemina (staff_read_at), read by the referrer (partner_read_at).
--    conversation_members now only means "taking part" (gets the notifications). public.mark_conversation_read() sets them.
-- 5. public.partner_threads(): every referrer conversation the caller can see, with unread count and colleagues (one call).
--    public.staff_colleagues(): names of the current team, for the portal's colleague picker (no emails).
-- 6. Emails (sent by the Edge Function message-emails, stage 2): the trigger asks for the referrer email at once, pg_cron every
--    5 minutes for the rest (team after 15 minutes unread, referrer at most once per conversation every 10 minutes, never if read).
--    The function address and an internal secret live in Vault (secret generated here, never written in a file). Until the
--    address 'functions_url' is stored in Vault, nothing is called.
-- 7. History import: with `select set_config('gemina.import', 'on', true)` (transaction only, never session-wide) and no
--    logged-in user, the trigger records who took part but sends no notification and asks for no email.
-- 8. A message's time and Zite id are set by the server (a browser cannot backdate, postdate or claim a Zite id), except
--    in the import. Times use clock_timestamp(), so messages written in one transaction keep their order.
-- Only additive or replacing statements (the connector Claude uses refuses destructive ones).

-- 1. Extensions -----------------------------------------------------------------------------------------------------------------
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

-- 2. Columns and indexes --------------------------------------------------------------------------------------------------------
alter table public.conversations
  add column zite_azienda_id    text check (char_length(zite_azienda_id) <= 100),
  add column staff_read_at      timestamptz,
  add column partner_read_at    timestamptz,
  add column partner_emailed_at timestamptz;

comment on column public.conversations.zite_azienda_id is 'Zite azienda the conversation is about ("Riguarda"), optional';
comment on column public.conversations.staff_read_at is 'Last time anyone of the Gemina team read the conversation';
comment on column public.conversations.partner_read_at is 'Last time the referrer (or client) read the conversation';
comment on column public.conversations.partner_emailed_at is 'Last email to the referrer about this conversation (at most one per 10 minutes)';
comment on table public.conversation_members is 'People taking part in a conversation: staff here get its notifications. last_read_at is legacy (read state is on conversations).';

create index conversations_zite_azienda_id_idx on public.conversations (zite_azienda_id);
create unique index conversations_partner_title_key on public.conversations (partner_id, lower(btrim(title))) where kind = 'partner';

alter table public.messages
  add column zite_messaggio_id text check (char_length(zite_messaggio_id) <= 100);
comment on column public.messages.zite_messaggio_id is 'Id of the Zite Messaggi row it was copied from (history import), so a copy can run twice safely';
create unique index messages_zite_messaggio_id_key on public.messages (zite_messaggio_id) where zite_messaggio_id is not null;

comment on column public.notifications.link is 'Where the bell takes the user: Zite vaiA for kind event (e.g. pratica:<id>), segnalatore:<zite id> or messaggi for kind message';

-- 3. Referrers create conversations only through the bridge ---------------------------------------------------------------------
alter policy "conversations: partner creates own" on public.conversations with check (false);

-- 4. Emails: ask the Edge Function (never fails the caller) ---------------------------------------------------------------------
select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'message_emails_secret',
                           'Shared by the database and the Edge Function message-emails')
 where not exists (select 1 from vault.secrets where name = 'message_emails_secret');

create function private.request_message_emails(p_mode text, p_conversation_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  fn_url text;
  secret text;
begin
  select decrypted_secret into fn_url from vault.decrypted_secrets where name = 'functions_url';
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'message_emails_secret';
  if fn_url is null or secret is null then
    return;  -- not configured on this project yet: nothing to do
  end if;
  perform net.http_post(
    url := rtrim(fn_url, '/') || '/message-emails',
    body := jsonb_build_object('mode', p_mode, 'conversation_id', p_conversation_id),
    headers := jsonb_build_object('content-type', 'application/json', 'x-email-secret', secret),
    timeout_milliseconds := 5000);
exception when others then
  raise warning 'request_message_emails: %', sqlerrm;
end $$;

-- 5a. Server-set values on a new message ---------------------------------------------------------------------------------------
-- Runs before the send limit (triggers fire in name order), so the limit counts the real time.
create function private.messages_server_values() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null and coalesce(current_setting('gemina.import', true), '') = 'on' then
    return new;  -- history import: keeps the original time and Zite id
  end if;
  new.created_at := clock_timestamp();
  new.zite_messaggio_id := null;
  return new;
end $$;

create trigger messages_a_server_values
  before insert on public.messages
  for each row execute function private.messages_server_values();

-- 5b. Who gets notified, read state, email at once ----------------------------------------------------------------------------
-- Same rule as 20261019194605 (staff recipients = current staff taking part, minus the sender; if no current staff takes part
-- and the sender is not staff, every staff member), plus: a link on each notification, the read state of the sender's side,
-- the request for the referrer email, and the history import mode.
create or replace function private.notify_on_message() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  c public.conversations%rowtype;
  sender_is_staff boolean;
  staff_involved boolean;
  importing boolean := (select auth.uid()) is null and coalesce(current_setting('gemina.import', true), '') = 'on';
  link_staff text;
begin
  select * into c from public.conversations where id = new.conversation_id;
  select exists (select 1 from public.profiles where id = new.sender_id and role = 'staff')
    into sender_is_staff;
  select sender_is_staff or exists (
    select 1 from public.conversation_members cm
      join public.profiles p on p.id = cm.profile_id
     where cm.conversation_id = c.id and p.role = 'staff'
  ) into staff_involved;

  -- the staff sender takes part from now on
  if sender_is_staff then
    insert into public.conversation_members (conversation_id, profile_id, last_read_at)
    values (c.id, new.sender_id, new.created_at)
    on conflict (conversation_id, profile_id) do update set last_read_at = excluded.last_read_at;
  end if;

  if importing then
    return new;  -- history copy: read state is set by the import itself, no notification, no email
  end if;

  -- whoever writes has read the conversation for their side: read time and bell entries (before this message's own
  -- notifications are created, so those stay unread)
  if sender_is_staff then
    update public.conversations
       set staff_read_at = greatest(coalesce(staff_read_at, '-infinity'::timestamptz), new.created_at)
     where id = c.id;
    update public.notifications n set read_at = clock_timestamp()
     where n.conversation_id = c.id and n.kind = 'message' and n.read_at is null
       and exists (select 1 from public.profiles p where p.id = n.recipient_id and p.role = 'staff');
  elsif new.sender_id is not null then
    update public.conversations
       set partner_read_at = greatest(coalesce(partner_read_at, '-infinity'::timestamptz), new.created_at)
     where id = c.id;
    update public.notifications set read_at = clock_timestamp()
     where conversation_id = c.id and kind = 'message' and recipient_id = new.sender_id and read_at is null;
  end if;

  if c.kind = 'partner' then
    select 'segnalatore:' || pa.zite_segnalatore_id into link_staff
      from public.partners pa where pa.id = c.partner_id;
  end if;

  insert into public.notifications
    (organization_id, recipient_id, kind, actor_id, conversation_id, message_id, label, link)
  select c.organization_id, p.id, 'message', new.sender_id, c.id, new.id, left(c.title, 300),
         case when p.role = 'staff' then link_staff
              when c.kind = 'partner' then 'messaggi' end
    from public.profiles p
   where p.id is distinct from new.sender_id
     and (
       (p.role = 'staff' and p.organization_id = c.organization_id
         and (not staff_involved or exists (
           select 1 from public.conversation_members cm
            where cm.conversation_id = c.id and cm.profile_id = p.id)))
       or (not new.internal and c.kind = 'partner' and exists (
           select 1 from public.partner_members pm
            where pm.partner_id = c.partner_id and pm.profile_id = p.id))
       or (not new.internal and c.kind = 'client' and exists (
           select 1 from public.company_members m
            where m.company_id = c.company_id and m.profile_id = p.id))
     );

  -- Gemina wrote to a referrer: email at once, unless one went out for this conversation in the last 10 minutes
  -- (the 5-minute sweep then covers it, and only if still unread). The Edge Function checks again before sending.
  if c.kind = 'partner' and sender_is_staff and not new.internal
     and (c.partner_emailed_at is null or c.partner_emailed_at < now() - interval '10 minutes') then
    perform private.request_message_emails('message', c.id);
  end if;
  return new;
end $$;

-- 6. Marking a conversation read (anyone at Gemina reads it for the whole team) -----------------------------------------------
create function public.mark_conversation_read(p_conversation_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  c public.conversations%rowtype;
begin
  select * into c from public.conversations where id = p_conversation_id;
  if uid is null or not found or not private.can_access_scope(c.kind, c.company_id, c.partner_id) then
    raise exception 'conversation not found' using errcode = '42501';
  end if;
  if private.is_staff() then
    update public.conversations set staff_read_at = clock_timestamp() where id = c.id;
    update public.notifications n set read_at = clock_timestamp()
     where n.conversation_id = c.id and n.kind = 'message' and n.read_at is null
       and exists (select 1 from public.profiles p where p.id = n.recipient_id and p.role = 'staff');
  else
    update public.conversations set partner_read_at = clock_timestamp() where id = c.id;
    update public.notifications set read_at = clock_timestamp()
     where conversation_id = c.id and kind = 'message' and recipient_id = uid and read_at is null;
  end if;
end $$;

-- 7. Referrer conversations in one call -----------------------------------------------------------------------------------------
-- Staff: every referrer conversation (or one referrer's with p_partner_id). Referrer: their own. Unread = messages from the
-- other side after that side last read. Internal notes never count for, or reach, a referrer.
create function public.partner_threads(p_partner_id uuid default null)
returns table (
  id uuid, title text, partner_id uuid, partner_name text, zite_segnalatore_id text,
  zite_azienda_id text, zite_pratica_id text, created_at timestamptz,
  last_message_at timestamptz, last_from_gemina boolean, unread int, taking_part boolean, colleagues text[]
)
language sql stable security definer set search_path = '' as $$
  with me as (select (select auth.uid()) as uid, private.is_staff() as staff)
  select c.id, c.title, c.partner_id, pa.name, pa.zite_segnalatore_id,
         c.zite_azienda_id, c.zite_pratica_id, c.created_at,
         lm.created_at, lm.from_gemina,
         (select count(*)::int from public.messages m
           where m.conversation_id = c.id and m.deleted_at is null and not m.internal
             and case when me.staff
                      then m.created_at > coalesce(c.staff_read_at, '-infinity'::timestamptz)
                           and not exists (select 1 from public.profiles s
                                            where s.id = m.sender_id and s.role in ('staff', 'former_staff'))
                      else m.created_at > coalesce(c.partner_read_at, '-infinity'::timestamptz)
                           and m.sender_id is distinct from me.uid
                 end),
         me.staff and exists (select 1 from public.conversation_members cm
                               where cm.conversation_id = c.id and cm.profile_id = me.uid),
         array_remove(array(
           select nullif(trim(coalesce(p.name_first, '') || ' ' || coalesce(p.name_last, '')), '')
             from public.conversation_members cm
             join public.profiles p on p.id = cm.profile_id
            where cm.conversation_id = c.id and p.role = 'staff'
            order by cm.created_at, p.id), null)
    from me
    cross join public.conversations c
    join public.partners pa on pa.id = c.partner_id
    left join lateral (
      select m.created_at,
             exists (select 1 from public.profiles s
                      where s.id = m.sender_id and s.role in ('staff', 'former_staff')) as from_gemina
        from public.messages m
       where m.conversation_id = c.id and m.deleted_at is null and (me.staff or not m.internal)
       order by m.created_at desc, m.id desc
       limit 1) lm on true
   where me.uid is not null
     and c.kind = 'partner'
     and (p_partner_id is null or c.partner_id = p_partner_id)
     and (me.staff or private.is_partner_member(c.partner_id))
   order by coalesce(lm.created_at, c.created_at) desc;
$$;

-- 8. The current team, for the portal's colleague picker (names only) ---------------------------------------------------------
create function public.staff_colleagues() returns table (id uuid, name text)
language sql stable security definer set search_path = '' as $$
  select p.id,
         coalesce(nullif(trim(coalesce(p.name_first, '') || ' ' || coalesce(p.name_last, '')), ''), 'Gemina Advisory')
    from public.profiles p
   where p.role = 'staff'
     and (private.is_staff()
          or exists (select 1 from public.partner_members pm where pm.profile_id = (select auth.uid())))
   order by 2;
$$;

-- 9. Privileges -----------------------------------------------------------------------------------------------------------------
revoke execute on function private.request_message_emails(text, uuid) from public, anon, authenticated;
revoke execute on function private.messages_server_values() from public, anon, authenticated;
revoke execute on function private.notify_on_message() from public, anon, authenticated;
revoke execute on function public.mark_conversation_read(uuid) from public, anon;
revoke execute on function public.partner_threads(uuid) from public, anon;
revoke execute on function public.staff_colleagues() from public, anon;
grant execute on function public.mark_conversation_read(uuid) to authenticated;
grant execute on function public.partner_threads(uuid) to authenticated;
grant execute on function public.staff_colleagues() to authenticated;

-- 10. Every 5 minutes: emails still due (team after 15 minutes, referrer after the 10-minute window) -----------------------------
select cron.schedule('message-emails-sweep', '*/5 * * * *', $cron$select private.request_message_emails('sweep', null)$cron$);

-- 11. Live: read state and new conversations reach open pages ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'conversations') then
    alter publication supabase_realtime add table public.conversations;
  end if;
end $$;
