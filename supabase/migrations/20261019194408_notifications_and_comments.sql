-- Notifications (bell + unread counters) and comments on Zite records.
-- Goal: move Zite's run-heavy features (gestisciNotifiche, messaggiSegnalatore, comments)
-- to Supabase, read and written directly by the browser (0 Zite runs), live via Realtime.
--
-- Rules:
-- - A notification is only ever created by the database (triggers), never by a user.
-- - Each person reads only their own notifications and can only mark them read.
-- - Notifications never copy message or comment text (only a label): safe to email later.
-- - Comments are internal (staff only), written on a Zite record (azienda, pratica, ...),
--   one level of replies, @mentions by profile id. Authors can edit/hide their own.

-- 1. Comments -------------------------------------------------------------------------
create type public.record_type as enum
  ('azienda', 'contatto', 'trattativa', 'pratica', 'segnalatore', 'lead', 'attivita', 'servizio');

create table public.comments (
  id              uuid not null default gen_random_uuid() primary key,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  record_type     public.record_type not null,
  record_zite_id  text not null check (char_length(record_zite_id) between 1 and 100),
  record_label    text check (char_length(record_label) <= 300),
  parent_id       uuid references public.comments(id) on delete cascade,
  author_id       uuid references public.profiles(id) on delete set null default auth.uid(),
  body            text not null check (char_length(body) between 1 and 10000),
  mentions        uuid[] not null default '{}' check (cardinality(mentions) <= 20),
  created_at      timestamptz not null default now(),
  edited_at       timestamptz,
  deleted_at      timestamptz
);
create index comments_record_idx on public.comments (record_type, record_zite_id, created_at);
create index comments_parent_id_idx on public.comments (parent_id);
create index comments_author_id_created_at_idx on public.comments (author_id, created_at);
create index comments_organization_id_idx on public.comments (organization_id);

-- Organization from the author (staff only), one reply level, edit stamp.
create function private.comments_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  parent_parent uuid;
  parent_record public.record_type;
  parent_zite   text;
begin
  if tg_op = 'INSERT' then
    select organization_id into new.organization_id
      from public.profiles where id = new.author_id and role = 'staff';
    if new.organization_id is null then
      raise exception 'only staff can comment' using errcode = '42501';
    end if;
    if new.parent_id is not null then
      select parent_id, record_type, record_zite_id
        into parent_parent, parent_record, parent_zite
        from public.comments where id = new.parent_id;
      if parent_parent is not null then
        raise exception 'replies are one level only';
      end if;
      if parent_record is distinct from new.record_type or parent_zite is distinct from new.record_zite_id then
        raise exception 'a reply must be on the same record as its parent';
      end if;
    end if;
    -- keep only mentions of staff in the same organization, without duplicates
    new.mentions := coalesce((
      select array_agg(distinct p.id)
        from public.profiles p
       where p.id = any(new.mentions) and p.role = 'staff'
         and p.organization_id = new.organization_id), '{}');
  else
    if new.body is distinct from old.body then
      new.edited_at := now();
    end if;
  end if;
  return new;
end $$;

create trigger comments_before_write
  before insert or update on public.comments
  for each row execute function private.comments_before_write();

-- Send limit for comments (same thresholds as messages).
create function private.enforce_comment_send_limit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  last_minute int;
  last_hour   int;
begin
  select count(*) filter (where created_at > now() - interval '1 minute'), count(*)
    into last_minute, last_hour
    from public.comments
   where author_id = new.author_id and created_at > now() - interval '1 hour';
  if last_minute >= 20 or last_hour >= 300 then
    raise exception 'comment send limit reached' using errcode = 'P0429';
  end if;
  return new;
end $$;

create trigger comments_send_limit
  before insert on public.comments
  for each row execute function private.enforce_comment_send_limit();

alter table public.comments enable row level security;

create policy "comments: staff read" on public.comments
  for select to authenticated using (private.is_staff());
create policy "comments: staff write own" on public.comments
  for insert to authenticated
  with check (private.is_staff() and author_id = (select auth.uid()) and deleted_at is null);
create policy "comments: author edits own" on public.comments
  for update to authenticated
  using (author_id = (select auth.uid()))
  with check (author_id = (select auth.uid()));

revoke update, delete on public.comments from authenticated;
grant update (body, deleted_at) on public.comments to authenticated;

