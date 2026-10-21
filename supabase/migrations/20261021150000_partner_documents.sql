-- Step 7, piece 1 (2026-10-21): files between Gemina and the segnalatori move from Zite/Drive to Supabase Storage.
-- Plan: claude/2026-10-21-piano-step7-file.md in the project folder. Decided by Giacomo: every file exchanged with a segnalatore
-- moves (message attachments, azienda files, direct shares, versions, Gemina's documents); contracts (Accordo) and the
-- segnalatore's Drive folder stay in Zite/Drive for now.
--
-- How a file travels:
-- 1. The browser creates the row in public.documents. The server makes the id, the time and the storage path
--    (partner/<partner id>/<document id>/<safe name>), checks that conversation, message and earlier version are in the same
--    scope, and records whether Gemina or the segnalatore shared it.
-- 2. The browser uploads the file to that path in the private bucket "documents" with its own login (the bucket's size and
--    type limits apply), then calls public.confirm_document_upload(): the server checks the file is there and takes size and
--    type from Storage. Until then only the author sees the row (as "not uploaded").
-- 3. A link (https only) is a row with link_url and no file: it is complete at once.
--
-- Rules fixed here (holes found in the baseline rules):
-- - a file attached to an internal note is never shared with the segnalatore (shared is forced off), and a file whose message
--   is internal or hidden is never shown to them;
-- - conversation, message and version must belong to the document's own scope;
-- - the storage path is made by the server, and a file can be uploaded once, only by its author;
-- - a staff edit cannot move a document to another scope or path, or fake its upload;
-- - at most 30 new documents a minute per person (staff excepted), like the message send limit.
--
-- Notices: a segnalatore's file shared outside a message → bell for the current team (kind 'document'; the team email follows the
-- 15-minute rule of messages, in message-emails). A file on a message rides on that message's notice. A Gemina document is
-- announced only when someone presses "Notifica segnalatore" (public.notify_document: bell + email to the segnalatore).
-- Removing = hiding (deleted_at): the file stays in Storage, Gemina keeps the history, as with Drive today.
-- History import: same switch as messages (gemina.import on, no logged-in user): values are kept as given, no notices.
-- Only additive or replacing statements, apart from the not-null rule on storage_path (a link has no file).

-- 1. Types, columns, indexes ----------------------------------------------------------------------------------------------------
alter type public.notification_kind add value if not exists 'document';

alter table public.documents alter column storage_path drop not null;
alter table public.documents
  add column link_url          text check (link_url ~ '^https://[^\s]+$' and char_length(link_url) <= 2000),
  add column version_of        uuid references public.documents(id) on delete set null,
  add column zite_azienda_id   text check (char_length(zite_azienda_id) <= 100),
  add column category          text check (char_length(category) <= 60),
  add column from_gemina       boolean not null default false,
  add column uploaded_at       timestamptz,
  add column notified_at       timestamptz,
  add column zite_documento_id text check (char_length(zite_documento_id) <= 100);
alter table public.documents add constraint documents_file_or_link check ((storage_path is null) <> (link_url is null));

comment on column public.documents.storage_path is 'Path in the bucket "documents", made by the server; null for a link';
comment on column public.documents.link_url is 'A shared link (https), instead of a file';
comment on column public.documents.version_of is 'First version of the same document (nothing is overwritten); null for a first version';
comment on column public.documents.zite_azienda_id is 'Zite azienda the document is about (a presented azienda, or "Riguarda")';
comment on column public.documents.category is 'Gemina''s document type (Zite TIPO_DOCUMENTO_SEGNALATORE, e.g. Presentazione); null for the segnalatore''s';
comment on column public.documents.from_gemina is 'Shared by the Gemina team (set by the server from the uploader)';
comment on column public.documents.uploaded_at is 'When the file reached Storage (confirmed by the server); links: when added. Null = not uploaded';
comment on column public.documents.notified_at is 'Last "Notifica segnalatore" (bell + email to the segnalatore)';
comment on column public.documents.zite_documento_id is 'Zite row it was copied from (history import), so a copy can run twice safely';

create index documents_version_of_idx on public.documents (version_of);
create index documents_zite_azienda_id_idx on public.documents (zite_azienda_id);
create index documents_uploaded_by_created_idx on public.documents (uploaded_by, created_at);
create unique index documents_zite_documento_id_key on public.documents (zite_documento_id) where zite_documento_id is not null;

alter table public.notifications add column document_id uuid references public.documents(id) on delete cascade;
create index notifications_document_id_idx on public.notifications (document_id);
comment on column public.notifications.document_id is 'Document the notice is about (kind document)';

