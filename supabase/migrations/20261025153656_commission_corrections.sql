-- Correct a commission marking (Linear PRDDISC-31, milestone M4). Staff put right a line marked invoiced or paid by mistake, one step at a time,
-- and every correction is recorded. Additive; the files of PRDDISC-21 (migration 20261023223240) are not touched.
--
--  * public.correct_commission_invoice(ids, invoice_number, on_date): new number (required) and date of lines in stage fatturate. Not for received lines.
--  * public.unmark_commissions_paid(ids): received -> back to invoiced; clears paid_on.
--  * public.unmark_commissions_invoiced(ids): invoiced -> back to matured; clears the segnalatore's invoice number and date. Refused on a received line (undo "paid" first).
--  * public.commission_corrections: one row per line per call (what was done, old and new values, who, when). Staff read only; written by the three functions.
-- Same style as the marking functions: staff only (checked inside), security definer, fixed search path, execute for signed-in users, all the lines of a call
-- succeed or none does (rows locked first), the answer is the lines as commission_stages_v shows them, messages in Italian. The stage is read from the view
-- (the rule stays in one place). A line is never deleted and its amount never changes here: only the invoice number, the date and paid_on.

create table public.commission_corrections (
  id                  uuid primary key default gen_random_uuid(),
  -- no foreign key: the history must outlive a line that the rebuild later removes (an unmarked, unpaid line can go with its invoice)
  commission_id       uuid not null,
  action              text not null check (action in ('correct_invoice', 'unmark_paid', 'unmark_invoiced')),
  old_stage           text not null,
  new_stage           text not null,
  old_invoice_number  text,
  new_invoice_number  text,
  old_invoiced_on     date,
  new_invoiced_on     date,
  old_paid_on         date,
  new_paid_on         date,
  done_by             uuid,
  done_at             timestamptz not null default now(),
  organization_id     uuid not null default private.default_organization_id() references public.organizations(id) on delete restrict
);
create index commission_corrections_commission_idx on public.commission_corrections (commission_id, done_at);
create index commission_corrections_organization_idx on public.commission_corrections (organization_id);
comment on table public.commission_corrections is 'Every correction of a commission marking (PRDDISC-31): one row per line per call; written only by the three correction functions';

alter table public.commission_corrections enable row level security;
create policy "commission_corrections: staff read" on public.commission_corrections for select to authenticated using ((select private.is_staff()));
revoke all on public.commission_corrections from public, anon, authenticated;
grant select on public.commission_corrections to authenticated;
grant all on public.commission_corrections to service_role;

-- The common part: checks who calls, locks the lines, checks they all exist and are in the stage the action needs. Returns the distinct ids.
create function private.commission_correction_lines(p_ids uuid[], p_stage text, p_wrong text, p_who text) returns uuid[]
language plpgsql set search_path = '' as $$
declare
  v_ids uuid[];
  v_found int;
  v_bad int;
begin
  if not (select private.is_staff()) then
    raise exception 'Solo il team Gemina può %.', p_who using errcode = '42501';
  end if;
  v_ids := array(select distinct unnest(p_ids));
  if cardinality(v_ids) = 0 then
    raise exception 'Seleziona almeno una provvigione.' using errcode = '22023';
  end if;
  perform 1 from public.commissions c where c.id = any(v_ids) order by c.id for update;
  select count(*), count(*) filter (where s.stage <> p_stage) into v_found, v_bad
    from public.commission_stages_v s where s.id = any(v_ids);
  if v_found <> cardinality(v_ids) then
    raise exception 'Provvigione non trovata.' using errcode = '22023';
  end if;
  if v_bad > 0 then
    raise exception '% (%: in un altro stato).', p_wrong, v_bad using errcode = '22023';
  end if;
  return v_ids;
end $$;
revoke execute on function private.commission_correction_lines(uuid[], text, text, text) from public, anon, authenticated;

create function public.correct_commission_invoice(ids uuid[], invoice_number text, on_date date default null)
returns setof public.commission_stages_v
language plpgsql security definer set search_path = '' as $$
declare
  v_ids uuid[];
  v_number text := btrim(coalesce(invoice_number, ''));
