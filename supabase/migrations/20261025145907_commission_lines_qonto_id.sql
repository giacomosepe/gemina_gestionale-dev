-- commission_lines_v (PRDDISC-24): one more column at the end, the Qonto id of the invoice. The Gestionale screens know an invoice by its Qonto id
-- (src/lib/supabase/fatture.ts), so a commission line can be matched to the invoice shown under its pratica. Replacing, additive (a column at the end).

create or replace view public.commission_lines_v with (security_invoker = true) as
select s.*,
       pt.zite_segnalatore_id,
       co.zite_azienda_id,
       co.name as company_name,
       pr.code as pratica_code,
       d.kind as invoice_kind,
       d.net_cents as invoice_net_cents,
       d.qonto_id as invoice_qonto_id
  from public.commission_stages_v s
  join public.partners pt on pt.id = s.partner_id
  join public.qonto_documents d on d.id = s.invoice_id
  left join public.companies co on co.id = s.company_id
  left join public.pratiche pr on pr.id = s.pratica_id;