-- 2. Who sees a document ---------------------------------------------------------------------------------------------------------
-- Staff: everything. Others: shared, not hidden, in their scope, uploaded (or their own upload in progress), and not on an
-- internal or hidden message.
create function private.can_see_document(p_kind public.conversation_kind, p_company_id uuid, p_partner_id uuid,
                                         p_shared boolean, p_deleted_at timestamptz, p_message_id uuid,
                                         p_uploaded_at timestamptz, p_uploaded_by uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_staff()
      or (p_shared and p_deleted_at is null
          and private.can_access_scope(p_kind, p_company_id, p_partner_id)
          and (p_uploaded_at is not null or p_uploaded_by = (select auth.uid()))
          and (p_message_id is null or exists (
                select 1 from public.messages m
                 where m.id = p_message_id and not m.internal and m.deleted_at is null)));
$$;

alter policy "documents: read" on public.documents
  using (private.can_see_document(kind, company_id, partner_id, shared, deleted_at, message_id, uploaded_at, uploaded_by));

create or replace function private.can_access_document_path(path text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.documents d
     where d.storage_path = path
       and private.can_see_document(d.kind, d.company_id, d.partner_id, d.shared, d.deleted_at, d.message_id,
                                    d.uploaded_at, d.uploaded_by));
$$;

-- A file is uploaded once, by its author, while the row waits for it.
create or replace function private.can_upload_document_path(path text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.documents d
     where d.storage_path = path
       and d.uploaded_by = (select auth.uid())
       and d.deleted_at is null
       and d.uploaded_at is null);
$$;

-- 3. Server values and scope checks on a new document ----------------------------------------------------------------------------
create function private.safe_file_name(p_name text) returns text
language sql immutable set search_path = '' as $$
  select coalesce(nullif(left(regexp_replace(regexp_replace(btrim(coalesce(p_name, '')), '[^A-Za-z0-9._-]+', '_', 'g'),
                                             '^[._-]+', ''), 120), ''), 'file');
$$;

-- Runs before documents_set_organization (triggers fire in name order).
create function private.documents_before_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  importing boolean := (select auth.uid()) is null and coalesce(current_setting('gemina.import', true), '') = 'on';
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
    if not importing and not staff and m.sender_id is distinct from uid then
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
       or v.company_id is distinct from new.company_id then
      raise exception 'the earlier version is outside the document''s scope' using errcode = '23514';
    end if;
    new.version_of := coalesce(v.version_of, v.id);
  end if;

  if importing then
    return new;  -- history copy: keeps id, times, path and Zite id as given
  end if;

  if not staff and (select count(*) from public.documents d
                     where d.uploaded_by = uid and d.created_at > now() - interval '1 minute') >= 30 then
    raise exception 'too many documents in a minute' using errcode = 'P0429';
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
                                      else 'client/' || new.company_id::text end
                        || '/' || new.id::text || '/' || private.safe_file_name(new.title);
  end if;
  return new;
end $$;

create trigger documents_a_before_insert
  before insert on public.documents
  for each row execute function private.documents_before_insert();

-- A browser edit (staff only, by policy) changes title, type, sharing or hiding; never scope, path, author or upload.
-- The server's own functions (security definer, not run as "authenticated") and the history import are not limited.
-- Security invoker on purpose: current_user must be the caller.
create function private.documents_before_update() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if current_user = 'authenticated' then
    new.kind := old.kind;
    new.company_id := old.company_id;
    new.partner_id := old.partner_id;
    new.conversation_id := old.conversation_id;
    new.message_id := old.message_id;
    new.version_of := old.version_of;
    new.storage_path := old.storage_path;
    new.link_url := old.link_url;
    new.uploaded_by := old.uploaded_by;
    new.from_gemina := old.from_gemina;
    new.uploaded_at := old.uploaded_at;
    new.size_bytes := old.size_bytes;
    new.mime_type := old.mime_type;
    new.created_at := old.created_at;
    new.notified_at := old.notified_at;
    new.zite_documento_id := old.zite_documento_id;
    if new.message_id is not null and exists (select 1 from public.messages m where m.id = new.message_id and m.internal) then
      new.shared := false;
    end if;
  end if;
  return new;
end $$;

create trigger documents_a_before_update
  before update on public.documents
  for each row execute function private.documents_before_update();

-- 4. Emails: one helper for every request to message-emails ---------------------------------------------------------------------
create function private.call_message_emails(p_body jsonb) returns void
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
    body := p_body,
    headers := jsonb_build_object('content-type', 'application/json', 'x-email-secret', secret),
    timeout_milliseconds := 5000);
