-- Staff accounts follow the Gestionale's team table (Zite "Ruoli"), decided by Giacomo on 2026-10-20.
--
-- Ruoli is the only list of Gemina's team (Amministratore -> staff_role 'admin', Manager -> 'manager').
-- The Gestionale, which now refuses anyone without a Ruoli row, tells the bridge (staff secret) who the
-- person is; the bridge creates or updates the staff profile on first use and demotes it when the person
-- leaves the team. Nobody is made staff from a browser.
--
-- Leaving the team = role 'former_staff' (staff_role and organization_id cleared by the existing checks):
-- every rule that tests role = 'staff' stops applying at once, and the profile stays so old messages keep
-- the author's name. Coming back = role 'staff' again.
--
-- Note: a value added to an enum cannot be used in the same transaction, so nothing below uses it.

alter type public.user_role add value if not exists 'former_staff';

-- The Zite user id of a team member: the stable link between a Zite user and their Supabase profile
-- (emails can change; notifications from Zite name recipients by Zite user id).
alter table public.profiles add column zite_user_id text;
create unique index profiles_zite_user_id_key on public.profiles (zite_user_id) where zite_user_id is not null;
comment on column public.profiles.zite_user_id is
  'Zite user id (Gestionale team members only). Set by the portal-bridge from the Gestionale; never by a browser.';
comment on type public.user_role is
  'client | partner (a segnalatore) | staff (Gemina team, mirrors Zite Ruoli) | former_staff (left the team: no access, kept for history)';
