-- The organization helpers are also run by service_role (jobs and functions that insert with the column default).
grant execute on function private.current_organization_id(), private.profile_organization_id(uuid), private.default_organization_id() to service_role;
