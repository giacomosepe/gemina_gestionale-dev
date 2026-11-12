-- Staff permissions, step 1: catalog, role -> permission matrix (from the «Matrice permessi Gestionale» sheet, 12 Nov 2026)
-- and the helpers. Nothing calls the helpers yet: no one's access changes with this migration.

create table public.permissions (
  key         text primary key check (key ~ '^[a-z_]+\.[a-z_]+$'),
  area        text not null check (char_length(area) between 1 and 60),
  description text not null check (char_length(description) between 1 and 300),
  created_at  timestamptz not null default now()
);
comment on table public.permissions is 'Catalog of staff permissions; functions and policies check these keys through private.has_permission()';

create table public.role_permissions (
  organization_id uuid not null default private.default_organization_id() references public.organizations (id),
  staff_role      public.staff_role not null,
  permission      text not null references public.permissions (key) on update cascade,
  scope           text not null default 'all' check (scope in ('all', 'own')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  primary key (organization_id, staff_role, permission)
);
comment on table public.role_permissions is 'Which staff role holds which permission, per organization. No row = not allowed. scope own = only on the records the person is responsible for (defined per permission)';
comment on column public.role_permissions.scope is 'all = every record; own = only records the person is responsible for (the meaning is set per permission before it is enforced)';
create index role_permissions_permission_idx on public.role_permissions (permission);

create trigger role_permissions_updated_at before update on public.role_permissions
  for each row execute function moddatetime('updated_at');

alter table public.permissions enable row level security;
alter table public.role_permissions enable row level security;

create policy "permissions: staff read" on public.permissions
  for select to authenticated using ((select private.is_staff()));
create policy "role_permissions: staff read" on public.role_permissions
  for select to authenticated using ((select private.is_staff()));
-- Writes: service role only for now; an admin screen will come with its own function (permission staff.manage).

revoke all on public.permissions, public.role_permissions from anon;
revoke insert, update, delete, truncate on public.permissions, public.role_permissions from authenticated;

-- The caller's scope for a permission: 'all', 'own', or null (not allowed). Current staff only.
create or replace function private.permission_scope(p_permission text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select rp.scope
    from public.profiles pr
    join public.role_permissions rp
      on rp.staff_role = pr.staff_role
     and rp.organization_id = pr.organization_id
     and rp.permission = p_permission
   where pr.id = (select auth.uid())
     and pr.role = 'staff';
$$;

create or replace function private.has_permission(p_permission text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.permission_scope(p_permission) is not null;
$$;

revoke execute on function private.permission_scope(text), private.has_permission(text) from public, anon;
grant execute on function private.permission_scope(text), private.has_permission(text) to authenticated;

insert into public.permissions (key, area, description) values
  ('commissions.view',              'Provvigioni',            'See all commission lines and their stages'),
  ('commissions.mark_invoiced',     'Provvigioni',            'Mark commissions as invoiced by the segnalatore'),
  ('commissions.mark_paid',         'Provvigioni',            'Mark commissions as paid'),
  ('commissions.correct',           'Provvigioni',            'Correct or undo invoiced and paid marks'),
  ('commissions.rebuild',           'Provvigioni',            'Rebuild all commission lines'),
  ('invoices.link_company',         'Fatture Qonto',          'Link a Qonto invoice to a company'),
  ('invoices.link_pratica',         'Fatture Qonto',          'Link or unlink an invoice to a pratica'),
  ('supplier_invoices.view',        'Fatture fornitori',      'See supplier invoices and summaries'),
  ('supplier_invoices.import',      'Fatture fornitori',      'Import supplier invoices from Drive'),
  ('supplier_invoices.assign',      'Fatture fornitori',      'Assign invoice lines to beni'),
  ('supplier_invoices.credit_notes','Fatture fornitori',      'Include or exclude credit notes from totals'),
  ('supplier_invoices.delete',      'Fatture fornitori',      'Delete supplier invoices'),
  ('suppliers.categorize',          'Fatture fornitori',      'Categorize suppliers'),
  ('pratiche.set_beneficiary',      'Pratiche',               'Set the beneficiary company of a pratica'),
  ('scadenze.manage',               'Pratiche',               'Manage scadenze'),
  ('reminders.manage',              'Pratiche',               'Manage reminders'),
  ('beni.manage',                   'Pratiche',               'Manage beni, their values and documents'),
  ('upload_portal.create',          'Portale caricamento',    'Create an upload link for a client'),
  ('upload_portal.revoke',          'Portale caricamento',    'Revoke an upload link'),
  ('signatures.manage',             'Firme',                  'Prepare signature attachments and their files'),
  ('signatures.send',               'Firme',                  'Send for signature and mark as signed'),
  ('documents.share',               'Documenti e messaggi',   'Share documents and notify the segnalatore'),
  ('documents.remove_any',          'Documenti e messaggi',   'Remove a document someone else uploaded'),
  ('messages.send',                 'Documenti e messaggi',   'Message segnalatori and clients'),
  ('comments.write',                'Documenti e messaggi',   'Write internal comments'),
  ('companies.manage',              'Anagrafiche e accessi',  'Edit companies'),
  ('partners.manage',               'Anagrafiche e accessi',  'Manage segnalatori and their portal access'),
  ('company_members.manage',        'Anagrafiche e accessi',  'Manage client portal access'),
  ('staff.manage',                  'Anagrafiche e accessi',  'Manage team members and their roles'),
  ('vat.edit',                      'IVA',                    'Edit VAT settlements');

-- The matrix as Giacomo filled it in (Yes = all, Own only = own, No = no row).
insert into public.role_permissions (staff_role, permission, scope)
select m.staff_role::public.staff_role, m.permission, m.scope
from (values
  ('admin','commissions.view','all'),('manager','commissions.view','all'),('associate','commissions.view','all'),
  ('admin','commissions.mark_invoiced','all'),('manager','commissions.mark_invoiced','all'),
  ('admin','commissions.mark_paid','all'),('manager','commissions.mark_paid','own'),
  ('admin','commissions.correct','all'),('manager','commissions.correct','all'),
  ('admin','commissions.rebuild','all'),
  ('admin','invoices.link_company','all'),('manager','invoices.link_company','all'),('associate','invoices.link_company','own'),
  ('admin','invoices.link_pratica','all'),('manager','invoices.link_pratica','all'),('associate','invoices.link_pratica','all'),
  ('admin','supplier_invoices.view','all'),('manager','supplier_invoices.view','all'),('associate','supplier_invoices.view','all'),
  ('admin','supplier_invoices.import','all'),('manager','supplier_invoices.import','all'),('associate','supplier_invoices.import','all'),
  ('admin','supplier_invoices.assign','all'),('manager','supplier_invoices.assign','all'),('associate','supplier_invoices.assign','all'),
  ('admin','supplier_invoices.credit_notes','all'),
  ('admin','supplier_invoices.delete','all'),('manager','supplier_invoices.delete','all'),('associate','supplier_invoices.delete','all'),
  ('admin','suppliers.categorize','all'),('manager','suppliers.categorize','all'),('associate','suppliers.categorize','all'),
  ('admin','pratiche.set_beneficiary','all'),('manager','pratiche.set_beneficiary','all'),('associate','pratiche.set_beneficiary','all'),
  ('admin','scadenze.manage','all'),('manager','scadenze.manage','all'),('associate','scadenze.manage','all'),
  ('admin','reminders.manage','all'),('manager','reminders.manage','all'),('associate','reminders.manage','all'),
  ('admin','beni.manage','all'),('manager','beni.manage','all'),('associate','beni.manage','all'),
  ('admin','upload_portal.create','all'),('manager','upload_portal.create','all'),
  ('admin','upload_portal.revoke','all'),('manager','upload_portal.revoke','all'),('associate','upload_portal.revoke','all'),
  ('admin','signatures.manage','all'),('manager','signatures.manage','all'),('associate','signatures.manage','all'),
  ('admin','signatures.send','all'),('manager','signatures.send','all'),('associate','signatures.send','all'),
  ('admin','documents.share','all'),('manager','documents.share','all'),('associate','documents.share','all'),
  ('admin','documents.remove_any','all'),('manager','documents.remove_any','all'),
  ('admin','messages.send','all'),('manager','messages.send','all'),('associate','messages.send','all'),
  ('admin','comments.write','all'),('manager','comments.write','all'),('associate','comments.write','all'),
  ('admin','companies.manage','all'),('manager','companies.manage','all'),('associate','companies.manage','all'),
  ('admin','partners.manage','all'),('manager','partners.manage','own'),
  ('admin','company_members.manage','all'),('manager','company_members.manage','all'),('associate','company_members.manage','all'),
  ('admin','staff.manage','all'),
  ('admin','vat.edit','all')
) as m(staff_role, permission, scope);