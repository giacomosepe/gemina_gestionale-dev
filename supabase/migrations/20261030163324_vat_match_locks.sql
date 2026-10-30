-- PRDDISC-34, second step: row locks in the VAT matching and in link_invoice_to_company, and the list says other_qonto_client when the Qonto client is held by another company.
-- The first step (20261030163121_vat_match_companies.sql) went to production as the version tested on 30 Oct; this replaces three objects, same signatures and columns.

create or replace function private.link_invoices_to_companies_by_vat() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  g record;
  c record;
  n int;
  go boolean;
  v_linked int := 0; v_companies int := 0; v_no_vat int := 0; v_no_company int := 0; v_ambiguous int := 0; v_other int := 0;
begin
  for g in
    select d.qonto_client_id as qid, k.vkey, array_agg(d.id order by d.id) as ids
      from public.qonto_documents d
      cross join lateral (select private.vat_key(coalesce(nullif(btrim(d.raw->'client'->>'vat_number'), ''),
                                                          nullif(btrim(d.raw->'client'->>'tax_identification_number'), ''))) as vkey) k
     where d.company_id is null and d.removed_at is null
     group by d.qonto_client_id, k.vkey
  loop
    if g.vkey is null then v_no_vat := v_no_vat + cardinality(g.ids); continue; end if;
    select count(*) into n from public.companies co where private.vat_key(co.vat_number) = g.vkey;
    if n = 0 then v_no_company := v_no_company + cardinality(g.ids); continue; end if;
    if n > 1 then v_ambiguous := v_ambiguous + cardinality(g.ids); continue; end if;
    -- lock the company first (same order as link_invoice_to_company: company, then invoices) and read its Qonto id after the lock, so two sessions
    -- can never both see it empty and both link; if the row stopped matching while we waited, skip it (the next run looks again)
    select co.id, co.qonto_client_id into c from public.companies co where private.vat_key(co.vat_number) = g.vkey for update;
    if not found then continue; end if;
    if g.qid is not null and c.qonto_client_id is not null and c.qonto_client_id <> g.qid then
      v_other := v_other + cardinality(g.ids); continue;
    end if;
    go := true;
    if g.qid is not null and c.qonto_client_id is null then
      begin
        update public.companies set qonto_client_id = g.qid where id = c.id and qonto_client_id is null;
        get diagnostics n = row_count;
        if n = 0 then
          go := false; v_other := v_other + cardinality(g.ids);   -- not expected under the lock; never link without the id written
        else
          v_companies := v_companies + 1;
        end if;
      exception when unique_violation then
        -- another company already holds this Qonto client id: never take it over
        go := false; v_other := v_other + cardinality(g.ids);
      end;
    end if;
    if go then
      update public.qonto_documents set company_id = c.id where id = any(g.ids) and company_id is null;
      get diagnostics n = row_count;
      v_linked := v_linked + n;
    end if;
  end loop;
  return jsonb_build_object('linked', v_linked, 'companies_updated', v_companies, 'no_vat', v_no_vat, 'no_company', v_no_company,
                            'ambiguous', v_ambiguous, 'other_qonto_client', v_other);
end $$;
revoke execute on function private.link_invoices_to_companies_by_vat() from public, anon, authenticated;
comment on function private.link_invoices_to_companies_by_vat() is 'Links invoices with company_id null to the ONE company with the same VAT key; fills an empty qonto_client_id, never replaces one; returns the counts';

