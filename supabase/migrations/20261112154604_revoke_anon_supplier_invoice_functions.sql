revoke execute on function public.supplier_invoices_page(uuid, integer, integer, integer, jsonb) from public, anon;
revoke execute on function public.supplier_invoices_summary(uuid, jsonb) from public, anon;
grant execute on function public.supplier_invoices_page(uuid, integer, integer, integer, jsonb) to authenticated;
grant execute on function public.supplier_invoices_summary(uuid, jsonb) to authenticated;