-- Roles are managed in Supabase from 12 Nov 2026 (Giacomo). The Zite Ruoli table still decides who is in the team (the bridge creates or
-- brings back the staff profile, with Zite's role as the starting role), but it no longer changes the role of someone who is already staff:
-- only public.set_staff_role (permission staff.manage) does. The bridge keeps sending staff_role; for existing staff the write is ignored.

create or replace function private.profiles_keep_staff_role()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.role = 'staff' and new.role = 'staff'
     and new.staff_role is distinct from old.staff_role
     and coalesce(current_setting('gemina.staff_role_change', true), '') <> 'on' then
    new.staff_role := old.staff_role;
  end if;
  return new;
end
$$;
revoke execute on function private.profiles_keep_staff_role() from public, anon, authenticated;

-- Runs before profiles_set_staff_organization (triggers fire in name order).
create trigger profiles_keep_staff_role
  before update of staff_role on public.profiles
  for each row execute function private.profiles_keep_staff_role();

-- Change a colleague's role. Not one's own (so the last administrator can never demote themselves).
create or replace function public.set_staff_role(p_profile uuid, p_role public.staff_role)
returns public.staff_role
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old public.staff_role;
  v_org uuid;
begin
  if not private.has_permission('staff.manage') then
    raise exception 'Solo un amministratore può cambiare i ruoli del team.' using errcode = '42501';
  end if;
  if p_role is null then
    raise exception 'Indica il ruolo.' using errcode = '22023';
  end if;
  if p_profile = (select auth.uid()) then
    raise exception 'Non puoi cambiare il tuo ruolo: chiedilo a un altro amministratore.' using errcode = '22023';
  end if;
  select staff_role, organization_id into v_old, v_org
    from public.profiles where id = p_profile and role = 'staff' for update;
  if not found or v_org is distinct from (select organization_id from public.profiles where id = (select auth.uid())) then
    raise exception 'Collega non trovato.' using errcode = '22023';
  end if;
  if v_old is not distinct from p_role then
    return p_role;
  end if;
  perform set_config('gemina.staff_role_change', 'on', true);
  update public.profiles set staff_role = p_role where id = p_profile;
  perform set_config('gemina.staff_role_change', 'off', true);
  return p_role;
end
$$;
revoke execute on function public.set_staff_role(uuid, public.staff_role) from public, anon;
grant execute on function public.set_staff_role(uuid, public.staff_role) to authenticated;