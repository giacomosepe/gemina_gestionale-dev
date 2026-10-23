-- Invoice to pratica link and pratica payment status (Linear PRDDISC-12, milestone M2). Additive (columns, functions, views); two functions replaced
-- (private.sync_pratiche gets one more line).
--
-- Link rule, as in Zite (sincronizzaQonto): an invoice whose company has exactly ONE open pratica is linked to it; else, if the company has exactly one
-- pratica in total, to that one; else it stays unlinked and is listed for review (review_invoices_v). As in Zite, a pratica once assigned is never changed by
-- the rule (it may have been corrected by hand). A link made by staff (set_invoice_pratica) or copied from Zite is never overwritten by the rule; a pratica
-- unlinked by hand stays unlinked (link source 'manual' with no pratica).
-- pratica_link_source: auto (the rule), manual (staff, through the bridge/service role: no browser can write), zite (copied from the Zite Fatture links).
-- zite_pratica_id (M1 column, kept) is filled with the pratica's Zite UUID text when linked.
--
-- Payment status (PRDDISC-1 rule 4, Giacomo 2026-10-23): paid net = net (imponibile, no VAT) of the linked documents with status Incassata, credit notes
-- (negative, settled) included, cancelled and removed ones left out, compared with the pratica's total_fee_cents (Zite's "Commissioni totali", net of VAT).
-- Tolerance: 1,000 cents (10 EUR) from ONE named setting, private.fully_paid_tolerance_cents(); to change it, replace that function in a new migration.
-- States: partial (paid below total minus tolerance, or nothing paid), fully_paid (within the tolerance), overpaid (above total plus tolerance: needs_review,
-- not archivable). No total (null or 0): payment_state null and needs_review. archivable = fully_paid; whether the pratica is also closed is NOT decided in
-- PRDDISC-1, so it is not encoded here (is_open is in the view for the app to combine). No commission logic.

-- 1. Link columns ------------------------------------------------------------------------------------------------------------------
alter table public.qonto_documents
  add column pratica_id uuid references public.pratiche(id) on delete set null,
  add column pratica_link_source text check (pratica_link_source in ('auto', 'manual', 'zite')),
  add constraint qonto_documents_pratica_link_check check (pratica_id is null or pratica_link_source is not null);
create index qonto_documents_pratica_id_idx on public.qonto_documents (pratica_id) where pratica_id is not null;
comment on column public.qonto_documents.pratica_id is 'The pratica (mirror, Zite UUID) the document belongs to; null = unlinked (review_invoices_v)';
comment on column public.qonto_documents.pratica_link_source is 'auto = link rule, manual = staff (a manual with no pratica = unlinked on purpose), zite = copied from Zite; the rule only fills documents that have no link source, so it never changes an existing link';

