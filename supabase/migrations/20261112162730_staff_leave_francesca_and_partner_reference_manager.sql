-- 1. Francesca Sepe left the team (removed from the Zite Ruoli table): same effect as the bridge's staff_leave.
--    Profile kept (name stays on old records), access ends: every rule checks role = 'staff'.
update public.profiles
   set role = 'former_staff', staff_role = null, organization_id = null
 where zite_user_id = 'ZfsDwZjUmMEX9MK6jb3LJbu6ExvBSCAA' and role = 'staff';
update public.notifications set read_at = now()
 where read_at is null
   and recipient_id = (select id from public.profiles where zite_user_id = 'ZfsDwZjUmMEX9MK6jb3LJbu6ExvBSCAA');

-- 2. Reference manager of each segnalatore: the Gemina colleague responsible for them.
--    Defines "own" for the permissions with scope 'own' (commissions.mark_paid, partners.manage).
alter table public.partners
  add column reference_manager_id uuid references public.profiles (id);
comment on column public.partners.reference_manager_id is
  'Gemina colleague responsible for this segnalatore (Reference Manager); set in Supabase only, never by the Zite sync. Must be current staff when set';
create index partners_reference_manager_idx on public.partners (reference_manager_id) where reference_manager_id is not null;

create or replace function private.partners_reference_manager_check()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.reference_manager_id is not null
     and new.reference_manager_id is distinct from old.reference_manager_id
     and not exists (select 1 from public.profiles p where p.id = new.reference_manager_id and p.role = 'staff') then
    raise exception 'Il Reference Manager deve essere un membro attuale del team Gemina.' using errcode = '22023';
  end if;
  return new;
end
$$;
revoke execute on function private.partners_reference_manager_check() from public, anon, authenticated;

create trigger partners_reference_manager_check
  before insert or update of reference_manager_id on public.partners
  for each row execute function private.partners_reference_manager_check();

-- "Own" for a segnalatore: the caller is its reference manager.
create or replace function private.is_reference_manager(p_partner uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.partners pa
                  where pa.id = p_partner and pa.reference_manager_id = (select auth.uid()));
$$;
revoke execute on function private.is_reference_manager(uuid) from public, anon;
grant execute on function private.is_reference_manager(uuid) to authenticated;