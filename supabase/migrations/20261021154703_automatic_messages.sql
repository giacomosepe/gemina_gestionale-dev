-- Step 7 follow-up (2026-10-21): automatic messages from Gemina Advisory on Supabase.
-- The Zite server writes some messages to segnalatori by itself: "Segnalazione approvata: …" when an azienda is approved and
-- "Provvigione maturata: …" when an invoice is paid (often from the Qonto sync, with nobody logged in). Until now they reached
-- only the Zite table, so a segnalatore on Supabase would not see them. Decided by Giacomo: they are signed "Gemina Advisory",
-- not by a person.
-- - messages.automatic: true only for these (no sender). Only full-rights callers (the bridge, action post_automatic_message)
--   can set it; a browser insert always has it false.
-- - notify_on_message: an automatic message notifies only the segnalatore (bell), leaves Gemina's read state alone (a question
--   of the segnalatore before it stays unread for the team) and asks for no email (the Zite endpoint sends its own email with the specific text). Nobody of the team takes part because of it,
--   so a reply from the segnalatore reaches the whole current team (rule B of step 6).
-- - partner_threads: an automatic message counts as from Gemina (never unread for the team).
-- - Also (review of step 7): "Notifica segnalatore" refuses a second press within a minute (double click, two tabs), so the
--   segnalatore never gets the same email twice.
-- Only additive or replacing statements.

alter table public.messages add column automatic boolean not null default false;
comment on column public.messages.automatic is 'Automatic message signed Gemina Advisory (no sender); set only by the server (portal-bridge)';
alter table public.messages add constraint messages_automatic_no_sender check (not automatic or sender_id is null);

-- Browser inserts can never mark a message automatic.
create or replace function private.messages_server_values() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is not null or coalesce((select auth.role()), '') = 'authenticated' then
    new.automatic := false;
  end if;
  if (select auth.uid()) is null and coalesce(current_setting('gemina.import', true), '') = 'on' then
    return new;  -- history import: keeps the original time and Zite id
  end if;
  new.created_at := clock_timestamp();
  new.zite_messaggio_id := null;
  return new;
end $$;

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
  -- An automatic message (Gemina Advisory, no person; only the bridge writes them): the segnalatore's bell only. No colleague is
  -- notified, Gemina's read state does not move (it never counts as unread for the team: partner_threads skips it), no email is
  -- requested (the Zite endpoint sends its own, specific one).
  if new.automatic then
    if importing then
      return new;
    end if;
    if c.kind = 'partner' and not new.internal then
      insert into public.notifications
        (organization_id, recipient_id, kind, actor_id, conversation_id, message_id, label, link)
      select c.organization_id, pm.profile_id, 'message', null, c.id, new.id, left(c.title, 300), 'messaggi'
        from public.partner_members pm
       where pm.partner_id = c.partner_id;
    end if;
    return new;
  end if;
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

-- Referrer conversations in one call -----------------------------------------------------------------------------------------
-- Staff: every referrer conversation (or one referrer's with p_partner_id). Referrer: their own. Unread = messages from the
-- other side after that side last read. Internal notes never count for, or reach, a referrer.
create or replace function public.partner_threads(p_partner_id uuid default null)
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
                           and not m.automatic
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
             (m.automatic or exists (select 1 from public.profiles s
                                      where s.id = m.sender_id and s.role in ('staff', 'former_staff'))) as from_gemina
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

create or replace function public.notify_document(p_document_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  d public.documents%rowtype;
begin
  select * into d from public.documents where id = p_document_id for update;
  if not private.is_staff() or not found or d.kind <> 'partner' or not d.shared or d.deleted_at is not null
     or d.uploaded_at is null or d.message_id is not null then
    raise exception 'document not found' using errcode = '42501';
  end if;
  if d.notified_at > now() - interval '1 minute' then
    return;  -- pressed twice: the segnalatore was told a moment ago
  end if;
  update public.documents set notified_at = clock_timestamp() where id = d.id;
  insert into public.notifications (organization_id, recipient_id, kind, actor_id, document_id, label, link)
  select d.organization_id, pm.profile_id, 'document', (select auth.uid()), d.id,
         left('Nuovo documento da Gemina Advisory: ' || d.title, 300), 'documenti'
    from public.partner_members pm
   where pm.partner_id = d.partner_id;
  perform private.call_message_emails(jsonb_build_object('mode', 'document', 'document_id', d.id));
end $$;

revoke execute on function private.messages_server_values() from public, anon, authenticated;
revoke execute on function private.notify_on_message() from public, anon, authenticated;
revoke execute on function public.partner_threads(uuid) from public, anon;
grant execute on function public.partner_threads(uuid) to authenticated;
revoke execute on function public.notify_document(uuid) from public, anon;
grant execute on function public.notify_document(uuid) to authenticated;