-- 2. The rule ----------------------------------------------------------------------------------------------------------------------
create function private.pratica_for_company(p_company uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  with p as (select id, is_open from public.pratiche where company_id = p_company and removed_at is null)
  select case when (select count(*) from p where is_open) = 1 then (select id from p where is_open)
              when (select count(*) from p) = 1 then (select id from p) end;
$$;

create function private.documents_link_pratica() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.pratica_id is null and new.pratica_link_source is null and new.company_id is not null
     and new.removed_at is null and new.status <> 'Annullata' then
    new.pratica_id := private.pratica_for_company(new.company_id);
    if new.pratica_id is not null then
      new.pratica_link_source := 'auto';
      new.zite_pratica_id := new.pratica_id::text;
    end if;
  end if;
  return new;
end $$;
create trigger qonto_documents_link_pratica before insert or update on public.qonto_documents
  for each row execute function private.documents_link_pratica();

-- Documents still unlinked get their pratica when it becomes known (a pratica arrives from Zite after the invoice).
create function private.link_invoices_to_pratiche() returns integer
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update public.qonto_documents d
     set pratica_id = x.pid, pratica_link_source = 'auto', zite_pratica_id = x.pid::text
    from (select id, private.pratica_for_company(company_id) as pid
            from public.qonto_documents
           where pratica_id is null and pratica_link_source is null and company_id is not null
             and removed_at is null and status <> 'Annullata') x
   where d.id = x.id and x.pid is not null;
  get diagnostics n = row_count;
  return n;
end $$;

-- Manual link by staff (called through the bridge / service role, never by a browser). p_pratica null = unlink on purpose.
create function private.set_invoice_pratica(p_document uuid, p_pratica uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_pratica is not null and not exists (select 1 from public.pratiche where id = p_pratica and removed_at is null) then
    raise exception 'pratica not found' using errcode = '23503';
  end if;
  update public.qonto_documents
     set pratica_id = p_pratica, pratica_link_source = 'manual', zite_pratica_id = p_pratica::text
   where id = p_document;
  if not found then
    raise exception 'document not found' using errcode = '23503';
  end if;
end $$;

-- sync_pratiche (migration pratiche_mirror) + one line: link the invoices that were waiting for their pratica.
create or replace function private.sync_pratiche(p_rows jsonb, p_mark_missing boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  ins  int := 0;
  upd  int := 0;
  gone int := 0;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows must be a json array' using errcode = '22023';
  end if;
  with up as (
    insert into public.pratiche as t (id, code, zite_azienda_id, status, is_open, total_fee_cents, removed_at, synced_at)
    select r.id, r.code, r.zite_azienda_id, r.status, r.is_open, r.total_fee_cents, case when r.removed then now() end, now()
      from jsonb_to_recordset(p_rows) as r(id uuid, code text, zite_azienda_id text, status text, is_open boolean,
                                           total_fee_cents bigint, removed boolean)
    on conflict (id) do update set
      code = excluded.code, zite_azienda_id = excluded.zite_azienda_id, status = excluded.status, is_open = excluded.is_open,
      total_fee_cents = excluded.total_fee_cents,
      removed_at = case when excluded.removed_at is null then null else coalesce(t.removed_at, excluded.removed_at) end,
      synced_at = now()
    returning (xmax = 0) as inserted)
  select count(*) filter (where inserted), count(*) filter (where not inserted) into ins, upd from up;

  if p_mark_missing and jsonb_array_length(p_rows) > 0 then
    update public.pratiche set removed_at = now()
     where removed_at is null and id not in (select (e->>'id')::uuid from jsonb_array_elements(p_rows) e);
    get diagnostics gone = row_count;
  end if;
  perform private.link_invoices_to_pratiche();
  return jsonb_build_object('inserted', ins, 'updated', upd, 'marked_removed', gone);
end $$;

-- 3. The one named setting ----------------------------------------------------------------------------------------------------------
create function private.fully_paid_tolerance_cents() returns bigint
language sql immutable as $$ select 1000::bigint $$;
comment on function private.fully_paid_tolerance_cents() is 'Tolerance (cents) around a pratica total for "fully paid": 1000 = 10 EUR (PRDDISC-1 rule 4); change by replacing this function';

revoke execute on function private.pratica_for_company(uuid) from public, anon, authenticated;
revoke execute on function private.documents_link_pratica() from public, anon, authenticated;
revoke execute on function private.link_invoices_to_pratiche() from public, anon, authenticated;
revoke execute on function private.set_invoice_pratica(uuid, uuid) from public, anon, authenticated;
revoke execute on function private.sync_pratiche(jsonb, boolean) from public, anon, authenticated;
revoke execute on function private.fully_paid_tolerance_cents() from public, anon;
grant execute on function private.fully_paid_tolerance_cents() to authenticated, service_role;

-- 4. Views (security_invoker: RLS of qonto_documents and pratiche applies; staff only) ----------------------------------------------------
create view public.pratica_payment_status_v with (security_invoker = true) as
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
       (s.payment_state = 'fully_paid') as archivable
  from calc c
  cross join lateral (select case
      when c.total_fee_cents is null or c.total_fee_cents <= 0 then null
      when c.paid_net_cents <= 0 then 'partial'
      when c.paid_net_cents < c.total_fee_cents - c.tolerance_cents then 'partial'
      when c.paid_net_cents > c.total_fee_cents + c.tolerance_cents then 'overpaid'
      else 'fully_paid' end as payment_state) s;
comment on view public.pratica_payment_status_v is 'Per pratica: total fee, invoiced and paid net (credit notes subtracted, cancelled left out), outstanding, payment_state partial/fully_paid/overpaid, needs_review, archivable';

create view public.review_invoices_v with (security_invoker = true) as
select d.id, d.qonto_id, d.kind, d.number, d.status, d.issue_date, d.net_cents, d.total_cents, d.company_id, d.qonto_client_id, d.pratica_id,
       case when d.company_id is null then 'company_unknown'
            when not exists (select 1 from public.pratiche p where p.company_id = d.company_id and p.removed_at is null) then 'no_pratica'
            else 'ambiguous' end as reason_code,
       case when d.company_id is null then 'Cliente Qonto non collegato a nessuna azienda'
            when not exists (select 1 from public.pratiche p where p.company_id = d.company_id and p.removed_at is null) then 'L''azienda non ha pratiche'
            else 'Più pratiche aperte (o più pratiche in totale): scegli a mano' end as reason
  from public.qonto_documents d
 where d.pratica_id is null and d.pratica_link_source is null and d.removed_at is null and d.status <> 'Annullata'
union all
select d.id, d.qonto_id, d.kind, d.number, d.status, d.issue_date, d.net_cents, d.total_cents, d.company_id, d.qonto_client_id, d.pratica_id,
       'company_mismatch', 'L''azienda della fattura è diversa da quella della pratica'
  from public.qonto_documents d
  join public.pratiche p on p.id = d.pratica_id
 where d.removed_at is null and d.status <> 'Annullata'
   and d.company_id is not null and p.company_id is not null and d.company_id <> p.company_id;
comment on view public.review_invoices_v is 'Invoices to link or check: unlinked (company unknown, no pratica, ambiguous; links made by hand are not listed) and linked to a pratica of another company';

revoke all on public.pratica_payment_status_v, public.review_invoices_v from public, anon, authenticated;
grant select on public.pratica_payment_status_v, public.review_invoices_v to authenticated;
grant select on public.pratica_payment_status_v, public.review_invoices_v to service_role;
