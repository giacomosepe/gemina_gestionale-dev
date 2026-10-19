-- Baseline: structure of the production project "Gestionale Gemina Advisory EU"
-- (gsnmtfugfhhrutmlvhzt) as read from its catalog on 2026-10-19 ~19:45 Europe/Rome.
-- Structure only, no data. Replaces the 5 migrations recorded in production
-- (part of the schema had been applied outside recorded migrations).
--
-- Production already contains all of this: there it must be marked as applied,
-- never run (see supabase/README.md). In a new or dev project it builds everything.

-- Extensions -----------------------------------------------------------------
create extension if not exists moddatetime schema extensions;
create extension if not exists pgcrypto schema extensions;

-- Schemas and types ----------------------------------------------------------
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create type public.user_role as enum ('client', 'partner', 'staff');
create type public.staff_role as enum ('admin', 'manager', 'associate');
create type public.conversation_kind as enum ('client', 'partner');

-- Tables -----------------------------------------------------------------------
create table public.organizations (
  id         uuid not null default gen_random_uuid() primary key,
  name       text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- private.default_organization_id() is needed by the defaults below, so the
-- functions that only read organizations are created before the other tables.
create function private.default_organization_id() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare
  n int;
  oid uuid;
begin
  select count(*), min(id::text)::uuid into n, oid from public.organizations;
  if n <> 1 then
    raise exception 'organization_id must be set explicitly: % organizations exist (multi-tenant rules not enabled yet)', n;
  end if;
  return oid;
end $$;

create table public.profiles (
  id              uuid not null primary key references auth.users(id) on delete cascade,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  name_first      text,
  name_last       text,
  email           text not null,
  role            public.user_role not null default 'client',
  organization_id uuid references public.organizations(id) on delete restrict,
  staff_role      public.staff_role,
  constraint profiles_staff_organization_check check ((role = 'staff') = (organization_id is not null)),
  constraint profiles_staff_role_check check ((role = 'staff') = (staff_role is not null))
);
create index profiles_organization_id_idx on public.profiles (organization_id);

create table public.companies (
  id              uuid not null default gen_random_uuid() primary key,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  name            text not null,
  zite_azienda_id text not null unique,
  organization_id uuid not null default private.default_organization_id()
                  references public.organizations(id) on delete restrict
);
create index companies_organization_id_idx on public.companies (organization_id);

create table public.company_members (
  company_id uuid not null references public.companies(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (company_id, profile_id)
);
create index company_members_profile_id_idx on public.company_members (profile_id);

create table public.partners (
  id                  uuid not null default gen_random_uuid() primary key,
  zite_segnalatore_id text not null unique,
  name                text not null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  organization_id     uuid not null default private.default_organization_id()
                      references public.organizations(id) on delete restrict,
  email               text
);
create index partners_organization_id_idx on public.partners (organization_id);
create unique index partners_email_key on public.partners (lower(email)) where email is not null;

create table public.partner_members (
  partner_id uuid not null references public.partners(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (partner_id, profile_id)
);
create index partner_members_profile_id_idx on public.partner_members (profile_id);

create table public.conversations (
  id                  uuid not null default gen_random_uuid() primary key,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  company_id          uuid references public.companies(id) on delete cascade,
  kind                public.conversation_kind not null default 'client',
  title               text not null,
  zite_pratica_id     text,
  created_by          uuid references public.profiles(id) on delete set null,
  partner_id          uuid references public.partners(id) on delete cascade,
  zite_provvigione_id text,
  organization_id     uuid not null references public.organizations(id) on delete restrict,
  zite_trattativa_id  text,
  constraint conversations_scope_check check (
    (kind = 'client' and company_id is not null and partner_id is null)
    or (kind = 'partner' and partner_id is not null))
);
create index conversations_company_id_idx on public.conversations (company_id);
create index conversations_partner_id_idx on public.conversations (partner_id);
create index conversations_created_by_idx on public.conversations (created_by);
create index conversations_organization_id_idx on public.conversations (organization_id);
create index conversations_zite_pratica_id_idx on public.conversations (zite_pratica_id);
create index conversations_zite_trattativa_id_idx on public.conversations (zite_trattativa_id);

create table public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  profile_id      uuid not null references public.profiles(id) on delete cascade,
  created_at      timestamptz not null default now(),
  last_read_at    timestamptz,
  primary key (conversation_id, profile_id)
);
create index conversation_members_profile_id_idx on public.conversation_members (profile_id);

create table public.messages (
  id              uuid not null default gen_random_uuid() primary key,
  created_at      timestamptz not null default now(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id       uuid references public.profiles(id) on delete set null,
  body            text not null check (char_length(body) between 1 and 10000),
  internal        boolean not null default false,
  deleted_at      timestamptz
);
create index messages_conversation_id_created_at_idx on public.messages (conversation_id, created_at);
create index messages_sender_id_idx on public.messages (sender_id);

create table public.documents (
  id                 uuid not null default gen_random_uuid() primary key,
  kind               public.conversation_kind not null,
  company_id         uuid references public.companies(id) on delete cascade,
  partner_id         uuid references public.partners(id) on delete cascade,
  conversation_id    uuid references public.conversations(id) on delete set null,
  message_id         uuid references public.messages(id) on delete set null,
  zite_pratica_id    text,
  title              text not null check (char_length(title) between 1 and 300),
  storage_path       text not null unique,
  mime_type          text,
  size_bytes         bigint check (size_bytes >= 0),
  shared             boolean not null default true,
  uploaded_by        uuid references public.profiles(id) on delete set null,
  deleted_at         timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  organization_id    uuid not null references public.organizations(id) on delete restrict,
  zite_trattativa_id text,
  constraint documents_scope_check check (
    (kind = 'client' and company_id is not null and partner_id is null)
    or (kind = 'partner' and partner_id is not null))
);
create index documents_company_id_idx on public.documents (company_id);
create index documents_partner_id_idx on public.documents (partner_id);
create index documents_conversation_id_idx on public.documents (conversation_id);
create index documents_message_id_idx on public.documents (message_id);
create index documents_uploaded_by_idx on public.documents (uploaded_by);
create index documents_organization_id_idx on public.documents (organization_id);
create index documents_zite_pratica_id_idx on public.documents (zite_pratica_id);
create index documents_zite_trattativa_id_idx on public.documents (zite_trattativa_id);

-- Helper functions (private schema: not reachable through the API) -------------
create function private.is_staff() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles
                 where id = (select auth.uid()) and role = 'staff');
$$;

create function private.current_staff_role() returns public.staff_role
language sql stable security definer set search_path = '' as $$
  select staff_role from public.profiles where id = (select auth.uid()) and role = 'staff';
$$;

create function private.can_manage_staff() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(private.current_staff_role() in ('admin', 'manager'), false);
$$;

create function private.is_company_member(cid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.company_members
                 where company_id = cid and profile_id = (select auth.uid()));
$$;

create function private.is_partner_member(pid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.partner_members
                 where partner_id = pid and profile_id = (select auth.uid()));
$$;

create function private.can_access_scope(k public.conversation_kind, cid uuid, pid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_staff()
      or (k = 'client'  and private.is_company_member(cid))
      or (k = 'partner' and private.is_partner_member(pid));
$$;

create function private.can_access_conversation(conv_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.conversations c
                 where c.id = conv_id
                   and private.can_access_scope(c.kind, c.company_id, c.partner_id));
$$;

create function private.can_see_profile(other uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select other = (select auth.uid())
      or private.is_staff()
      or exists (select 1 from public.messages m
                 where m.sender_id = other and not m.internal and m.deleted_at is null
                   and private.can_access_conversation(m.conversation_id));
$$;

create function private.can_access_document_path(path text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.documents d
    where d.storage_path = path
      and (private.is_staff()
           or (d.shared and d.deleted_at is null
               and private.can_access_scope(d.kind, d.company_id, d.partner_id))));
$$;

create function private.can_upload_document_path(path text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.documents d
    where d.storage_path = path
      and d.uploaded_by = (select auth.uid())
      and d.deleted_at is null);
$$;

-- Trigger functions --------------------------------------------------------------
create function private.set_organization_from_scope() returns trigger
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
  if new.organization_id is null then
    raise exception 'cannot determine organization for %', tg_table_name;
  end if;
  return new;
end $$;

create function private.set_staff_organization() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  actor_org uuid;
begin
  if new.role = 'staff' then
    if new.organization_id is null then
      select organization_id into actor_org
        from public.profiles
       where id = (select auth.uid()) and role = 'staff';
      new.organization_id := coalesce(actor_org, private.default_organization_id());
    end if;
    if new.staff_role is null then
      new.staff_role := 'associate';
    end if;
  else
    new.organization_id := null;
    new.staff_role := null;
  end if;
  return new;
end $$;

create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email);
  return new;
end $$;

-- Function privileges: nothing callable by visitors; the trigger by nobody.
revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;
revoke execute on function private.set_organization_from_scope() from authenticated;
revoke execute on function private.set_staff_organization() from authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- Triggers -------------------------------------------------------------------------
create trigger organizations_updated_at before update on public.organizations
  for each row execute function extensions.moddatetime(updated_at);
create trigger profiles_updated_at before update on public.profiles
  for each row execute function extensions.moddatetime(updated_at);
create trigger companies_updated_at before update on public.companies
  for each row execute function extensions.moddatetime(updated_at);
create trigger partners_updated_at before update on public.partners
  for each row execute function extensions.moddatetime(updated_at);
create trigger conversations_updated_at before update on public.conversations
  for each row execute function extensions.moddatetime(updated_at);
create trigger documents_updated_at before update on public.documents
  for each row execute function extensions.moddatetime(updated_at);

create trigger profiles_set_staff_organization
  before insert or update of role, organization_id, staff_role on public.profiles
  for each row execute function private.set_staff_organization();
create trigger conversations_set_organization
  before insert or update of company_id, partner_id, organization_id on public.conversations
  for each row execute function private.set_organization_from_scope();
create trigger documents_set_organization
  before insert or update of company_id, partner_id, organization_id on public.documents
  for each row execute function private.set_organization_from_scope();

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Table privileges -------------------------------------------------------------------
revoke all on all tables in schema public from anon;

-- Column-limited updates: nobody edits a message, a role or someone else's marker.
revoke update on public.profiles from authenticated;
grant update (name_first, name_last) on public.profiles to authenticated;
revoke update on public.conversation_members from authenticated;
grant update (last_read_at) on public.conversation_members to authenticated;
revoke update, delete on public.messages from authenticated;
grant update (deleted_at) on public.messages to authenticated;

-- Row Level Security ---------------------------------------------------------------------
alter table public.organizations        enable row level security;
alter table public.profiles             enable row level security;
alter table public.companies            enable row level security;
alter table public.company_members      enable row level security;
alter table public.partners             enable row level security;
alter table public.partner_members      enable row level security;
alter table public.conversations        enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages             enable row level security;
alter table public.documents            enable row level security;

create policy "organizations: staff read" on public.organizations
  for select to authenticated using (private.is_staff());

create policy "profiles: visible to self, staff and conversation peers" on public.profiles
  for select to authenticated using (private.can_see_profile(id));
create policy "profiles: update own name" on public.profiles
  for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy "companies: members read" on public.companies
  for select to authenticated using (private.is_company_member(id));
create policy "companies: staff manage" on public.companies
  for all to authenticated using (private.is_staff()) with check (private.is_staff());

create policy "company_members: read own" on public.company_members
  for select to authenticated using (profile_id = (select auth.uid()));
create policy "company_members: staff manage" on public.company_members
  for all to authenticated using (private.is_staff()) with check (private.is_staff());

create policy "partners: members read" on public.partners
  for select to authenticated using (private.is_partner_member(id));
create policy "partners: staff manage" on public.partners
  for all to authenticated using (private.is_staff()) with check (private.is_staff());

create policy "partner_members: read own" on public.partner_members
  for select to authenticated using (profile_id = (select auth.uid()));
create policy "partner_members: staff manage" on public.partner_members
  for all to authenticated using (private.is_staff()) with check (private.is_staff());

create policy "conversations: read if in scope" on public.conversations
  for select to authenticated using (private.can_access_scope(kind, company_id, partner_id));
create policy "conversations: staff manage" on public.conversations
  for all to authenticated using (private.is_staff()) with check (private.is_staff());
create policy "conversations: partner creates own" on public.conversations
  for insert to authenticated
  with check (kind = 'partner' and company_id is null
              and created_by = (select auth.uid())
              and private.is_partner_member(partner_id));

create policy "read markers: own" on public.conversation_members
  for select to authenticated
  using (profile_id = (select auth.uid()) or private.is_staff());
create policy "read markers: create own" on public.conversation_members
  for insert to authenticated
  with check (profile_id = (select auth.uid()) and private.can_access_conversation(conversation_id));
create policy "read markers: update own" on public.conversation_members
  for update to authenticated
  using (profile_id = (select auth.uid()))
  with check (profile_id = (select auth.uid()) and private.can_access_conversation(conversation_id));

create policy "messages: read" on public.messages
  for select to authenticated
  using (private.is_staff()
         or (not internal and deleted_at is null and private.can_access_conversation(conversation_id)));
create policy "messages: send" on public.messages
  for insert to authenticated
  with check (sender_id = (select auth.uid()) and deleted_at is null
              and (private.is_staff() or (not internal and private.can_access_conversation(conversation_id))));
create policy "messages: staff soft-delete" on public.messages
  for update to authenticated using (private.is_staff()) with check (private.is_staff());

create policy "documents: read" on public.documents
  for select to authenticated
  using (private.is_staff()
         or (shared and deleted_at is null and private.can_access_scope(kind, company_id, partner_id)));
create policy "documents: upload" on public.documents
  for insert to authenticated
  with check (uploaded_by = (select auth.uid()) and deleted_at is null
              and (private.is_staff() or (shared and private.can_access_scope(kind, company_id, partner_id))));
create policy "documents: staff update" on public.documents
  for update to authenticated using (private.is_staff()) with check (private.is_staff());

-- Storage ------------------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documents', 'documents', false, 26214400, array[
  'application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.oasis.opendocument.text',
  'application/vnd.oasis.opendocument.spreadsheet',
  'application/pkcs7-mime', 'application/x-pkcs7-mime',
  'application/zip', 'text/plain', 'text/csv'])
on conflict (id) do nothing;

create policy "documents bucket: read" on storage.objects
  for select to authenticated
  using (bucket_id = 'documents' and private.can_access_document_path(name));
create policy "documents bucket: upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'documents' and private.can_upload_document_path(name));
create policy "documents bucket: staff delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'documents' and private.is_staff());

-- Realtime ------------------------------------------------------------------------------------
alter publication supabase_realtime add table public.messages;
