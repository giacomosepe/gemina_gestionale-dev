-- Team documents and date reminders (2026-10-22, pratica side panel redesign).
--
-- 1. Team documents: kind 'team' (added by 20261021221703) = Gemina's own files about a pratica, today the attachments of the
--    azioni, kept in the private bucket "documents" under team/<pratica>/<document>/<name>. Staff only (the existing read,
--    upload and Storage policies already give 'team' to staff only through private.can_access_scope); never shared outside;
--    the pratica is required, the azione optional (zite_attivita_id). They show in the pratica's «Documenti dal server».
-- 2. Reminders: a date of a pratica (firma, kick-off, a deadline, a milestone…) can warn chosen colleagues N days before.
--    One row per pratica and date key, written by staff from the browser (0 Zite runs); recipients are Zite user ids, mapped
--    to staff profiles when sending. Every hour pg_cron calls private.send_due_reminders(), which acts from 8 in Rome on:
--    a bell (notifications, kind 'event', event 'promemoria', link pratica:<id>) per recipient, once per reminder, day and
--    date (reminder_sends), then one request to message-emails (mode "reminders") for the emails. A changed date re-arms it.

-- 1. Team documents ---------------------------------------------------------------------------------------------------------------
alter table public.documents
  add column zite_attivita_id text check (char_length(zite_attivita_id) <= 100);
create index documents_team_pratica_idx on public.documents (zite_pratica_id, created_at desc)
  where kind = 'team' and deleted_at is null;
create index documents_zite_attivita_idx on public.documents (zite_attivita_id) where zite_attivita_id is not null;

alter table public.documents drop constraint documents_scope_check;
alter table public.documents add constraint documents_scope_check check (
  (kind = 'client' and company_id is not null and partner_id is null)
  or (kind = 'partner' and partner_id is not null)
  or (kind = 'team' and company_id is null and partner_id is null and zite_pratica_id is not null));
alter table public.documents add constraint documents_team_not_shared check (kind <> 'team' or not shared);

-- The organization of a team document: the only one (there is no company or partner to take it from).
create or replace function private.set_organization_from_scope() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  org_company uuid;
  org_partner uuid;
begin
  if new.company_id is not null then
    select organization_id into org_company from public.companies where id = new.company_id;
  end if;
  if new.partner_id is not null then
    select organization_id into org_partner from public.partners where id = new.partner_id;
  end if;
  if org_company is not null and org_partner is not null and org_company <> org_partner then
    raise exception 'company and partner belong to different organizations';
  end if;
  new.organization_id := coalesce(org_company, org_partner);
  if new.organization_id is null and new.kind = 'team' then
    new.organization_id := private.default_organization_id();
  end if;
  if new.organization_id is null then
    raise exception 'cannot determine organization for %', tg_table_name;
  end if;
  return new;
end $$;

-- The insert check of 20261021145534, with the team path and "never shared" for team documents.
create or replace function private.documents_before_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  importing boolean := (select auth.uid()) is null and coalesce(current_setting('gemina.import', true), '') = 'on';
  browser boolean := coalesce((select auth.role()), '') = 'authenticated';
  staff boolean := private.is_staff();
  c public.conversations%rowtype;
  m public.messages%rowtype;
  v public.documents%rowtype;
