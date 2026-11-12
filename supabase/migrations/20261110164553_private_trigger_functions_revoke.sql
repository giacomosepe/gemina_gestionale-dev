-- Six SECURITY DEFINER trigger functions in schema private kept the default EXECUTE for PUBLIC (created 4-6 Nov in the migrations recovered on
-- 9 Nov), unlike the other 18 private trigger functions. Not exploitable (a trigger function cannot be called directly and anon has no usage on
-- private), but aligned so that test 032 (security guard) admits no exception. Firing a trigger does not check EXECUTE: nothing changes for writes.
revoke execute on function
  private.beni_before_write(),
  private.supplier_invoices_before_write(),
  private.supplier_invoice_lines_before_write(),
  private.supplier_allocation_guard(),
  private.supplier_allocation_log(),
  private.pratiche_lock_company()
from public, anon, authenticated;