-- 2. Notifications --------------------------------------------------------------------
create type public.notification_kind as enum ('message', 'mention', 'comment_reply');

create table public.notifications (
  id              uuid not null default gen_random_uuid() primary key,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  recipient_id    uuid not null references public.profiles(id) on delete cascade,
  kind            public.notification_kind not null,
  actor_id        uuid references public.profiles(id) on delete set null,
  conversation_id uuid references public.conversations(id) on delete cascade,
  message_id      uuid references public.messages(id) on delete cascade,
  comment_id      uuid references public.comments(id) on delete cascade,
  record_type     public.record_type,
  record_zite_id  text,
  label           text,
  created_at      timestamptz not null default now(),
  read_at         timestamptz,
  emailed_at      timestamptz
);
create index notifications_recipient_unread_idx
  on public.notifications (recipient_id, created_at desc) where read_at is null;
create index notifications_recipient_created_idx on public.notifications (recipient_id, created_at desc);
create index notifications_conversation_id_idx on public.notifications (conversation_id);
create index notifications_message_id_idx on public.notifications (message_id);
create index notifications_comment_id_idx on public.notifications (comment_id);
create index notifications_actor_id_idx on public.notifications (actor_id);
create index notifications_organization_id_idx on public.notifications (organization_id);

alter table public.notifications enable row level security;

create policy "notifications: read own" on public.notifications
  for select to authenticated using (recipient_id = (select auth.uid()));
create policy "notifications: mark own read" on public.notifications
  for update to authenticated
  using (recipient_id = (select auth.uid()))
  with check (recipient_id = (select auth.uid()));

-- Users never insert or delete notifications; they can only set read_at.
revoke insert, update, delete on public.notifications from authenticated;
grant update (read_at) on public.notifications to authenticated;

-- 3. Who gets notified ------------------------------------------------------------------
-- New message: the other side of the conversation.
-- - Referrers / client members of the conversation's scope (never for internal notes).
-- - Staff: those already taking part (rows in conversation_members); if nobody from the
--   staff has taken part yet, every staff member of the organization.
create function private.notify_on_message() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  c public.conversations%rowtype;
  staff_involved boolean;
begin
  select * into c from public.conversations where id = new.conversation_id;
  select exists (
    select 1 from public.conversation_members cm
      join public.profiles p on p.id = cm.profile_id
     where cm.conversation_id = c.id and p.role = 'staff'
       and p.id is distinct from new.sender_id
  ) into staff_involved;

  insert into public.notifications
    (organization_id, recipient_id, kind, actor_id, conversation_id, message_id, label)
  select c.organization_id, p.id, 'message', new.sender_id, c.id, new.id, c.title
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
  return new;
end $$;

create trigger messages_notify
  after insert on public.messages
  for each row execute function private.notify_on_message();

-- New comment: people @mentioned, and the author of the comment being replied to.
create function private.notify_on_comment() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  parent_author uuid;
begin
  insert into public.notifications
    (organization_id, recipient_id, kind, actor_id, comment_id, record_type, record_zite_id, label)
  select new.organization_id, m, 'mention', new.author_id, new.id,
         new.record_type, new.record_zite_id, new.record_label
    from unnest(new.mentions) as m
   where m is distinct from new.author_id;

  if new.parent_id is not null then
    select author_id into parent_author from public.comments where id = new.parent_id;
    if parent_author is not null and parent_author is distinct from new.author_id
       and not (parent_author = any(new.mentions)) then
      insert into public.notifications
        (organization_id, recipient_id, kind, actor_id, comment_id, record_type, record_zite_id, label)
      values (new.organization_id, parent_author, 'comment_reply', new.author_id, new.id,
              new.record_type, new.record_zite_id, new.record_label);
    end if;
  end if;
  return new;
end $$;

create trigger comments_notify
  after insert on public.comments
  for each row execute function private.notify_on_comment();

-- Trigger functions are never callable through the API.
revoke execute on function private.comments_before_write() from public, anon, authenticated;
revoke execute on function private.enforce_comment_send_limit() from public, anon, authenticated;
revoke execute on function private.notify_on_message() from public, anon, authenticated;
revoke execute on function private.notify_on_comment() from public, anon, authenticated;

-- 4. Live updates ------------------------------------------------------------------------
alter publication supabase_realtime add table public.notifications;
alter publication supabase_realtime add table public.comments;
