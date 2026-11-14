-- A row whose organization cannot be determined (a fresh profile when several organizations exist) is not logged, instead of failing the write.
create or replace function private.audit_row() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  o jsonb; n jsonb;
  old_diff jsonb; new_diff jsonb;
  row_json jsonb;
  org uuid;
begin
  if tg_op = 'INSERT' then n := to_jsonb(new); row_json := n;
  elsif tg_op = 'DELETE' then o := to_jsonb(old); row_json := o;
  else
    o := to_jsonb(old); n := to_jsonb(new); row_json := n;
    select coalesce(jsonb_object_agg(k, o -> k) filter (where (o -> k) is distinct from (n -> k)), '{}'),
           coalesce(jsonb_object_agg(k, n -> k) filter (where (o -> k) is distinct from (n -> k)), '{}')
      into old_diff, new_diff
      from jsonb_object_keys(n) k where k <> 'updated_at';
    if new_diff = '{}'::jsonb then return null; end if;      -- nothing but updated_at changed
    o := old_diff; n := new_diff;
  end if;

  org := (row_json ->> 'organization_id')::uuid;
  if org is null and tg_table_name = 'profiles' then org := private.profile_organization_id((row_json ->> 'id')::uuid); end if;
  if org is null then
    -- a profile that belongs to nobody yet (a fresh sign-up when several organizations exist) has no organization to log under: skip it
    begin org := private.default_organization_id(); exception when others then return null; end;
  end if;

  insert into public.audit_log (organization_id, actor_id, table_name, row_id, action, old_values, new_values)
  values (org, (select auth.uid()), tg_table_name, row_json ->> 'id', lower(tg_op), o, n);
  return null;
end $$;
revoke all on function private.audit_row() from public, anon, authenticated;
