-- Catalogue of services (Linear PM-153, the pilot domain). The Zite tables Categorie, Strumenti, Dati, Campi strumento, Fasi di attivita, Attivita modello,
-- Attivita standard and Opzioni become eight tables with English names (glossary): service_categories, services, data_requests, service_fields,
-- milestones, activity_templates, standard_activities, lookup_options.
-- Reading: any staff. Writing: the permission catalog.manage (administrators). Every row keeps its Zite id in legacy_id (import runner, PM-164).
-- Empty in Zite and left out on purpose: Scadenze milestone and Layout schede (no rows; revisit when the screens are built).
-- Text columns whose name starts with legacy_ hold the Zite value as it was; they are replaced when the screens that use them are rebuilt.

-- 1. permission -------------------------------------------------------------------------------------------------------------
insert into public.permissions (key, area, description) values ('catalog.manage', 'catalog', 'Edit the catalogue: services, categories, data requests, milestones, activity templates')
on conflict (key) do nothing;
insert into public.role_permissions (organization_id, staff_role, permission, scope)
select o.id, 'admin', 'catalog.manage', 'all' from public.organizations o
on conflict do nothing;

-- 2. tables -----------------------------------------------------------------------------------------------------------------
create table public.service_categories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations (id) on delete restrict,
  legacy_id text,
  name text not null,
  position integer not null default 0,
  active boolean not null default true,
  macro_category text,
  standard_terms text,
  required_documents text,
  deadline_templates jsonb,                 -- Zite scadenzeModello: list of {chiave, nome, genere, ordine, quante, quando, cartella}
  output_template jsonb,                    -- Zite outputModello
  legacy_active_milestones jsonb,           -- Zite milestoneAttive: [{m: <Zite milestone id>}]
  legacy_active_activities jsonb,           -- Zite attivitaAttive: [{a: <Zite activity id>}]
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.service_categories is 'Catalogue: category of services (Zite Categorie). Holds the templates its services inherit.';

