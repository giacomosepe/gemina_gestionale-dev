-- Staff link of an invoice to a pratica (Linear PRDDISC-23, milestone M4). Zite's "Collega a una pratica" dialog (collegaFatturaPratica) as three functions
-- staff call from the Gestionale. A link made here is 'manual': the Qonto sync's automatic rule only fills documents with no link source, so it never
-- overwrites it. Linking an invoice fires the commission rebuild (PRDDISC-20), so the lines appear; unlinking drops the unpaid, un-invoiced lines and keeps the others.
-- Additive.
--
-- Differences from Zite, on purpose:
--  * Zite lets a pratica of ANOTHER azienda be chosen and rewrites the invoice's azienda; the Qonto sync would put it back on its next run (it rewrites
--    company_id from the Qonto client). Here that link is refused with a clear message, and the options list shows only pratiche of the invoice's azienda
--    first and flags the others, so the screen can hide them.
--  * Who: staff only.

create function public.invoice_pratica_options(p_invoice uuid)
returns table (pratica_id uuid, code text, status text, is_open boolean, company_id uuid, company_name text, same_company boolean, linked boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_company uuid;
  v_pratica uuid;
begin
  if not (select private.is_staff()) then
    raise exception 'Solo il team Gemina può collegare le fatture alle pratiche.' using errcode = '42501';
  end if;
  select d.company_id, d.pratica_id into v_company, v_pratica from public.qonto_documents d where d.id = p_invoice and d.removed_at is null;
  if not found then
    raise exception 'Fattura non trovata.' using errcode = '22023';
  end if;
  return query
    select p.id, p.code, p.status, p.is_open, p.company_id, c.name, (p.company_id = v_company), (p.id = v_pratica)
      from public.pratiche p left join public.companies c on c.id = p.company_id
     where p.removed_at is null
     order by (p.company_id = v_company) desc nulls last, p.is_open desc, p.code, p.id;
end $$;

create function public.link_invoice_to_pratica(p_invoice uuid, p_pratica uuid)
returns table (invoice_id uuid, pratica_id uuid, pratica_link_source text)
language plpgsql security definer set search_path = '' as $$
declare
  v_inv_company uuid;
  v_pra_company uuid;
begin
  if not (select private.is_staff()) then
    raise exception 'Solo il team Gemina può collegare le fatture alle pratiche.' using errcode = '42501';
  end if;
  select d.company_id into v_inv_company from public.qonto_documents d where d.id = p_invoice and d.removed_at is null for update;
  if not found then
    raise exception 'Fattura non trovata.' using errcode = '22023';
  end if;
  select p.company_id into v_pra_company from public.pratiche p where p.id = p_pratica and p.removed_at is null;
  if not found then
    raise exception 'Pratica non trovata.' using errcode = '22023';
  end if;
  if v_inv_company is null then
    raise exception 'La fattura non ha ancora un''azienda: collega prima il cliente Qonto all''azienda.' using errcode = '22023';
  end if;
  if v_pra_company is distinct from v_inv_company then
    raise exception 'La pratica è di un''altra azienda: la fattura si collega solo a una pratica della sua azienda.' using errcode = '22023';
  end if;
  perform private.set_invoice_pratica(p_invoice, p_pratica);
  return query select d.id, d.pratica_id, d.pratica_link_source from public.qonto_documents d where d.id = p_invoice;
end $$;

create function public.unlink_invoice_pratica(p_invoice uuid)
returns table (invoice_id uuid, pratica_id uuid, pratica_link_source text)
language plpgsql security definer set search_path = '' as $$
begin
  if not (select private.is_staff()) then
    raise exception 'Solo il team Gemina può scollegare le fatture dalle pratiche.' using errcode = '42501';
  end if;
  perform 1 from public.qonto_documents d where d.id = p_invoice and d.removed_at is null for update;
  if not found then
    raise exception 'Fattura non trovata.' using errcode = '22023';
  end if;
  perform private.set_invoice_pratica(p_invoice, null);
  return query select d.id, d.pratica_id, d.pratica_link_source from public.qonto_documents d where d.id = p_invoice;
end $$;

revoke all on function public.invoice_pratica_options(uuid), public.link_invoice_to_pratica(uuid, uuid), public.unlink_invoice_pratica(uuid) from public, anon;
grant execute on function public.invoice_pratica_options(uuid), public.link_invoice_to_pratica(uuid, uuid), public.unlink_invoice_pratica(uuid) to authenticated;

comment on function public.invoice_pratica_options(uuid) is 'Staff: pratiche an invoice can be linked to, same azienda first';
comment on function public.link_invoice_to_pratica(uuid, uuid) is 'Staff: manual link of an invoice to a pratica of its azienda; commission lines follow';
comment on function public.unlink_invoice_pratica(uuid) is 'Staff: manual unlink; unpaid un-invoiced commission lines go, the others stay';

-- Commission lines for the segnalatore screens (PRDDISC-24): the stage view plus the Zite ids and the pratica code the screens key on.
create view public.commission_lines_v with (security_invoker = true) as
select s.*,
       pt.zite_segnalatore_id,
       co.zite_azienda_id,
       co.name as company_name,
       pr.code as pratica_code,
       d.kind as invoice_kind,
       d.net_cents as invoice_net_cents
  from public.commission_stages_v s
  join public.partners pt on pt.id = s.partner_id
  join public.qonto_documents d on d.id = s.invoice_id
  left join public.companies co on co.id = s.company_id
  left join public.pratiche pr on pr.id = s.pratica_id;

comment on view public.commission_lines_v is 'Commission lines with stage, Zite ids of segnalatore and azienda, pratica code; for the Gestionale segnalatore screens';
revoke all on public.commission_lines_v from public, anon, authenticated;
grant select on public.commission_lines_v to authenticated;
