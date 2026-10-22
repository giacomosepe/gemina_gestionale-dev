-- Documents: the azienda is the home of every team document; reminders also for a trattativa (2026-10-22, trattativa CRM).
--
-- Decided by Giacomo on 2026-10-22: documents such as bilanci, visure, analyses outlive a trattativa or a pratica (weeks or
-- months), so a team document now always belongs to an azienda (zite_azienda_id) and may also be about a trattativa and/or a
-- pratica ("riguarda"). Its lifespan says whether it serves every project of the azienda ('company', the default) or only the
-- project it was uploaded for ('project': project invoices, contracts…). Every view reads across: a pratica shows the azienda's
-- documents and its own, the azienda shows all. Nothing is copied or moved. At this date production holds no team document
-- (checked before writing), so the stricter rule needs no backfill.
-- Also: the bucket accepts files up to 50 MB (the Free plan ceiling; was 25 MB), and a reminder may be about a trattativa
-- (exactly one of pratica / trattativa), its bell linking to the right page.

-- 1. Team documents ---------------------------------------------------------------------------------------------------------------
alter table public.documents
  add column lifespan text not null default 'company' check (lifespan in ('company', 'project'));
comment on column public.documents.lifespan is
  'Team documents: company = serves every project of the azienda (bilancio, visura); project = only the trattativa/pratica it is about';
alter table public.documents add constraint documents_zite_trattativa_id_check check (char_length(zite_trattativa_id) <= 100);

alter table public.documents drop constraint documents_scope_check;
alter table public.documents add constraint documents_scope_check check (
  (kind = 'client' and company_id is not null and partner_id is null)
  or (kind = 'partner' and partner_id is not null)
  or (kind = 'team' and company_id is null and partner_id is null and zite_azienda_id is not null
      and (lifespan = 'company' or zite_pratica_id is not null or zite_trattativa_id is not null)));

create index documents_team_azienda_idx on public.documents (zite_azienda_id, created_at desc)
  where kind = 'team' and deleted_at is null;
create index documents_zite_trattativa_idx on public.documents (zite_trattativa_id) where zite_trattativa_id is not null;

-- The insert check of 20261021221829 with two changes: a team file goes under team/<azienda>/…, and a new version of a team
-- document stays with the same azienda.
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
       or (new.kind = 'team' and v.zite_azienda_id is distinct from new.zite_azienda_id)
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
                                      when 'team' then 'team/' || private.safe_file_name(new.zite_azienda_id)
                                      else 'client/' || new.company_id::text end
                        || '/' || new.id::text || '/' || private.safe_file_name(new.title);
  end if;
  return new;
end $$;

-- 2. Bucket size -----------------------------------------------------------------------------------------------------------------
update storage.buckets set file_size_limit = 52428800 where id = 'documents';

-- 3. Reminders of a trattativa ---------------------------------------------------------------------------------------------------
alter table public.reminders alter column zite_pratica_id drop not null;
alter table public.reminders
  add column zite_trattativa_id text check (char_length(zite_trattativa_id) between 1 and 100),
  add constraint reminders_one_record check ((zite_pratica_id is null) <> (zite_trattativa_id is null)),
  add constraint reminders_trattativa_date_key unique (zite_trattativa_id, date_key);
comment on column public.reminders.pratica_title is 'Title of the pratica or trattativa, shown in the bell and the email';

-- The hourly job of 20261021221829; the bell links to the pratica or to the trattativa.
create or replace function private.send_due_reminders(p_force boolean default false) returns integer
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
           coalesce('pratica:' || r.zite_pratica_id, 'trattativa:' || r.zite_trattativa_id),
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
