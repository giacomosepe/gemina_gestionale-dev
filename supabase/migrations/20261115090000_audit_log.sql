-- Audit log (Linear PM-150): who changed what, when. One table, one generic trigger, attached to every business table.
-- Readable by admins of the organization only; written by the trigger only (nobody can insert, update or delete through the API).
-- Not audited, on purpose: tables that are logs or technical records themselves (listed in private.audit_excluded_tables and in test 039).

create table public.audit_log (
  id              bigint generated always as identity primary key,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  occurred_at     timestamptz not null default now(),
  actor_id        uuid,                       -- auth.uid(); null for jobs, imports and the database itself
  table_name      text not null,
  row_id          text,                       -- the id of the row (text, so any key type fits)
  action          text not null check (action in ('insert', 'update', 'delete')),
  old_values      jsonb,                      -- delete: the whole row; update: only the columns that changed
  new_values      jsonb                       -- insert: the whole row; update: only the columns that changed
);
create index audit_log_row_idx on public.audit_log (table_name, row_id, occurred_at desc);
create index audit_log_organization_idx on public.audit_log (organization_id, occurred_at desc);
create index audit_log_actor_idx on public.audit_log (actor_id, occurred_at desc) where actor_id is not null;

alter table public.audit_log enable row level security;
revoke all on public.audit_log from anon, authenticated;
grant select on public.audit_log to authenticated;
create policy "audit_log: admin read" on public.audit_log for select to authenticated
  using ((select private.current_staff_role()) = 'admin');
create policy "audit_log: organization" on public.audit_log as restrictive for all to authenticated
  using (organization_id = (select private.current_organization_id())) with check (organization_id = (select private.current_organization_id()));

-- The tables that are not audited.
create function private.audit_excluded_tables() returns text[]
language sql immutable set search_path = ''
as $$ select array['audit_log', 'qonto_sync_runs', 'commission_rebuild_errors', 'reminder_sends', 'supplier_invoice_allocation_log',
                   'commission_corrections', 'signature_events', 'notifications', 'supplier_invoice_import_runs', 'conversation_members', 'permissions'] $$;

-- The trigger function. Security definer: the signed-in user has no right to write to audit_log, the trigger does it for them.
create function private.audit_row() returns trigger
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
  if org is null then org := private.default_organization_id(); end if;

  insert into public.audit_log (organization_id, actor_id, table_name, row_id, action, old_values, new_values)
  values (org, (select auth.uid()), tg_table_name, row_json ->> 'id', lower(tg_op), o, n);
  return null;
end $$;
revoke all on function private.audit_row() from public, anon, authenticated;

-- Attach the trigger to one table (also used by later migrations that add a table).
create function private.add_audit_trigger(p_table regclass) returns void
language plpgsql set search_path = ''
as $$
begin
  execute format('create trigger audit after insert or update or delete on %s for each row execute function private.audit_row()', p_table);
end $$;
revoke all on function private.add_audit_trigger(regclass) from public, anon, authenticated;

do $$
declare t text;
begin
  for t in
    select c.relname from pg_class c
     where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and c.relname <> all (private.audit_excluded_tables())
  loop
    perform private.add_audit_trigger(format('public.%I', t)::regclass);
  end loop;
end $$;
