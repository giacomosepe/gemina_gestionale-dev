-- Mark commissions invoiced and paid (Linear PRDDISC-21, milestone M4). The two Gestionale actions of Zite (segnaProvvigioniFatturate / segnaProvvigioniPagate) as
-- functions staff call: the segnalatore's own invoice arrived (matured -> invoiced) and Gemina paid the segnalatore (invoiced -> received). Additive.
--
-- Rules, from the Zite endpoints and their dialogs:
--  * fatturate: the number of the segnalatore's invoice is required (Zite: "Indica il numero della fattura del segnalatore."); the date may be empty.
--  * pagate: the payment date (Zite's dialog always sends one). Here it defaults to today (Rome) when empty, because "received" IS "paid_on set" in the stage view.
--  * Who: staff only (Zite: anybody in Ruoli).
--  * Stage checks: the Zite endpoints do not check the stage on the server (the screens only offer "Maturate" lines for the first and "Fatturate" lines for the
--    second); here the database checks it, as the issue asks: only a matured line can be marked invoiced, only an invoiced line can be marked paid. The stage is
--    the one of public.commission_stages_v (PRDDISC-16), read from the view so the rule stays in one place.
--  * All the lines of a call succeed or none does (one transaction; the lines are locked first). The answer is the lines as the stage view shows them.
-- Not in scope (Zite can do it, these functions cannot): un-marking a line paid "to fix a mistake" (segnaProvvigioniPagate with pagata=false).

create function public.mark_commissions_invoiced(ids uuid[], invoice_number text, on_date date default null)
returns setof public.commission_stages_v
language plpgsql security definer set search_path = '' as $$
declare
  v_ids uuid[];
  v_number text := btrim(coalesce(invoice_number, ''));
  v_found int;
  v_bad int;
begin
  if not (select private.is_staff()) then
    raise exception 'Solo il team Gemina può segnare le provvigioni come fatturate.' using errcode = '42501';
  end if;
  v_ids := array(select distinct unnest(ids));
  if cardinality(v_ids) = 0 then
    raise exception 'Seleziona almeno una provvigione.' using errcode = '22023';
  end if;
  if v_number = '' then
    raise exception 'Indica il numero della fattura del segnalatore.' using errcode = '22023';
  end if;
  if char_length(v_number) > 100 then
    raise exception 'Il numero della fattura è troppo lungo (100 caratteri al massimo).' using errcode = '22023';
  end if;
  perform 1 from public.commissions c where c.id = any(v_ids) order by c.id for update;
  select count(*), count(*) filter (where s.stage <> 'Provvigioni maturate') into v_found, v_bad
    from public.commission_stages_v s where s.id = any(v_ids);
  if v_found <> cardinality(v_ids) then
    raise exception 'Provvigione non trovata.' using errcode = '22023';
  end if;
  if v_bad > 0 then
    raise exception 'Solo le provvigioni maturate si possono segnare come fatturate (%: non maturate).', v_bad using errcode = '22023';
  end if;
  update public.commissions c set partner_invoice_number = v_number, partner_invoiced_on = on_date where c.id = any(v_ids);
  return query select s.* from public.commission_stages_v s where s.id = any(v_ids) order by s.created_at, s.id;
end $$;

create function public.mark_commissions_paid(ids uuid[], on_date date default null)
returns setof public.commission_stages_v
language plpgsql security definer set search_path = '' as $$
declare
  v_ids uuid[];
  v_day date := coalesce(on_date, (now() at time zone 'Europe/Rome')::date);
  v_found int;
  v_bad int;
begin
  if not (select private.is_staff()) then
    raise exception 'Solo il team Gemina può segnare le provvigioni come ricevute.' using errcode = '42501';
  end if;
  v_ids := array(select distinct unnest(ids));
  if cardinality(v_ids) = 0 then
    raise exception 'Seleziona almeno una provvigione.' using errcode = '22023';
  end if;
  perform 1 from public.commissions c where c.id = any(v_ids) order by c.id for update;
  select count(*), count(*) filter (where s.stage <> 'Provvigioni fatturate') into v_found, v_bad
    from public.commission_stages_v s where s.id = any(v_ids);
  if v_found <> cardinality(v_ids) then
    raise exception 'Provvigione non trovata.' using errcode = '22023';
  end if;
  if v_bad > 0 then
    raise exception 'Solo le provvigioni fatturate si possono segnare come ricevute (%: non fatturate).', v_bad using errcode = '22023';
  end if;
  update public.commissions c set paid_on = v_day where c.id = any(v_ids);
  return query select s.* from public.commission_stages_v s where s.id = any(v_ids) order by s.created_at, s.id;
end $$;

comment on function public.mark_commissions_invoiced(uuid[], text, date) is 'Staff: the segnalatore''s invoice arrived; matured lines only; all or none; returns the lines';
comment on function public.mark_commissions_paid(uuid[], date) is 'Staff: Gemina paid the segnalatore; invoiced lines only; all or none; returns the lines';

revoke execute on function public.mark_commissions_invoiced(uuid[], text, date) from public, anon;
revoke execute on function public.mark_commissions_paid(uuid[], date) from public, anon;
grant execute on function public.mark_commissions_invoiced(uuid[], text, date) to authenticated;
grant execute on function public.mark_commissions_paid(uuid[], date) to authenticated;