begin
  -- a file on a message belongs to the message's conversation; a segnalatore attaches only to their own messages
  if new.message_id is not null then
    select * into m from public.messages where id = new.message_id;
    if not found then
      raise exception 'message not found' using errcode = '23503';
    end if;
    if new.conversation_id is null then
      new.conversation_id := m.conversation_id;
    elsif new.conversation_id <> m.conversation_id then
      raise exception 'the message is in another conversation' using errcode = '23514';
    end if;
    if browser and not staff and (m.sender_id is distinct from uid or m.deleted_at is not null) then
      raise exception 'files can be attached only to your own messages' using errcode = '42501';
    end if;
    if m.internal then
      new.shared := false;  -- a file on an internal note stays inside Gemina
    end if;
  end if;

  if new.conversation_id is not null then
    select * into c from public.conversations where id = new.conversation_id;
    if not found or c.kind <> new.kind or c.partner_id is distinct from new.partner_id
       or c.company_id is distinct from new.company_id then
      raise exception 'the conversation is outside the document''s scope' using errcode = '23514';
    end if;
  end if;

  -- a new version points at the first version, in the same scope
  if new.version_of is not null then
    select * into v from public.documents where id = new.version_of;
    if not found or v.kind <> new.kind or v.partner_id is distinct from new.partner_id
       or v.company_id is distinct from new.company_id
       or (browser and not staff and not private.can_see_document(v.kind, v.company_id, v.partner_id, v.shared, v.deleted_at,
                                                                  v.message_id, v.uploaded_at, v.uploaded_by)) then
      raise exception 'the earlier version is outside the document''s scope' using errcode = '23514';
    end if;
    new.version_of := coalesce(v.version_of, v.id);
  end if;

  -- Gemina's own files never reach anyone outside the team.
  if new.kind = 'team' then
    new.shared := false;
  end if;

  if not browser then
    return new;  -- history copy or full-rights caller: keeps id, times, path and Zite id as given
  end if;

  if not staff then
    if (select count(*) from public.documents d
         where d.uploaded_by = uid and d.created_at > now() - interval '1 minute') >= 30
       or (select count(*) from public.documents d
            where d.uploaded_by = uid and d.created_at > now() - interval '1 hour') >= 300 then
      raise exception 'too many documents' using errcode = 'P0429';
    end if;
    if new.kind = 'partner' then
      new.company_id := null;
    end if;
  end if;

  new.id := gen_random_uuid();
  new.uploaded_by := uid;
  new.created_at := clock_timestamp();
  new.updated_at := new.created_at;
  new.from_gemina := staff;
  new.zite_documento_id := null;
  new.deleted_at := null;
  new.notified_at := null;
  new.size_bytes := null;
  if not staff then
    new.category := null;
  end if;

  if new.link_url is not null then
    new.storage_path := null;
    new.mime_type := null;
    new.uploaded_at := new.created_at;
  else
    new.uploaded_at := null;
    new.storage_path := case new.kind when 'partner' then 'partner/' || new.partner_id::text
                                      when 'team' then 'team/' || private.safe_file_name(new.zite_pratica_id)
                                      else 'client/' || new.company_id::text end
                        || '/' || new.id::text || '/' || private.safe_file_name(new.title);
  end if;
  return new;
end $$;


-- 2. Reminders --------------------------------------------------------------------------------------------------------------------
create table public.reminders (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations(id) on delete restrict,
  zite_pratica_id text not null check (char_length(zite_pratica_id) between 1 and 100),
  -- which date of the pratica: 'firma', 'kickoff', 'scadenza', 'milestone:<id>', 'campo:<id>'…
  date_key        text not null check (date_key ~ '^[A-Za-z0-9:_-]{1,120}$'),
  label           text not null check (char_length(label) between 1 and 200),
  pratica_title   text check (char_length(pratica_title) <= 300),
  due_date        date not null,
  days_before     smallint[] not null check (cardinality(days_before) between 1 and 6 and array_position(days_before, null) is null
                                         and 0 <= all(days_before) and 90 >= all(days_before)),
  recipients      text[] not null check (cardinality(recipients) between 1 and 20 and array_position(recipients, null) is null),
  -- the pratica is closed (set by the Gestionale): nothing is sent
  closed          boolean not null default false,
  created_by      uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (zite_pratica_id, date_key)
);
comment on table public.reminders is 'A date of a pratica that warns colleagues N days before (bell + email at 8 in Rome)';

create table public.reminder_sends (
  reminder_id uuid not null references public.reminders(id) on delete cascade,
  due_date    date not null,
  days_before smallint not null,
  sent_at     timestamptz not null default now(),
  primary key (reminder_id, due_date, days_before)
);
comment on table public.reminder_sends is 'Which warnings of a reminder went out (once per date and day before)';