create or replace view public.invoices_to_link_v with (security_invoker = true) as
with docs as (
  select d.id, d.qonto_id, d.kind, d.number, d.status, d.issue_date, d.net_cents, d.total_cents, d.qonto_client_id,
         nullif(btrim(coalesce(d.raw->'client'->>'name', concat_ws(' ', d.raw->'client'->>'first_name', d.raw->'client'->>'last_name'))), '') as qonto_client_name,
         coalesce(nullif(btrim(d.raw->'client'->>'vat_number'), ''), nullif(btrim(d.raw->'client'->>'tax_identification_number'), '')) as qonto_vat
    from public.qonto_documents d
   where d.company_id is null and d.removed_at is null and (select private.is_staff())
), keyed as (
  select docs.*, private.vat_key(docs.qonto_vat) as vat_key from docs
)
select k.id, k.qonto_id, k.kind, k.number, k.status, k.issue_date, k.net_cents, k.total_cents, k.qonto_client_id, k.qonto_client_name, k.qonto_vat, k.vat_key,
       case when k.vat_key is null then 'no_vat'
            when m.n = 0 then 'no_company'
            when m.n > 1 then 'ambiguous'
            when (k.qonto_client_id is not null and m.first_qid is not null and m.first_qid <> k.qonto_client_id) or m.held_elsewhere then 'other_qonto_client'
            else 'to_be_linked' end as reason_code,
       case when k.vat_key is null then 'Il cliente Qonto non ha partita IVA né codice fiscale: scegli l''azienda a mano'
            when m.n = 0 then 'Nessuna azienda ha questa partita IVA: scegli l''azienda a mano o correggi la partita IVA dell''azienda'
            when m.n > 1 then 'Più aziende hanno questa partita IVA: scegli a mano'
            when (k.qonto_client_id is not null and m.first_qid is not null and m.first_qid <> k.qonto_client_id) or m.held_elsewhere then 'L''azienda con questa partita IVA è già collegata a un altro cliente Qonto, oppure questo cliente Qonto è già di un''altra azienda: controlla o scegli a mano'
            else 'Verrà collegata da sola al prossimo aggiornamento da Qonto' end as reason,
       cand.candidates
  from keyed k
  left join lateral (
    select count(*) as n, (array_agg(c.qonto_client_id))[1] as first_qid, (array_agg(c.id))[1] as first_id,
           -- the invoice's Qonto client is already held by a company other than the one the VAT points to (the matching and the staff action refuse it)
           (k.qonto_client_id is not null and exists (select 1 from public.companies h where h.qonto_client_id = k.qonto_client_id
                                                         and h.id is distinct from (array_agg(c.id))[1])) as held_elsewhere
      from public.companies c where k.vat_key is not null and private.vat_key(c.vat_number) = k.vat_key
  ) m on true
  left join lateral (
    select coalesce(jsonb_agg(x.j order by x.rank, x.name), '[]'::jsonb) as candidates
      from (select c.name, mt.rank,
                   jsonb_build_object('company_id', c.id, 'name', c.name, 'vat_number', c.vat_number, 'qonto_client_id', c.qonto_client_id, 'match', mt.match) as j
              from public.companies c
              cross join lateral (
                select case when k.vat_key is not null and private.vat_key(c.vat_number) = k.vat_key then 'vat'
                            when k.vat_key is not null and private.vat_close(private.vat_key(c.vat_number), k.vat_key) then 'vat_close'
                            when private.name_overlap(c.name, k.qonto_client_name) then 'name' end as match,
                       case when k.vat_key is not null and private.vat_key(c.vat_number) = k.vat_key then 1
                            when k.vat_key is not null and private.vat_close(private.vat_key(c.vat_number), k.vat_key) then 2 else 3 end as rank
              ) mt
             where mt.match is not null
             order by mt.rank, c.name
             limit 10) x
  ) cand on true;
comment on view public.invoices_to_link_v is 'Fatture da collegare: invoices with no company (not removed), why, and the companies with the same or a similar VAT or name; staff only';

create or replace function public.link_invoice_to_company(p_invoice uuid, p_company uuid)
returns table (invoice_id uuid, company_id uuid, pratica_id uuid)
language plpgsql security definer set search_path = '' as $$
declare
  v_qid text;
  v_has uuid;
  c_qid text;
  n int;
begin
  if not (select private.is_staff()) then
    raise exception 'Solo il team Gemina può collegare le fatture alle aziende.' using errcode = '42501';
  end if;
  -- lock the company first, then the invoice (the order the matching uses), and read the company's Qonto id after the lock: two staff requests for
  -- different Qonto clients and the same empty company are serialised, so the second sees the id the first wrote and is refused below
  select c.qonto_client_id into c_qid from public.companies c where c.id = p_company for update;
  if not found then
    raise exception 'Azienda non trovata.' using errcode = '22023';
  end if;
  select d.qonto_client_id, d.company_id into v_qid, v_has from public.qonto_documents d where d.id = p_invoice and d.removed_at is null for update;
  if not found then
    raise exception 'Fattura non trovata.' using errcode = '22023';
  end if;
  if v_has is not null then
    raise exception 'La fattura ha già un''azienda.' using errcode = '22023';
  end if;
  if v_qid is not null and c_qid is not null and c_qid <> v_qid then
    raise exception 'L''azienda è già collegata a un altro cliente Qonto: non lo sostituisco.' using errcode = '22023';
  end if;
  if v_qid is not null and c_qid is null then
    begin
      update public.companies set qonto_client_id = v_qid where id = p_company and qonto_client_id is null;
      get diagnostics n = row_count;
    exception when unique_violation then
      raise exception 'Questo cliente Qonto è già collegato a un''altra azienda.' using errcode = '22023';
    end;
    if n = 0 then   -- not expected under the lock; never link without the id written
      raise exception 'L''azienda è già collegata a un altro cliente Qonto: non lo sostituisco.' using errcode = '22023';
    end if;
  end if;
  -- this invoice and the other still unlinked ones of the same Qonto client; the pratica and the commission lines follow from the existing triggers
  return query
    with up as (
      update public.qonto_documents d set company_id = p_company
       where d.company_id is null and d.removed_at is null and (d.id = p_invoice or (v_qid is not null and d.qonto_client_id = v_qid))
      returning d.id, d.company_id, d.pratica_id)
    select up.id, up.company_id, up.pratica_id from up order by up.id;
end $$;
comment on function public.link_invoice_to_company(uuid, uuid) is 'Staff: picks the company of an unlinked invoice (and of the other unlinked invoices of the same Qonto client); fills an empty qonto_client_id, never replaces one';
