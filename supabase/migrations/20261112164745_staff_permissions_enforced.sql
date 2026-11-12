-- Staff permissions, step 2: actions and writes check the permission matrix (public.role_permissions) instead of "any staff".
-- Reads stay open to all staff (every role has the view permissions). "own" = segnalatori of which the person is Reference Manager;
-- for invoices.link_company, companies brought by such a segnalatore (a referral, not removed).

create or replace function private.can_on_partner(p_permission text, p_partner uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case private.permission_scope(p_permission)
           when 'all' then true
           when 'own' then p_partner is not null and private.is_reference_manager(p_partner)
           else false
         end;
$$;

create or replace function private.can_on_company(p_permission text, p_company uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case private.permission_scope(p_permission)
           when 'all' then true
           when 'own' then p_company is not null and exists (
             select 1 from public.referrals r join public.partners pa on pa.id = r.partner_id
              where r.company_id = p_company and r.removed_at is null and pa.reference_manager_id = (select auth.uid()))
           else false
         end;
$$;
revoke execute on function private.can_on_partner(text, uuid), private.can_on_company(text, uuid) from public, anon;
grant execute on function private.can_on_partner(text, uuid), private.can_on_company(text, uuid) to authenticated;

-- Functions: replace exactly one known snippet each, keeping the rest of the definition (and its grants) as it is.
do $do$
declare
  r record;
  def text;
  hits int;
begin
  for r in select * from (values
    (1,  'public.assign_supplier_invoices(uuid[],uuid,uuid)', $x$if not private.is_staff() then$x$, $x$if not private.has_permission('supplier_invoices.assign') then$x$),
    (2,  'public.create_upload_portal(uuid,text,integer)', $x$if not private.is_staff() then$x$, $x$if not private.has_permission('upload_portal.create') then$x$),
    (3,  'public.create_upload_portal(uuid,text,integer)', $x$Solo lo staff può creare un link di caricamento.$x$, $x$Il tuo ruolo non permette di creare link di caricamento.$x$),
    (4,  'public.revoke_upload_portal(uuid)', $x$if not private.is_staff() then$x$, $x$if not private.has_permission('upload_portal.revoke') then$x$),
    (5,  'public.invoice_pratica_options(uuid)', $x$if not (select private.is_staff()) then$x$, $x$if not private.has_permission('invoices.link_pratica') then$x$),
    (6,  'public.link_invoice_to_company(uuid,uuid)', $x$if not (select private.is_staff()) then$x$, $x$if not private.can_on_company('invoices.link_company', p_company) then$x$),
    (7,  'public.link_invoice_to_company(uuid,uuid)', $x$Solo il team Gemina può collegare le fatture alle aziende.$x$, $x$Il tuo ruolo non permette di collegare fatture a questa azienda.$x$),
    (8,  'public.link_invoice_to_pratica(uuid,uuid)', $x$if not (select private.is_staff()) then$x$, $x$if not private.has_permission('invoices.link_pratica') then$x$),
    (9,  'public.unlink_invoice_pratica(uuid)', $x$if not (select private.is_staff()) then$x$, $x$if not private.has_permission('invoices.link_pratica') then$x$),
    (10, 'public.mark_commissions_invoiced(uuid[],text,date)', $x$if not (select private.is_staff()) then$x$, $x$if not private.has_permission('commissions.mark_invoiced') then$x$),
    (11, 'public.mark_commissions_invoiced(uuid[],text,date)', $x$Solo il team Gemina può segnare le provvigioni come fatturate.$x$, $x$Il tuo ruolo non permette di segnare le provvigioni come fatturate.$x$),
    (12, 'public.mark_commissions_paid(uuid[],date)', $x$if not (select private.is_staff()) then$x$, $x$if private.permission_scope('commissions.mark_paid') is null then$x$),
    (13, 'public.mark_commissions_paid(uuid[],date)', $x$Solo il team Gemina può segnare le provvigioni come ricevute.$x$, $x$Il tuo ruolo non permette di segnare le provvigioni come ricevute.$x$),
    (14, 'public.mark_commissions_paid(uuid[],date)', $x$perform 1 from public.commissions c where c.id = any(v_ids) order by c.id for update;$x$,
         $x$if private.permission_scope('commissions.mark_paid') = 'own'
     and exists (select 1 from public.commissions c where c.id = any(v_ids) and not private.is_reference_manager(c.partner_id)) then
    raise exception 'Puoi segnare come ricevute solo le provvigioni dei segnalatori di cui sei Reference Manager.' using errcode = '42501';
  end if;
  perform 1 from public.commissions c where c.id = any(v_ids) order by c.id for update;$x$),
    (15, 'private.commission_correction_lines(uuid[],text,text,text)', $x$if not (select private.is_staff()) then$x$, $x$if not private.has_permission('commissions.correct') then$x$),
    (16, 'private.commission_correction_lines(uuid[],text,text,text)', $x$'Solo il team Gemina può %.'$x$, $x$'Il tuo ruolo non permette di %.'$x$),
    (17, 'public.correct_commission_invoice(uuid[],text,date)', $x$if not (select private.is_staff()) then$x$, $x$if not private.has_permission('commissions.correct') then$x$),
    (18, 'public.correct_commission_invoice(uuid[],text,date)', $x$Solo il team Gemina può correggere le provvigioni.$x$, $x$Il tuo ruolo non permette di correggere le provvigioni.$x$),
    (19, 'public.unmark_commissions_invoiced(uuid[])', $x$if (select private.is_staff()) and exists$x$, $x$if private.has_permission('commissions.correct') and exists$x$),
    (20, 'public.notify_document(uuid)', $x$if not private.is_staff() or not found$x$, $x$if not private.has_permission('documents.share') or not found$x$),
    (21, 'public.remove_document(uuid)', $x$not (private.is_staff() or (d.uploaded_by = uid$x$, $x$not (private.has_permission('documents.remove_any') or (d.uploaded_by = uid$x$),
    (22, 'public.rebuild_all_commissions()', $x$if not exists (select 1 from public.profiles where id = (select auth.uid()) and role = 'staff' and staff_role = 'admin') then$x$, $x$if not private.has_permission('commissions.rebuild') then$x$),
    (23, 'public.set_credit_notes_included(uuid,uuid[],boolean)', $x$if not (select private.is_staff()) then$x$, $x$if not private.has_permission('supplier_invoices.credit_notes') then$x$),
    (24, 'public.set_pratica_beneficiary(uuid,uuid)', $x$if not private.is_staff() or private.current_staff_role() is distinct from 'admin' then$x$, $x$if not private.has_permission('pratiche.set_beneficiary') then$x$),
    (25, 'public.set_pratica_beneficiary(uuid,uuid)', $x$'Solo un amministratore può impostare l''azienda beneficiaria.'$x$, $x$'Il tuo ruolo non permette di impostare l''azienda beneficiaria.'$x$),
    (26, 'public.set_supplier_allocation(uuid,uuid[],uuid[],jsonb)', $x$if not (select private.is_staff()) then$x$, $x$if not private.has_permission('supplier_invoices.assign') then$x$),
    (27, 'public.set_supplier_category(uuid[],uuid)', $x$if not (select private.is_staff()) then$x$, $x$if not private.has_permission('suppliers.categorize') then$x$),
    (28, 'public.delete_supplier_invoices(uuid,uuid[])', $x$if not (select private.is_staff()) then$x$, $x$if not private.has_permission('supplier_invoices.delete') then$x$),
    (29, 'private.can_manage_staff()', $x$select coalesce(private.current_staff_role() in ('admin', 'manager'), false);$x$, $x$select private.has_permission('staff.manage');$x$)
  ) v(n, fn, old_text, new_text) order by n
  loop
    def := pg_get_functiondef(r.fn::regprocedure);
    hits := (length(def) - length(replace(def, r.old_text, ''))) / length(r.old_text);
    if hits <> 1 then
      raise exception 'Step %: expected the snippet once in %, found % times', r.n, r.fn, hits;
    end if;
    execute replace(def, r.old_text, r.new_text);
  end loop;
end
$do$;

-- Policies. ALL policies that also gave staff their reads: a separate staff read policy keeps reads as they were.
create policy "beni: staff read" on public.beni for select to authenticated using ((select private.is_staff()));
alter policy "beni: staff manage" on public.beni
  using ((select private.has_permission('beni.manage'))) with check ((select private.has_permission('beni.manage')));
alter policy "beni: staff manage" on public.beni rename to "beni: manage";

create policy "bene_values: staff read" on public.bene_values for select to authenticated using ((select private.is_staff()));
alter policy "bene_values: staff manage" on public.bene_values
  using ((select private.has_permission('beni.manage'))) with check ((select private.has_permission('beni.manage')));
alter policy "bene_values: staff manage" on public.bene_values rename to "bene_values: manage";

create policy "bene_documents: staff read" on public.bene_documents for select to authenticated using ((select private.is_staff()));
alter policy "bene_documents: staff manage" on public.bene_documents
  using ((select private.has_permission('beni.manage'))) with check ((select private.has_permission('beni.manage')));
alter policy "bene_documents: staff manage" on public.bene_documents rename to "bene_documents: manage";

create policy "supplier_invoice_allocations: staff read" on public.supplier_invoice_allocations for select to authenticated using ((select private.is_staff()));
alter policy "supplier_invoice_allocations: staff manage" on public.supplier_invoice_allocations
  using ((select private.has_permission('supplier_invoices.assign'))) with check ((select private.has_permission('supplier_invoices.assign')));
alter policy "supplier_invoice_allocations: staff manage" on public.supplier_invoice_allocations rename to "supplier_invoice_allocations: manage";

create policy "companies: staff read" on public.companies for select to authenticated using ((select private.is_staff()));
alter policy "companies: staff manage" on public.companies
  using ((select private.has_permission('companies.manage'))) with check ((select private.has_permission('companies.manage')));
alter policy "companies: staff manage" on public.companies rename to "companies: manage";

create policy "company_members: staff read" on public.company_members for select to authenticated using ((select private.is_staff()));
alter policy "company_members: staff manage" on public.company_members
  using ((select private.has_permission('company_members.manage'))) with check ((select private.has_permission('company_members.manage')));
alter policy "company_members: staff manage" on public.company_members rename to "company_members: manage";

create policy "conversations: staff read" on public.conversations for select to authenticated using ((select private.is_staff()));
alter policy "conversations: staff manage" on public.conversations
  using ((select private.has_permission('messages.send'))) with check ((select private.has_permission('messages.send')));
alter policy "conversations: staff manage" on public.conversations rename to "conversations: manage";

create policy "partners: staff read" on public.partners for select to authenticated using ((select private.is_staff()));
alter policy "partners: staff manage" on public.partners
  using (private.can_on_partner('partners.manage', id)) with check (private.can_on_partner('partners.manage', id));
alter policy "partners: staff manage" on public.partners rename to "partners: manage";

create policy "partner_members: staff read" on public.partner_members for select to authenticated using ((select private.is_staff()));
alter policy "partner_members: staff manage" on public.partner_members
  using (private.can_on_partner('partners.manage', partner_id)) with check (private.can_on_partner('partners.manage', partner_id));
alter policy "partner_members: staff manage" on public.partner_members rename to "partner_members: manage";

alter policy "comments: staff write own" on public.comments
  with check ((select private.has_permission('comments.write')) and author_id = (select auth.uid()) and deleted_at is null);
alter policy "comments: author edits own" on public.comments
  using (author_id = (select auth.uid()) and (select private.has_permission('comments.write')))
  with check (author_id = (select auth.uid()) and (select private.has_permission('comments.write')));

alter policy "documents: upload" on public.documents
  with check (uploaded_by = (select auth.uid()) and deleted_at is null
              and ((select private.has_permission('documents.share')) or (shared and private.can_access_scope(kind, company_id, partner_id))));
alter policy "documents: staff update" on public.documents
  using ((select private.has_permission('documents.share'))) with check ((select private.has_permission('documents.share')));

alter policy "messages: send" on public.messages
  with check (sender_id = (select auth.uid()) and deleted_at is null
              and ((select private.has_permission('messages.send')) or ((not internal) and private.can_access_conversation(conversation_id))));
alter policy "messages: staff soft-delete" on public.messages
  using ((select private.has_permission('messages.send'))) with check ((select private.has_permission('messages.send')));

alter policy "reminders: staff insert" on public.reminders with check ((select private.has_permission('reminders.manage')));
alter policy "reminders: staff update" on public.reminders
  using ((select private.has_permission('reminders.manage'))) with check ((select private.has_permission('reminders.manage')));
alter policy "reminders: staff delete" on public.reminders using ((select private.has_permission('reminders.manage')));

alter policy "scadenze: staff insert" on public.scadenze with check ((select private.has_permission('scadenze.manage')));
alter policy "scadenze: staff update" on public.scadenze
  using ((select private.has_permission('scadenze.manage'))) with check ((select private.has_permission('scadenze.manage')));

alter policy "signature_attachments: staff insert" on public.signature_attachments with check ((select private.has_permission('signatures.manage')));
alter policy "signature_attachments: staff update" on public.signature_attachments
  using ((select private.has_permission('signatures.manage'))) with check ((select private.has_permission('signatures.manage')));
alter policy "signature_attachment_files: staff insert" on public.signature_attachment_files with check ((select private.has_permission('signatures.manage')));
alter policy "signature_attachment_files: staff update" on public.signature_attachment_files
  using ((select private.has_permission('signatures.manage'))) with check ((select private.has_permission('signatures.manage')));

alter policy "supplier_invoices: staff delete" on public.supplier_invoices using ((select private.has_permission('supplier_invoices.delete')));

alter policy "vat_settlements: admin insert" on public.vat_settlements with check ((select private.has_permission('vat.edit')));
alter policy "vat_settlements: admin update" on public.vat_settlements
  using ((select private.has_permission('vat.edit'))) with check ((select private.has_permission('vat.edit')));
alter policy "vat_settlements: admin delete" on public.vat_settlements using ((select private.has_permission('vat.edit')));