create table public.services (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations (id) on delete restrict,
  legacy_id text,
  category_id uuid references public.service_categories (id) on delete restrict,
  name text not null,
  short_name text,
  kind text check (kind in ('grant_call', 'tax_incentive')),                       -- Zite Tipo: Bando, Agevolazione fiscale
  status text check (status in ('upcoming', 'open', 'closed')),                    -- Zite Stato: In arrivo, Aperto, Chiuso
  active boolean not null default true,
  position integer not null default 0,
  authority text,                           -- Zite Ente
  managing_body text,                       -- Zite Soggetto gestore
  info_url text,
  call_document_url text,
  opens_on date,
  closes_on date,
  procedure text,                           -- label chosen from lookup_options (kind 'procedure')
  aid_regime text,                          -- label from lookup_options (kind 'aid_regime')
  benefit_types text[] not null default '{}',     -- labels from lookup_options (kind 'benefit_type')
  budget_cents bigint,
  max_intensity_pct numeric,
  max_contribution_cents bigint,
  min_expense_cents bigint,
  max_expense_cents bigint,
  beneficiaries text[] not null default '{}',
  allowed_sizes text[] not null default '{}',
  allowed_regions text[] not null default '{}',
  included_ateco text,
  excluded_ateco text,
  min_company_age_months numeric,
  special_requirements text[] not null default '{}',
  funded_expenses text[] not null default '{}',
  cases_to_check text,
  notes text,
  standard_terms text,
  resources text,
  required_documents text,
  lines text,
  original_folders text,
  reviewed boolean not null default false,
  reviewed_on date,
  deadline_templates jsonb,
  legacy_active_milestones jsonb,
  legacy_active_activities jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.services is 'Catalogue: a grant call or tax incentive Gemina can handle (Zite Strumenti). Classification lists hold the labels as data (editable in lookup_options); only kind and status are fixed codes.';

create table public.data_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations (id) on delete restrict,
  legacy_id text,
  name text not null,
  data_type text check (data_type in ('number', 'text', 'date', 'yes_no', 'choice', 'money', 'document', 'multi_choice', 'person')),
  lifetime text check (lifetime in ('permanent', 'temporary')),                    -- Zite genere
  feeds text,                               -- Zite alimenta (for example baseCommissione)
  save_on_company boolean not null default false,
  save_on_contact boolean not null default false,
  save_on_deal boolean not null default false,
  save_on_case boolean not null default false,
  save_on_asset boolean not null default false,
  required_by_default boolean not null default false,
  validity text check (validity in ('none', 'months', 'until_deadline', 'until_next')),
  validity_months numeric,
  options text,                             -- one option per line (choice, multi_choice)
  help text,
  archived boolean not null default false,
  local_only boolean not null default false,
  local_owner text,
  legacy_target_column text,                -- Zite colonna: the column of the old company/deal/case record it fills; mapped to the new names with the domain that owns it
  section text,
  signatures_required numeric,
  signers text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.data_requests is 'Catalogue: one piece of data or one document the team collects (Zite Dati, "dati da raccogliere").';

create table public.service_fields (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations (id) on delete restrict,
  legacy_id text,
  category_id uuid references public.service_categories (id) on delete restrict,
  service_id uuid references public.services (id) on delete restrict,
  data_request_id uuid references public.data_requests (id) on delete restrict,
  label text not null,
  field_type text check (field_type in ('number', 'text', 'date', 'money', 'choice', 'multi_choice')),   -- only the older own fields have one; the others take it from the data request
  options text,
  required boolean not null default false,
  initial_value text,
  help text,
  position integer not null default 0,
  active boolean not null default true,
  feeds text,
  required_on_deal text check (required_on_deal in ('required', 'optional')),
  required_on_case text check (required_on_case in ('required', 'optional')),
  shown_in_deadlines jsonb,                 -- Zite inScadenze: list of deadline keys
  asked_in_deadlines jsonb,                 -- Zite daChiedereIn
  per_deadline boolean,
  template text,
  template_version text,
  template_on_every_case boolean,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.service_fields is 'Catalogue: a data request attached to a category or a service, with the rules for deals and cases (Zite Campi strumento).';

create table public.milestones (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations (id) on delete restrict,
  legacy_id text,
  category_id uuid references public.service_categories (id) on delete restrict,
  name text not null,
  position integer not null default 0,
  active boolean not null default true,
  days numeric,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.milestones is 'Catalogue: a phase of the work of a category (Zite Fasi di attivita). The links to cases move with the cases (M4).';

create table public.activity_templates (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations (id) on delete restrict,
  legacy_id text,
  category_id uuid references public.service_categories (id) on delete restrict,
  service_id uuid references public.services (id) on delete restrict,
  milestone_id uuid references public.milestones (id) on delete restrict,
  title text not null,
  description text,
  days numeric,
  owner text,
  kind text,
  position integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.activity_templates is 'Catalogue: an activity created on a case from its category or service (Zite Attivita modello).';

create table public.standard_activities (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations (id) on delete restrict,
  legacy_id text,
  milestone_id uuid references public.milestones (id) on delete restrict,
  title text not null,
  description text,
  days numeric,
  owner text,
  position integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.standard_activities is 'Catalogue: an activity every case of a milestone gets (Zite Attivita standard).';

create table public.lookup_options (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null default private.default_organization_id() references public.organizations (id) on delete restrict,
  legacy_id text,
  kind text not null,                       -- procedure, aid_regime, benefit_type (Zite campo: procedura, regimeDiAiuto, tipoAgevolazione)
  label text not null,
  position integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.lookup_options is 'Catalogue: the labels an administrator can choose from in the service form (Zite Opzioni).';

-- 3. keys, indexes, triggers, access -----------------------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['service_categories', 'services', 'data_requests', 'service_fields', 'milestones', 'activity_templates', 'standard_activities', 'lookup_options'] loop
    execute format('create unique index %I on public.%I (organization_id, legacy_id) where legacy_id is not null', t || '_legacy_id_key', t);
    execute format('create trigger %I before update on public.%I for each row execute function moddatetime(''updated_at'')', t || '_updated_at', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('create policy %I on public.%I as restrictive for all to authenticated using (organization_id = (select private.current_organization_id())) with check (organization_id = (select private.current_organization_id()))', t || ': organization', t);
    execute format('create policy %I on public.%I for select to authenticated using ((select private.is_staff()))', t || ': staff read', t);
    execute format('create policy %I on public.%I for insert to authenticated with check ((select private.has_permission(''catalog.manage'')))', t || ': catalog.manage insert', t);
    execute format('create policy %I on public.%I for update to authenticated using ((select private.has_permission(''catalog.manage''))) with check ((select private.has_permission(''catalog.manage'')))', t || ': catalog.manage update', t);
    execute format('create policy %I on public.%I for delete to authenticated using ((select private.has_permission(''catalog.manage'')))', t || ': catalog.manage delete', t);
    perform private.add_audit_trigger(format('public.%I', t)::regclass);
  end loop;
end $$;

create index services_category_id_idx on public.services (category_id);
create index service_fields_category_id_idx on public.service_fields (category_id);
create index service_fields_service_id_idx on public.service_fields (service_id);
create index service_fields_data_request_id_idx on public.service_fields (data_request_id);
create index milestones_category_id_idx on public.milestones (category_id);
create index activity_templates_category_id_idx on public.activity_templates (category_id);
create index activity_templates_service_id_idx on public.activity_templates (service_id);
create index activity_templates_milestone_id_idx on public.activity_templates (milestone_id);
create index standard_activities_milestone_id_idx on public.standard_activities (milestone_id);
create index lookup_options_kind_idx on public.lookup_options (organization_id, kind);
