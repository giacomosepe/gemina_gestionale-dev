-- Match Qonto invoices to companies by VAT number, and the list of invoices still to link (Linear PRDDISC-34, milestone M5).
-- A client created by hand in Qonto has no companies.qonto_client_id, so its invoices were stored with company_id null (real case 30 Oct 2026: GA005,
-- G.T.B. DI TOMOLA...). Qonto sends the VAT number as "IT01122290032"; our companies hold the 11 plain digits. Additive: functions, two triggers, a view.
-- No policy changes, no deletion. The matching itself is in the database (see 3); the qonto-sync Edge Function changes by one line only (it reads back the
-- unmatched count the database stores, so its answer matches the run row).
--
--  1. private.vat_key(text): THE normalisation. Remove spaces, dots and dashes; upper case; remove a leading IT only when exactly 11 digits follow (nothing
--     else after them). Other country prefixes stay (FR12345678901 is compared with its prefix). Empty -> null.
--     A trigger on companies stores the key form (so IT01122290032, 01122290032 and "01122290032 " are saved as 01122290032); the matching compares
--     vat_key() on both sides, so the same text gives the same key everywhere. Existing values are normalised below only where they differ (none do today).
--  2. private.link_invoices_to_companies_by_vat(): for every stored invoice with company_id null (not removed), key = vat_key(Qonto client vat_number, else
--     tax_identification_number). EXACTLY ONE company with that key: set the invoice's company_id and, only if the company has no qonto_client_id, set it to the
--     Qonto client id (never overwrite a different one: then nothing is linked and the invoice is listed). No VAT, no company, several companies: change nothing.
--     Writes: qonto_documents.company_id (the existing triggers then link the pratica and rebuild the commission lines) and companies.qonto_client_id.
--     Neither of those triggers writes back to companies or to company_id, and the companies trigger below fires only on vat_number, so there is no cycle.
--     Invoiced or received commission lines are never touched here (the rebuild leaves them alone, as before); the function does not touch commissions at all.
--  3. Where it runs: a BEFORE UPDATE trigger on qonto_sync_runs, when a run is marked finished without error. The Edge Function's own final update of the run
--     row (which it already does) therefore links what it could not, and the same statement gets unmatched_count recomputed after the linking, so the run row says 0
--     when nothing is left (the Edge Function reads that stored count back, RETURNING, for its own answer). The trigger fires once per run (finished_at null -> not null) and writes only to documents and companies, so it never re-enters.
--     A failure inside is logged in commission_rebuild_errors (message "vat-match: ...") and never breaks the run.
--  4. View invoices_to_link_v ("Fatture da collegare", staff only, security_invoker) and function link_invoice_to_company(invoice, company), the same pattern as
--     link_invoice_to_pratica: staff only (checked inside), security definer, fixed search_path, signed-in users only, Italian messages. It links the invoice and
--     the other still unlinked invoices of the same Qonto client, and fills companies.qonto_client_id when empty (never replaces a different one).

-- 1. Normalisation -----------------------------------------------------------------------------------------------------------------------
create function private.vat_key(p text) returns text
language sql immutable set search_path = '' as $$
  select case when k = '' then null when k ~ '^IT[0-9]{11}$' then substr(k, 3) else k end
    from (select upper(regexp_replace(translate(coalesce(p, ''), chr(160), ' '), '[[:space:].-]', '', 'g')) as k) s;
$$;
comment on function private.vat_key(text) is 'VAT number key: no spaces, dots or dashes, upper case, leading IT removed only when exactly 11 digits follow; other prefixes kept; empty = null';

-- "similar" helpers for the list of candidates (not used by the matching itself)
create function private.vat_close(a text, b text) returns boolean
language sql immutable set search_path = '' as $$
  select a is not null and b is not null and a <> b and (
           regexp_replace(a, '^[A-Z]{2}(?=[0-9])', '') = regexp_replace(b, '^[A-Z]{2}(?=[0-9])', '')
        or (length(a) = length(b) and length(a) >= 8
            and (select count(*) from generate_series(1, length(a)) i where substr(a, i, 1) <> substr(b, i, 1)) <= 1));
$$;
comment on function private.vat_close(text, text) is 'Two different VAT keys that differ only by the country prefix or by one character';

create function private.name_tokens(p text) returns text[]
language sql immutable set search_path = '' as $$
  select coalesce(array_agg(distinct w), '{}')
    from regexp_split_to_table(lower(regexp_replace(coalesce(p, ''), '[^[:alnum:]]+', ' ', 'g')), ' ') w
   where length(w) >= 4 and w <> all (array['societa', 'group', 'italia', 'studio', 'servizi', 'service', 'services', 'consulting', 'srls', 'coop']);
$$;
create function private.name_overlap(a text, b text) returns boolean
language sql immutable set search_path = '' as $$ select private.name_tokens(a) && private.name_tokens(b) $$;
comment on function private.name_overlap(text, text) is 'Two names share a significant word (4+ letters, legal forms and filler words left out)';

grant execute on function private.vat_key(text), private.vat_close(text, text), private.name_tokens(text), private.name_overlap(text, text) to authenticated, service_role;

-- companies: save the key form
create function private.companies_vat_key() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.vat_number := private.vat_key(new.vat_number);
  return new;
end $$;
create trigger companies_vat_key before insert or update of vat_number on public.companies
  for each row execute function private.companies_vat_key();
revoke execute on function private.companies_vat_key() from public, anon, authenticated;
comment on column public.companies.vat_number is 'Partita IVA in its key form (private.vat_key): no spaces, dots or dashes, upper case, no leading IT for an Italian number; a foreign prefix is kept';

update public.companies set vat_number = private.vat_key(vat_number) where vat_number is distinct from private.vat_key(vat_number);

-- 2. The matching ------------------------------------------------------------------------------------------------------------------------
create function private.link_invoices_to_companies_by_vat() returns jsonb
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

-- 3. At the end of a sync run -------------------------------------------------------------------------------------------------------------
create function private.qonto_run_finished() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  begin
    perform private.link_invoices_to_companies_by_vat();
  exception when others then
    insert into public.commission_rebuild_errors (invoice_id, sqlstate, message) values (null, sqlstate, 'vat-match: ' || left(sqlerrm, 480));
  end;
  -- what is still without a company after the linking (the Edge Function counted before it)
  new.unmatched_count := (select count(*) from public.qonto_documents where company_id is null and removed_at is null);
  return new;
end $$;
create trigger qonto_sync_runs_link_companies before update on public.qonto_sync_runs
  for each row when (old.finished_at is null and new.finished_at is not null and new.error is null)
  execute function private.qonto_run_finished();
revoke execute on function private.qonto_run_finished() from public, anon, authenticated;

-- 4. The list and the staff action -------------------------------------------------------------------------------------------------------
create view public.invoices_to_link_v with (security_invoker = true) as
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

create function public.link_invoice_to_company(p_invoice uuid, p_company uuid)
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

revoke all on public.invoices_to_link_v from public, anon, authenticated;
grant select on public.invoices_to_link_v to authenticated, service_role;
revoke all on function public.link_invoice_to_company(uuid, uuid) from public, anon;
grant execute on function public.link_invoice_to_company(uuid, uuid) to authenticated;
