-- Two fixes to 20261023190000_invoice_pratica_link (found by test 015 and the security advisor right after applying it). Replacing statements only.
-- 1. pratica_payment_status_v.archivable was NULL (not false) for a pratica with no total; it is now always true or false.
-- 2. private.fully_paid_tolerance_cents had no fixed search_path (advisor warning function_search_path_mutable).

create or replace function private.fully_paid_tolerance_cents() returns bigint
language sql immutable set search_path = '' as $$ select 1000::bigint $$;

create or replace view public.pratica_payment_status_v with (security_invoker = true) as
with money as (
  select d.pratica_id,
         coalesce(sum(d.net_cents) filter (where d.status <> 'Annullata'), 0)::bigint as invoiced_net_cents,
         coalesce(sum(d.net_cents) filter (where d.status = 'Incassata'), 0)::bigint as paid_net_cents,
         count(*)::int as documents
    from public.qonto_documents d
   where d.pratica_id is not null and d.removed_at is null
   group by d.pratica_id),
calc as (
  select p.id, p.code, p.company_id, p.status, p.is_open, p.total_fee_cents,
         coalesce(m.invoiced_net_cents, 0) as invoiced_net_cents, coalesce(m.paid_net_cents, 0) as paid_net_cents,
         coalesce(m.documents, 0) as documents, private.fully_paid_tolerance_cents() as tolerance_cents
    from public.pratiche p left join money m on m.pratica_id = p.id
   where p.removed_at is null)
select c.id as pratica_id, c.code, c.company_id, c.status, c.is_open, c.total_fee_cents,
       c.invoiced_net_cents, c.paid_net_cents,
       case when c.total_fee_cents is null then null else c.total_fee_cents - c.paid_net_cents end as outstanding_cents,
       c.tolerance_cents, c.documents as linked_documents,
       s.payment_state,
       (s.payment_state is null or s.payment_state = 'overpaid') as needs_review,
       case when s.payment_state is null then 'total_missing' when s.payment_state = 'overpaid' then 'overpaid' end as review_reason,
       coalesce(s.payment_state = 'fully_paid', false) as archivable
  from calc c
  cross join lateral (select case
      when c.total_fee_cents is null or c.total_fee_cents <= 0 then null
      when c.paid_net_cents <= 0 then 'partial'
      when c.paid_net_cents < c.total_fee_cents - c.tolerance_cents then 'partial'
      when c.paid_net_cents > c.total_fee_cents + c.tolerance_cents then 'overpaid'
      else 'fully_paid' end as payment_state) s;
