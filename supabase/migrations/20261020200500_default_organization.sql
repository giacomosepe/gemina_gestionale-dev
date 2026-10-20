-- The one organization (Gemina Advisory). Every staff profile and every conversation gets it from
-- private.default_organization_id(), which refuses to guess unless exactly one organization exists.
-- Dev already has it (created before the baseline); a new production project has none, and the first staff
-- login would fail without this. Does nothing when an organization already exists.
insert into public.organizations (name)
select 'Gemina Advisory'
 where not exists (select 1 from public.organizations);