exception when others then
  raise warning 'call_message_emails: %', sqlerrm;
end $$;

create or replace function private.request_message_emails(p_mode text, p_conversation_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.call_message_emails(jsonb_build_object('mode', p_mode, 'conversation_id', p_conversation_id));
end $$;

-- 5. Bell for the team when a segnalatore shares something outside a message ----------------------------------------------------
create function private.notify_document_shared(p_document_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  d public.documents%rowtype;
  who text;
  seg text;
begin
  select * into d from public.documents where id = p_document_id;
  if not found or d.from_gemina or d.kind <> 'partner' or d.message_id is not null or not d.shared
     or d.deleted_at is not null or d.uploaded_at is null then
    return;
  end if;
  select coalesce(nullif(btrim(pa.name), ''), 'Un segnalatore'), pa.zite_segnalatore_id into who, seg
    from public.partners pa where pa.id = d.partner_id;
  insert into public.notifications (organization_id, recipient_id, kind, actor_id, document_id, label, link)
  select d.organization_id, p.id, 'document', d.uploaded_by, d.id,
         left(who || case when d.version_of is not null then ' ha caricato una nuova versione di un documento: '
                          else ' ha condiviso un documento: ' end || d.title, 300),
         'segnalatore:' || seg
    from public.profiles p
   where p.role = 'staff' and p.organization_id = d.organization_id;
end $$;

create function private.documents_after_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null and coalesce(current_setting('gemina.import', true), '') = 'on' then
    return null;
  end if;
  if new.uploaded_at is not null then  -- a link: complete at once
    perform private.notify_document_shared(new.id);
  end if;
  return null;
end $$;

create trigger documents_after_insert
  after insert on public.documents
  for each row execute function private.documents_after_insert();

-- 6. The browser confirms an upload (the server checks Storage) ----------------------------------------------------------------
create function public.confirm_document_upload(p_document_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  d public.documents%rowtype;
  meta jsonb;
begin
  select * into d from public.documents where id = p_document_id for update;
  if uid is null or not found or d.uploaded_by is distinct from uid or d.deleted_at is not null or d.storage_path is null then
    raise exception 'document not found' using errcode = '42501';
  end if;
  if d.uploaded_at is not null then
    return;  -- already confirmed
  end if;
  select o.metadata into meta from storage.objects o where o.bucket_id = 'documents' and o.name = d.storage_path;
  if not found then
    raise exception 'the file has not reached storage' using errcode = 'P0002';
  end if;
  update public.documents
     set uploaded_at = clock_timestamp(),
         size_bytes = case when coalesce(meta ->> 'size', '') ~ '^[0-9]+$' then (meta ->> 'size')::bigint end,
         mime_type = coalesce(nullif(meta ->> 'mimetype', ''), d.mime_type)
   where id = d.id;
  perform private.notify_document_shared(d.id);
end $$;

-- 7. Hiding a document (its author, or staff) --------------------------------------------------------------------------------------
create function public.remove_document(p_document_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  d public.documents%rowtype;
begin
  select * into d from public.documents where id = p_document_id;
  if uid is null or not found or d.deleted_at is not null
     or not (private.is_staff() or (d.uploaded_by = uid and private.can_access_scope(d.kind, d.company_id, d.partner_id))) then
    raise exception 'document not found' using errcode = '42501';
  end if;
  update public.documents set deleted_at = clock_timestamp() where id = d.id;
  update public.notifications set read_at = clock_timestamp() where document_id = d.id and read_at is null;
end $$;

-- 8. "Notifica segnalatore": bell + email to the segnalatore about a Gemina document ----------------------------------------------
create function public.notify_document(p_document_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  d public.documents%rowtype;
begin
  select * into d from public.documents where id = p_document_id for update;
  if not private.is_staff() or not found or d.kind <> 'partner' or not d.shared or d.deleted_at is not null
     or d.uploaded_at is null or d.message_id is not null then
    raise exception 'document not found' using errcode = '42501';
  end if;
  update public.documents set notified_at = clock_timestamp() where id = d.id;
  insert into public.notifications (organization_id, recipient_id, kind, actor_id, document_id, label, link)
  select d.organization_id, pm.profile_id, 'document', (select auth.uid()), d.id,
         left('Nuovo documento da Gemina Advisory: ' || d.title, 300), 'documenti'
    from public.partner_members pm
   where pm.partner_id = d.partner_id;
  perform private.call_message_emails(jsonb_build_object('mode', 'document', 'document_id', d.id));
end $$;

-- 9. Document notices read: staff for one segnalatore (anyone reads for the team), a segnalatore their own -------------------------
create function public.mark_documents_read(p_partner_id uuid default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not logged in' using errcode = '42501';
  end if;
  if private.is_staff() then
    update public.notifications n set read_at = clock_timestamp()
      from public.documents d
     where n.document_id = d.id and n.kind = 'document' and n.read_at is null
       and d.partner_id = p_partner_id
       and exists (select 1 from public.profiles p where p.id = n.recipient_id and p.role = 'staff');
  else
    update public.notifications set read_at = clock_timestamp()
     where recipient_id = uid and kind = 'document' and read_at is null;
  end if;
end $$;

-- 10. A segnalatore's documents in one call -----------------------------------------------------------------------------------------
-- Staff: one segnalatore's (p_partner_id) or all; others: their own. Staff do not see someone else's upload in progress.
create function public.partner_documents(p_partner_id uuid default null)
returns table (
  id uuid, partner_id uuid, zite_segnalatore_id text, title text, category text, link_url text, storage_path text,
  mime_type text, size_bytes bigint, from_gemina boolean, uploader_name text, mine boolean, created_at timestamptz,
  uploaded_at timestamptz, conversation_id uuid, conversation_title text, message_id uuid, version_of uuid,
  zite_azienda_id text, zite_pratica_id text, shared boolean, notified_at timestamptz
)
language sql stable security definer set search_path = '' as $$
  with me as (select (select auth.uid()) as uid, private.is_staff() as staff)
  select d.id, d.partner_id, pa.zite_segnalatore_id, d.title, d.category, d.link_url, d.storage_path,
         d.mime_type, d.size_bytes, d.from_gemina,
         case when d.from_gemina
              then coalesce(nullif(trim(coalesce(p.name_first, '') || ' ' || coalesce(p.name_last, '')), ''), 'Gemina Advisory')
              else pa.name end,
         coalesce(d.uploaded_by = me.uid, false), d.created_at, d.uploaded_at, d.conversation_id, c.title, d.message_id, d.version_of,
         d.zite_azienda_id, d.zite_pratica_id, d.shared, d.notified_at
    from me
    cross join public.documents d
    join public.partners pa on pa.id = d.partner_id
    left join public.profiles p on p.id = d.uploaded_by
    left join public.conversations c on c.id = d.conversation_id
   where me.uid is not null
     and d.kind = 'partner'
     and d.deleted_at is null
     and (p_partner_id is null or d.partner_id = p_partner_id)
     and (d.uploaded_at is not null or d.uploaded_by = me.uid)
     and private.can_see_document(d.kind, d.company_id, d.partner_id, d.shared, d.deleted_at, d.message_id,
                                  d.uploaded_at, d.uploaded_by)
   order by d.created_at desc, d.id;
$$;

-- 11. Privileges --------------------------------------------------------------------------------------------------------------------
revoke execute on function private.documents_before_insert() from public, anon, authenticated;
revoke execute on function private.documents_before_update() from public, anon, authenticated;
revoke execute on function private.documents_after_insert() from public, anon, authenticated;
revoke execute on function private.notify_document_shared(uuid) from public, anon, authenticated;
revoke execute on function private.call_message_emails(jsonb) from public, anon, authenticated;
revoke execute on function private.request_message_emails(text, uuid) from public, anon, authenticated;
revoke execute on function private.safe_file_name(text) from public, anon;
revoke execute on function private.can_see_document(public.conversation_kind, uuid, uuid, boolean, timestamptz, uuid, timestamptz, uuid) from public, anon;
grant execute on function private.can_see_document(public.conversation_kind, uuid, uuid, boolean, timestamptz, uuid, timestamptz, uuid) to authenticated;
revoke execute on function public.confirm_document_upload(uuid) from public, anon;
revoke execute on function public.remove_document(uuid) from public, anon;
revoke execute on function public.notify_document(uuid) from public, anon;
revoke execute on function public.mark_documents_read(uuid) from public, anon;
revoke execute on function public.partner_documents(uuid) from public, anon;
grant execute on function public.confirm_document_upload(uuid) to authenticated;
grant execute on function public.remove_document(uuid) to authenticated;
grant execute on function public.notify_document(uuid) to authenticated;
grant execute on function public.mark_documents_read(uuid) to authenticated;
grant execute on function public.partner_documents(uuid) to authenticated;

-- 12. Live: a shared file reaches the other side's open page -------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'documents') then
    alter publication supabase_realtime add table public.documents;
  end if;
end $$;
