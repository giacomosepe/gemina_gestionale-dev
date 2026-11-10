-- Fatture fornitori: the two views read again with the rights of WHO READS (2026-11-10).
-- They were created with security_invoker = true (20261104112817_supplier_invoices_v3); the next day 20261105161322_supplier_invoices_credit_note_review
-- re-created them with «create or replace view» and no options, which turned them back into SECURITY DEFINER views: they ignored the RLS of the tables
-- below, so any signed-in user (a segnalatore too) could read every supplier invoice line through them. Flagged as ERROR by the security advisor.
-- Checked before applying (rolled back): with the option set, a staff member still reads every row (53 / 50), a segnalatore none. Test 030.
-- NOTE for whoever changes these views again: «create or replace view» must repeat «with (security_invoker = true)».

alter view public.supplier_invoice_lines_status set (security_invoker = true);
alter view public.supplier_invoice_by_bene set (security_invoker = true);