create function private.reminders_before_write() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  -- each recipient a plausible Zite id, no duplicates, days sorted from the farthest
  if exists (select 1 from unnest(new.recipients) r where r !~ '^[A-Za-z0-9_-]{1,100}$') then
    raise exception 'invalid recipient' using errcode = '23514';
  end if;
  new.recipients := array(select distinct r from unnest(new.recipients) r order by r);
  new.days_before := array(select distinct d from unnest(new.days_before) d order by d desc);
  if tg_op = 'INSERT' then
    new.created_by := coalesce((select auth.uid()), new.created_by);
    new.organization_id := private.default_organization_id();
  else
    new.id := old.id;
    new.organization_id := old.organization_id;
    new.created_by := old.created_by;
    new.created_at := old.created_at;
  end if;
  return new;
end $$;
create trigger reminders_a_before_write before insert or update on public.reminders
  for each row execute function private.reminders_before_write();

alter table public.reminders enable row level security;
alter table public.reminder_sends enable row level security;
create policy "reminders: staff read" on public.reminders for select to authenticated using ((select private.is_staff()));
create policy "reminders: staff insert" on public.reminders for insert to authenticated with check ((select private.is_staff()));
create policy "reminders: staff update" on public.reminders for update to authenticated
  using ((select private.is_staff())) with check ((select private.is_staff()));
create policy "reminders: staff delete" on public.reminders for delete to authenticated using ((select private.is_staff()));
create policy "reminder_sends: staff read" on public.reminder_sends for select to authenticated using ((select private.is_staff()));
grant select, insert, update, delete on public.reminders to authenticated;
grant select on public.reminder_sends to authenticated;
revoke all on public.reminders, public.reminder_sends from anon;
revoke truncate, references, trigger on public.reminders, public.reminder_sends from authenticated;
revoke insert, update, delete on public.reminder_sends from authenticated;

-- The warnings due today. `p_force`: run whatever the hour (tests, a manual run); otherwise from 8 in Rome on: the first run
-- after 8 sends them, a later one catches up what a missed run or a reminder set during the day left (never twice: reminder_sends).
-- Returns how many bells were written.
create function private.send_due_reminders(p_force boolean default false) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  rome      timestamp := now() at time zone 'Europe/Rome';
  today     date := (now() at time zone 'Europe/Rome')::date;
  r         record;
  days      int;
  bells     int := 0;
  written   int;
  quando    text;
begin
  if not p_force and extract(hour from rome) < 8 then
    return 0;
  end if;
  for r in
    select rm.*, (rm.due_date - today) as left_days
      from public.reminders rm
     where not rm.closed and rm.due_date >= today and (rm.due_date - today) = any(rm.days_before)
       and not exists (select 1 from public.reminder_sends s
                        where s.reminder_id = rm.id and s.due_date = rm.due_date and s.days_before = (rm.due_date - today))
     for update of rm skip locked
  loop
    days := r.left_days;
    insert into public.reminder_sends (reminder_id, due_date, days_before) values (r.id, r.due_date, days)
      on conflict do nothing;
    if not found then continue; end if;
    quando := case days when 0 then 'è oggi' when 1 then 'è domani' else format('tra %s giorni', days) end;
    insert into public.notifications (organization_id, recipient_id, kind, event, label, link, event_key)
    select r.organization_id, p.id, 'event', 'promemoria',
           left(format('Promemoria: %s %s (%s)%s', r.label, quando, to_char(r.due_date, 'DD/MM/YYYY'),
                       coalesce(' · ' || r.pratica_title, '')), 300),
           'pratica:' || r.zite_pratica_id,
           left(format('rem:%s:%s:%s:%s', r.id, r.due_date, days, p.id), 100)
      from public.profiles p
     where p.role = 'staff' and p.zite_user_id = any(r.recipients)
    on conflict do nothing;
    get diagnostics written = row_count;
    bells := bells + written;
  end loop;
  if bells > 0 then
    perform private.call_message_emails(jsonb_build_object('mode', 'reminders'));
  end if;
  return bells;
end $$;
revoke execute on function private.send_due_reminders(boolean) from public, anon, authenticated;

-- Every hour at minute 5; the function itself waits for 8 in Rome (summer and winter time alike).
select cron.schedule('pratica-reminders', '5 * * * *', $$select private.send_due_reminders()$$);
