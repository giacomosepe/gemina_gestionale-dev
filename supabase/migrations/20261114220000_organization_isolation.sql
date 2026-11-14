-- Organization isolation (Linear PM-149). Until now one organization existed and the staff policies were global (private.is_staff()).
-- Four rules make a second organization possible later without a rewrite:
--   1. every business table has organization_id not null (nine child tables get it here),
--   2. one helper, private.current_organization_id(), says which organization the signed-in user belongs to,
--   3. functions and defaults take the organization from that helper,
--   4. a test with two organizations proves that nothing crosses (supabase/tests/038_organization_isolation.sql).
-- With one organization nothing changes for anyone. A restrictive policy on every table is ANDed with the policies that exist.

-- 1. the helper ---------------------------------------------------------------------------------------------------------------
-- Staff: the organization on the profile. Clients and referrers: the organization of their company or partner. Nobody else: null (sees nothing).
create function private.current_organization_id() returns uuid
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select p.organization_id from public.profiles p where p.id = (select auth.uid())),
    (select c.organization_id from public.company_members m join public.companies c on c.id = m.company_id
      where m.profile_id = (select auth.uid()) limit 1),
    (select pa.organization_id from public.partner_members m join public.partners pa on pa.id = m.partner_id
      where m.profile_id = (select auth.uid()) limit 1))
$$;

-- The organization of any profile (same rule), used so that staff of one organization do not read the profiles of another.
create function private.profile_organization_id(p_profile uuid) returns uuid
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select p.organization_id from public.profiles p where p.id = p_profile),
    (select c.organization_id from public.company_members m join public.companies c on c.id = m.company_id where m.profile_id = p_profile limit 1),
    (select pa.organization_id from public.partner_members m join public.partners pa on pa.id = m.partner_id where m.profile_id = p_profile limit 1))
$$;

revoke all on function private.current_organization_id(), private.profile_organization_id(uuid) from public, anon;
grant execute on function private.current_organization_id(), private.profile_organization_id(uuid) to authenticated;

-- The default of organization_id: the signed-in user's organization; without a user (jobs, imports) the only organization, as before.
create or replace function private.default_organization_id() returns uuid
language plpgsql stable security definer set search_path = ''
as $$
declare
  n int;
  org uuid := private.current_organization_id();
begin
  if org is not null then return org; end if;
  select count(*), min(id::text)::uuid into n, org from public.organizations;
  if n <> 1 then
    raise exception 'organization_id must be set explicitly: % organizations exist and nobody is signed in', n;
  end if;
  return org;
end $$;

-- 2. organization_id on the child tables -------------------------------------------------------------------------------------
alter table public.company_members add column organization_id uuid references public.organizations(id) on delete restrict;
update public.company_members t set organization_id = c.organization_id from public.companies c where c.id = t.company_id;
alter table public.partner_members add column organization_id uuid references public.organizations(id) on delete restrict;
update public.partner_members t set organization_id = c.organization_id from public.partners c where c.id = t.partner_id;
alter table public.conversation_members add column organization_id uuid references public.organizations(id) on delete restrict;
update public.conversation_members t set organization_id = c.organization_id from public.conversations c where c.id = t.conversation_id;
alter table public.messages add column organization_id uuid references public.organizations(id) on delete restrict;
update public.messages t set organization_id = c.organization_id from public.conversations c where c.id = t.conversation_id;
alter table public.reminder_sends add column organization_id uuid references public.organizations(id) on delete restrict;
update public.reminder_sends t set organization_id = c.organization_id from public.reminders c where c.id = t.reminder_id;
alter table public.commission_notices add column organization_id uuid references public.organizations(id) on delete restrict;
update public.commission_notices t set organization_id = c.organization_id from public.commissions c where c.id = t.commission_id;
alter table public.commission_rebuild_errors add column organization_id uuid references public.organizations(id) on delete restrict;
alter table public.qonto_documents add column organization_id uuid references public.organizations(id) on delete restrict;
alter table public.qonto_sync_runs add column organization_id uuid references public.organizations(id) on delete restrict;

do $$
declare t text;
begin
  -- rows whose parent is gone or not set take the only organization (there is exactly one until now)
  foreach t in array array['company_members','partner_members','conversation_members','messages','reminder_sends','commission_notices',
                           'commission_rebuild_errors','qonto_documents','qonto_sync_runs'] loop
    execute format('update public.%I set organization_id = private.default_organization_id() where organization_id is null', t);
    execute format('alter table public.%I alter column organization_id set not null', t);
    execute format('alter table public.%I alter column organization_id set default private.default_organization_id()', t);
    execute format('create index %I on public.%I (organization_id)', t || '_organization_id_idx', t);
  end loop;
end $$;

-- 3. one restrictive policy on every table with organization_id ---------------------------------------------------------------
-- Restrictive = ANDed with the existing policies: a row must pass those AND belong to the user's organization.
do $$
declare t text;
begin
  for t in
    select c.relname from pg_class c
     where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
       and c.relname not in ('profiles', 'organizations')
       and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'organization_id' and not a.attisdropped)
  loop
    execute format('create policy %I on public.%I as restrictive for all to authenticated using (organization_id = (select private.current_organization_id())) with check (organization_id = (select private.current_organization_id()))',
                   t || ': organization', t);
  end loop;
end $$;

-- the organization itself, and profiles (clients and referrers have no organization of their own: it comes from their company or partner;
-- a profile that belongs to nothing yet, such as a fresh invitation, stays visible as before)
create policy "organizations: own organization" on public.organizations as restrictive for all to authenticated
  using (id = (select private.current_organization_id())) with check (id = (select private.current_organization_id()));
create policy "profiles: organization" on public.profiles as restrictive for all to authenticated
  using (id = (select auth.uid()) or (select private.profile_organization_id(id)) is null or (select private.profile_organization_id(id)) = (select private.current_organization_id()))
  with check (id = (select auth.uid()) or (select private.profile_organization_id(id)) is null or (select private.profile_organization_id(id)) = (select private.current_organization_id()));