begin
  if v_number = '' then
    if not (select private.is_staff()) then
      raise exception 'Solo il team Gemina può correggere le provvigioni.' using errcode = '42501';
    end if;
    raise exception 'Indica il numero della fattura del segnalatore.' using errcode = '22023';
  end if;
  if char_length(v_number) > 100 then
    raise exception 'Il numero della fattura è troppo lungo (100 caratteri al massimo).' using errcode = '22023';
  end if;
  v_ids := private.commission_correction_lines(correct_commission_invoice.ids, 'Provvigioni fatturate',
             'Si può correggere solo il numero di una provvigione fatturata', 'correggere le provvigioni');
  insert into public.commission_corrections (commission_id, action, old_stage, new_stage, old_invoice_number, new_invoice_number,
                                             old_invoiced_on, new_invoiced_on, old_paid_on, new_paid_on, done_by)
    select c.id, 'correct_invoice', s.stage, s.stage, c.partner_invoice_number, v_number, c.partner_invoiced_on, on_date, c.paid_on, c.paid_on, (select auth.uid())
      from public.commissions c join public.commission_stages_v s on s.id = c.id where c.id = any(v_ids);
  update public.commissions c set partner_invoice_number = v_number, partner_invoiced_on = on_date where c.id = any(v_ids);
  return query select s.* from public.commission_stages_v s where s.id = any(v_ids) order by s.created_at, s.id;
end $$;

create function public.unmark_commissions_paid(ids uuid[])
returns setof public.commission_stages_v
language plpgsql security definer set search_path = '' as $$
declare
  v_ids uuid[];
begin
  v_ids := private.commission_correction_lines(unmark_commissions_paid.ids, 'Provvigioni ricevute',
             'Solo le provvigioni ricevute si possono riportare a fatturate', 'annullare il pagamento delle provvigioni');
  -- the new stage is what the view will say after the change: the line goes back to invoiced if it has a number, else the view decides
  insert into public.commission_corrections (commission_id, action, old_stage, new_stage, old_invoice_number, new_invoice_number,
                                             old_invoiced_on, new_invoiced_on, old_paid_on, new_paid_on, done_by)
    select c.id, 'unmark_paid', s.stage,
           case when nullif(btrim(c.partner_invoice_number), '') is not null then 'Provvigioni fatturate'
                when s.invoice_status = 'Incassata' then 'Provvigioni maturate' else 'Provvigioni teoriche' end,
           c.partner_invoice_number, c.partner_invoice_number, c.partner_invoiced_on, c.partner_invoiced_on, c.paid_on, null, (select auth.uid())
      from public.commissions c join public.commission_stages_v s on s.id = c.id where c.id = any(v_ids);
  update public.commissions c set paid_on = null where c.id = any(v_ids);
  return query select s.* from public.commission_stages_v s where s.id = any(v_ids) order by s.created_at, s.id;
end $$;

create function public.unmark_commissions_invoiced(ids uuid[])
returns setof public.commission_stages_v
language plpgsql security definer set search_path = '' as $$
declare
  v_ids uuid[];
begin
  if (select private.is_staff()) and exists (select 1 from public.commission_stages_v s where s.id = any(unmark_commissions_invoiced.ids) and s.stage = 'Provvigioni ricevute') then
    raise exception 'Una provvigione ricevuta non si può riportare a maturata: prima annulla il pagamento.' using errcode = '22023';
  end if;
  v_ids := private.commission_correction_lines(unmark_commissions_invoiced.ids, 'Provvigioni fatturate',
             'Solo le provvigioni fatturate si possono riportare a maturate', 'annullare la fatturazione delle provvigioni');
  insert into public.commission_corrections (commission_id, action, old_stage, new_stage, old_invoice_number, new_invoice_number,
                                             old_invoiced_on, new_invoiced_on, old_paid_on, new_paid_on, done_by)
    select c.id, 'unmark_invoiced', s.stage,
           case when s.invoice_status = 'Incassata' then 'Provvigioni maturate' else 'Provvigioni teoriche' end,
           c.partner_invoice_number, null, c.partner_invoiced_on, null, c.paid_on, c.paid_on, (select auth.uid())
      from public.commissions c join public.commission_stages_v s on s.id = c.id where c.id = any(v_ids);
  update public.commissions c set partner_invoice_number = null, partner_invoiced_on = null where c.id = any(v_ids);
  return query select s.* from public.commission_stages_v s where s.id = any(v_ids) order by s.created_at, s.id;
end $$;

revoke execute on function public.correct_commission_invoice(uuid[], text, date) from public, anon;
revoke execute on function public.unmark_commissions_paid(uuid[]) from public, anon;
revoke execute on function public.unmark_commissions_invoiced(uuid[]) from public, anon;
grant execute on function public.correct_commission_invoice(uuid[], text, date) to authenticated;
grant execute on function public.unmark_commissions_paid(uuid[]) to authenticated;
grant execute on function public.unmark_commissions_invoiced(uuid[]) to authenticated;

comment on function public.correct_commission_invoice(uuid[], text, date) is 'Staff: new invoice number and date on invoiced lines; logged; all or none; returns the lines';
comment on function public.unmark_commissions_paid(uuid[]) is 'Staff: received -> invoiced (clears paid_on); logged; all or none; returns the lines';
comment on function public.unmark_commissions_invoiced(uuid[]) is 'Staff: invoiced -> matured (clears number and date); refused on a received line; logged; all or none; returns the lines';
