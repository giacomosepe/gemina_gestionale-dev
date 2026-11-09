-- Allegati per la firma (2026-11-09, piano pagine passo 8; decisions: Giacomo 9 Nov, «su Supabase, i file su Supabase e su Drive»).
--
-- A scadenza of a pratica (public.scadenze: Domanda, Rendicontazione 2…) needs some documents signed by the client and/or Gemina. Which ones, how many
-- signatures and who signs come from Zite (the catalogue voce: Dati.firmeRichieste / firmatari, set on the categoria's Output tab): the Gestionale
-- creates one row here per (scadenza, voce) the first time the list is opened, with a copy of those settings (later changes on the categoria do not move
-- a document already in signature).
--
-- The files live in the Drive folder the operator links to the scadenza (no folder is proposed by default: Giacomo, 9 Nov) and, as a copy, in the
-- private bucket `signature-files`. Every file read from the folder is a version (original, or signed: each CAdES signature adds `.p7m`, the app counts
-- them). Nothing is ever deleted: a document is archived, a version stays.
--
-- `signature_events` is the history the operator reads («inviato il… a…», «firmato 1 di 2»…). Today the database writes it from the app's own changes;
-- later a webhook (Resend: delivered / bounced; PandaDoc if ever used: opened / signed) adds its events with `source` and `external_event_id`
-- (each external event once). `method` already allows 'pandadoc' for that day; nothing uses it yet.

-- 1. The Drive folder of each scadenza (a link to a FOLDER; the Gestionale checks it can open it before saving).
alter table public.scadenze
  add column drive_folder text
    check (drive_folder is null or (char_length(drive_folder) <= 300 and drive_folder ~ '^https://drive\.google\.com/drive/folders/[A-Za-z0-9_-]{10,}$'));
comment on column public.scadenze.drive_folder is 'Cartella Drive della scadenza (allegati da firmare): scelta dall''operatore, nessuna di partenza.';

-- 2. One document to sign for one scadenza.
create table public.signature_attachments (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null default private.default_organization_id() references public.organizations(id) on delete restrict,
  pratica_id          uuid not null references public.pratiche(id) on delete restrict,
  scadenza_id         uuid not null references public.scadenze(id) on delete restrict,
  zite_dato_id        text not null check (zite_dato_id ~ '^[A-Za-z0-9-]{8,64}$'),
  name                text not null check (char_length(btrim(name)) between 1 and 200),
  signatures_required smallint not null check (signatures_required between 1 and 5),
  signers             text[] not null check (cardinality(signers) between 1 and 2 and signers <@ array['cliente', 'gemina']::text[]),
  method              text not null default 'p7m' check (method in ('p7m', 'pandadoc')),
  external_ref        text check (external_ref is null or char_length(external_ref) <= 200),
  -- «Richiedi firma» (step 9): when, to whom, by whom. The email provider's id lets a later webhook find the row.
  sent_at             timestamptz,
  sent_to             text check (sent_to is null or char_length(sent_to) <= 500),
  sent_by             uuid references public.profiles(id) on delete set null,
  sent_message_id     text check (sent_message_id is null or char_length(sent_message_id) <= 200),
  -- «Segna come firmati»: by hand, when the signed file is not in the folder (or a signature is not a .p7m).
  marked_signed_at    timestamptz,
  marked_signed_by    uuid references public.profiles(id) on delete set null,
  archived            boolean not null default false,
  created_by          uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint signature_attachments_scadenza_dato_key unique (scadenza_id, zite_dato_id),
  constraint signature_attachments_signers_fit check (cardinality(signers) <= signatures_required)
);
comment on table public.signature_attachments is 'Allegati da firmare di una scadenza: uno per voce del catalogo (Zite). Firme richieste e firmatari copiati dalla voce alla creazione. Si archiviano, non si cancellano.';
create index signature_attachments_pratica_idx on public.signature_attachments (pratica_id, scadenza_id);
create index signature_attachments_organization_idx on public.signature_attachments (organization_id);

-- 3. The files of a document, as they were read from the Drive folder: the original and every signed version.
create table public.signature_attachment_files (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations(id) on delete restrict,
  attachment_id   uuid not null references public.signature_attachments(id) on delete restrict,
  kind            text not null check (kind in ('original', 'signed')),
  file_name       text not null check (char_length(file_name) between 1 and 255),
  drive_file_id   text not null check (drive_file_id ~ '^[A-Za-z0-9_-]{10,200}$'),
  -- how many `.p7m` the name carries (0 = not signed); written by the app, which reads the name (lib/firme/regole.nFirme)
  signatures      smallint not null default 0 check (signatures between 0 and 5),
  sha256          text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes      bigint check (size_bytes between 0 and 52428800),
  -- the copy in the bucket `signature-files` (<organization>/<attachment>/<sha256>.<ext>); null while the copy could not be made
  storage_path    text unique check (storage_path is null or char_length(storage_path) <= 300),
  created_by      uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at      timestamptz not null default now(),
  -- the same bytes are one version, even when read twice or from a copy of the file
  constraint signature_attachment_files_same_bytes_key unique (attachment_id, sha256),
  constraint signature_attachment_files_kind_fits check ((kind = 'original') = (signatures = 0))
);
comment on table public.signature_attachment_files is 'Versioni dei file di un allegato da firmare: originale e firmati (ogni firma CAdES aggiunge .p7m). Copia nel bucket signature-files. Non si cancellano.';
create index signature_attachment_files_attachment_idx on public.signature_attachment_files (attachment_id, created_at);
create index signature_attachment_files_organization_idx on public.signature_attachment_files (organization_id);

-- 4. What happened to a document: the operator's reassurance and the place for future webhooks.
create table public.signature_events (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references public.organizations(id) on delete restrict,
  attachment_id     uuid not null references public.signature_attachments(id) on delete restrict,
  event             text not null check (event in ('created', 'file', 'signed_file', 'sent', 'delivered', 'bounced', 'opened', 'signed',
                                                   'marked_signed', 'unmarked', 'archived', 'restored')),
  source            text not null default 'app' check (source in ('app', 'resend', 'pandadoc')),
  detail            jsonb not null default '{}'::jsonb check (pg_column_size(detail) <= 4000),
  actor_id          uuid references public.profiles(id) on delete set null,
  external_event_id text unique check (external_event_id is null or char_length(external_event_id) <= 200),
  -- the real time, not the transaction's: several events of one call (a folder read) keep their order
  created_at        timestamptz not null default clock_timestamp()
);
comment on table public.signature_events is 'Storia di un allegato da firmare: creato, file letti, inviato, (consegnato, aperto, firmato da webhook in futuro), segnato firmato. Scritta solo dal database e dalle funzioni del server.';
create index signature_events_attachment_idx on public.signature_events (attachment_id, created_at);
create index signature_events_organization_idx on public.signature_events (organization_id);

-- 5. Rules on write.
create or replace function private.signature_attachments_before_write()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  new.updated_at := now();
  new.name := btrim(new.name);
  if tg_op = 'INSERT' then
    -- the scadenza must be of this pratica, not archived, on a pratica still in the mirror
    if not exists (select 1 from public.scadenze s join public.pratiche p on p.id = s.pratica_id
                    where s.id = new.scadenza_id and s.pratica_id = new.pratica_id and not s.archiviata and p.removed_at is null) then
      raise exception 'Scadenza non trovata per questa pratica.' using errcode = '23503';
    end if;
    new.created_by := coalesce((select auth.uid()), new.created_by);
    new.organization_id := (select s.organization_id from public.scadenze s where s.id = new.scadenza_id);
    new.created_at := now();
    new.sent_at := null; new.sent_to := null; new.sent_by := null; new.sent_message_id := null;
    new.marked_signed_at := null; new.marked_signed_by := null;
  else
    -- what identifies the document never changes
    new.id := old.id; new.organization_id := old.organization_id; new.pratica_id := old.pratica_id; new.scadenza_id := old.scadenza_id;
    new.zite_dato_id := old.zite_dato_id; new.created_by := old.created_by; new.created_at := old.created_at;
    -- signatures and signers follow the voce only while nothing has been sent or signed
    if (new.signatures_required, new.signers) is distinct from (old.signatures_required, old.signers)
       and (old.sent_at is not null or old.marked_signed_at is not null
            or exists (select 1 from public.signature_attachment_files f where f.attachment_id = old.id and f.kind = 'signed')) then
      new.signatures_required := old.signatures_required; new.signers := old.signers;
    end if;
    -- who sent or marked is the person doing it, never what the request says
    if new.sent_at is distinct from old.sent_at then new.sent_by := case when new.sent_at is null then null else (select auth.uid()) end; end if;
    if new.marked_signed_at is distinct from old.marked_signed_at then
      new.marked_signed_by := case when new.marked_signed_at is null then null else (select auth.uid()) end;
    end if;
  end if;
  return new;
end $$;

create trigger signature_attachments_a_before_write
  before insert or update on public.signature_attachments
  for each row execute function private.signature_attachments_before_write();

create or replace function private.signature_attachment_files_before_insert()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  new.organization_id := (select a.organization_id from public.signature_attachments a where a.id = new.attachment_id);
  if new.organization_id is null then raise exception 'Allegato non trovato.' using errcode = '23503'; end if;
  if exists (select 1 from public.signature_attachments a where a.id = new.attachment_id and a.archived) then
    raise exception 'Questo allegato è archiviato.' using errcode = '22023';
  end if;
  if new.storage_path is not null and new.storage_path not like new.organization_id::text || '/' || new.attachment_id::text || '/' || new.sha256 || '.%' then
    raise exception 'Percorso del file non valido.' using errcode = '22023';
  end if;
  new.created_by := coalesce((select auth.uid()), new.created_by);
  -- the real time: the versions read in one call keep their order
  new.created_at := clock_timestamp();
  return new;
end $$;

create trigger signature_attachment_files_a_before_insert
  before insert on public.signature_attachment_files
  for each row execute function private.signature_attachment_files_before_insert();

-- The copy can be attached later (the storage upload failed the first time); nothing else of a version changes.
create or replace function private.signature_attachment_files_before_update()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if (to_jsonb(new) - 'storage_path') is distinct from (to_jsonb(old) - 'storage_path') or old.storage_path is not null then
    raise exception 'Una versione non si cambia.' using errcode = '22023';
  end if;
  if new.storage_path not like new.organization_id::text || '/' || new.attachment_id::text || '/' || new.sha256 || '.%' then
    raise exception 'Percorso del file non valido.' using errcode = '22023';
  end if;
  return new;
end $$;

create trigger signature_attachment_files_b_before_update
  before update on public.signature_attachment_files
  for each row execute function private.signature_attachment_files_before_update();

-- 6. The history, written by the database from the app's own changes (security definer: nobody inserts events directly).
create or replace function private.signature_log()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare me uuid := (select auth.uid());
begin
  if tg_table_name = 'signature_attachments' then
    if tg_op = 'INSERT' then
      insert into public.signature_events (organization_id, attachment_id, event, actor_id, detail)
      values (new.organization_id, new.id, 'created', me, jsonb_build_object('signatures_required', new.signatures_required, 'signers', new.signers));
    else
      if new.sent_at is not null and new.sent_at is distinct from old.sent_at then
        insert into public.signature_events (organization_id, attachment_id, event, actor_id, detail)
        values (new.organization_id, new.id, 'sent', me, jsonb_build_object('to', new.sent_to, 'message_id', new.sent_message_id));
      end if;
      if new.marked_signed_at is distinct from old.marked_signed_at then
        insert into public.signature_events (organization_id, attachment_id, event, actor_id)
        values (new.organization_id, new.id, case when new.marked_signed_at is null then 'unmarked' else 'marked_signed' end, me);
      end if;
      if new.archived is distinct from old.archived then
        insert into public.signature_events (organization_id, attachment_id, event, actor_id)
        values (new.organization_id, new.id, case when new.archived then 'archived' else 'restored' end, me);
      end if;
    end if;
  else
    insert into public.signature_events (organization_id, attachment_id, event, actor_id, detail)
    values (new.organization_id, new.attachment_id, case when new.kind = 'signed' then 'signed_file' else 'file' end, me,
            jsonb_build_object('file_name', new.file_name, 'signatures', new.signatures));
  end if;
  return null;
end $$;

create trigger signature_attachments_z_log after insert or update on public.signature_attachments
  for each row execute function private.signature_log();
create trigger signature_attachment_files_z_log after insert on public.signature_attachment_files
  for each row execute function private.signature_log();

revoke all on function private.signature_log() from public, anon, authenticated;

-- 7. What the screens read: the document with its latest file, the signatures done and one state.
create view public.signature_attachments_v with (security_invoker = true) as
select a.*,
       f.file_name     as current_file_name,
       f.drive_file_id as current_drive_file_id,
       f.kind          as current_kind,
       coalesce(d.done, 0) as signatures_done,
       case
         when a.archived then 'archiviato'
         when a.marked_signed_at is not null or coalesce(d.done, 0) >= a.signatures_required then 'firmato'
         when coalesce(d.done, 0) > 0 then 'firmato_in_parte'
         when a.sent_at is not null then 'inviato'
         when f.id is not null then 'pronto'
         else 'da_preparare'
       end as status,
       e.last_event, e.last_event_at
  from public.signature_attachments a
  left join lateral (select x.id, x.file_name, x.drive_file_id, x.kind from public.signature_attachment_files x
                      where x.attachment_id = a.id order by x.signatures desc, x.created_at desc limit 1) f on true
  left join lateral (select max(x.signatures)::int as done from public.signature_attachment_files x where x.attachment_id = a.id) d on true
  left join lateral (select y.event as last_event, y.created_at as last_event_at from public.signature_events y
                      where y.attachment_id = a.id order by y.created_at desc limit 1) e on true;
comment on view public.signature_attachments_v is 'Allegati da firmare con il file attuale, le firme fatte e lo stato: da_preparare, pronto, inviato, firmato_in_parte, firmato, archiviato.';

-- 8. Access: staff only, as public.scadenze. No delete anywhere (archive instead).
alter table public.signature_attachments enable row level security;
alter table public.signature_attachment_files enable row level security;
alter table public.signature_events enable row level security;

create policy "signature_attachments: staff read" on public.signature_attachments
  for select to authenticated using ((select private.is_staff()));
create policy "signature_attachments: staff insert" on public.signature_attachments
  for insert to authenticated with check ((select private.is_staff()));
create policy "signature_attachments: staff update" on public.signature_attachments
  for update to authenticated using ((select private.is_staff())) with check ((select private.is_staff()));

create policy "signature_attachment_files: staff read" on public.signature_attachment_files
  for select to authenticated using ((select private.is_staff()));
create policy "signature_attachment_files: staff insert" on public.signature_attachment_files
  for insert to authenticated with check ((select private.is_staff()));
create policy "signature_attachment_files: staff update" on public.signature_attachment_files
  for update to authenticated using ((select private.is_staff())) with check ((select private.is_staff()));

create policy "signature_events: staff read" on public.signature_events
  for select to authenticated using ((select private.is_staff()));

revoke all on public.signature_attachments, public.signature_attachment_files, public.signature_events, public.signature_attachments_v from anon, authenticated;
grant select, insert, update on public.signature_attachments to authenticated;
grant select, insert, update (storage_path) on public.signature_attachment_files to authenticated;
grant select on public.signature_events, public.signature_attachments_v to authenticated;

-- 9. The private bucket of the copies: staff read; written only by the server (Edge Function with the service role), never from a browser.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('signature-files', 'signature-files', false, 52428800,
        array['application/pdf', 'application/pkcs7-mime', 'application/x-pkcs7-mime', 'application/octet-stream',
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'])
on conflict (id) do nothing;

create policy "signature-files bucket: staff read" on storage.objects for select to authenticated
  using (bucket_id = 'signature-files' and (select private.is_staff()));
