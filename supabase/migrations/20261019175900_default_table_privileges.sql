-- Default privileges for new tables in schema public, so a clean project behaves like production.
--
-- Production was created with Supabase's default of "automatically expose new tables": every table made by
-- the postgres role in public is granted to authenticated and service_role (not to anon). Later migrations
-- rely on that and narrow it with explicit revokes (for example "revoke update, delete on public.messages
-- from authenticated"). A project created with the option off has no such default, so those tables stay
-- closed and the tests fail with "permission denied".
--
-- This file sorts just before the baseline, so on a clean project it runs first. On production the default
-- already exists, so it changes nothing. Row access is still decided by the row level security policies.
alter default privileges for role postgres in schema public grant all on tables to authenticated, service_role;
alter default privileges for role postgres in schema public grant usage, select on sequences to authenticated, service_role;
