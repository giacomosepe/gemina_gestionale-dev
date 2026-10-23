-- Backfill of the Zite Provvigioni into public.commissions (Linear PRDDISC-16, milestone M4). IDEMPOTENT: a line that already exists (same invoice and referral)
-- is left exactly as it is, so the script can be run again. One statement; the answer is one json row, `report`.
-- On 2026-10-23 the Zite table "Provvigioni" had 0 rows, so the first run inserts nothing; the script is here for the day it has rows (before the cutover, PRDDISC-28).
--   1. Run this in Zite (execute_sql on the workspace) and replace the rows of the CTE `zite` below with its result: one row per Provvigioni line with the
--      Provvigioni id, the Qonto ID of its invoice (Fatture."Qonto ID"), the Zite id of its Segnalazione, Percentuale, Base, Importo (euros), Pagata,
--      Data pagamento, Fattura segnalatore, Data fattura segnalatore (the invoice and the segnalazione are links: join through the link tables, as listFatture does).
--   2. Run the whole statement on the Supabase project (SQL editor or MCP).
-- Rules reproduced: percentage and base frozen from the Zite line (base = round(euro x 100) cents); the amount is recomputed in cents half up and compared with the
-- Zite importo (report.amount_differences must be empty); "pagata" without a date takes the invoice's payment date, else its issue date (report.paid_without_date counts them);
-- credit notes, cancelled and removed invoices cannot hold a line (the table refuses them): they are listed in report.skipped.
-- Lines whose invoice or referral is not in Supabase yet are skipped and listed (run the Qonto sync / resync_referrals, then run this again).

with zite (zite_id, qonto_id, referral_id, pct, base, importo, pagata, data_pagamento, fattura_segnalatore, data_fattura_segnalatore) as (
  select * from (values
    (null::text, null::text, null::uuid, null::numeric, null::numeric, null::numeric, null::boolean, null::date, null::text, null::date)
  ) v where false   -- replace with the Zite rows: ('<Provvigioni id>', '<Qonto ID>', '<Segnalazione id>'::uuid, 5, 1000.00, 50.00, false, null, null, null), ...
),
joined as (
  select z.*, d.id as invoice_id, d.kind, d.status as invoice_status, d.removed_at as invoice_removed, d.paid_at as invoice_paid_at, d.issue_date,
         r.id as ref_id, r.partner_id, r.removed_at as ref_removed
    from zite z
    left join public.qonto_documents d on d.qonto_id = z.qonto_id
    left join public.referrals r on r.id = z.referral_id
),
calc as (
  select j.*, round(j.base * 100)::bigint as base_cents, floor(round(j.base * 100) * j.pct / 100 + 0.5)::bigint as amount_cents
    from joined j
),
ok as (
  select * from calc
   where invoice_id is not null and ref_id is not null and partner_id is not null and kind = 'invoice' and invoice_status <> 'Annullata' and invoice_removed is null
),
ins as (
  insert into public.commissions (invoice_id, referral_id, partner_id, pct, base_cents, amount_cents, partner_invoice_number, partner_invoiced_on, paid_on)
  select invoice_id, ref_id, partner_id, pct, base_cents, amount_cents,
         nullif(btrim(fattura_segnalatore), ''), case when nullif(btrim(fattura_segnalatore), '') is not null then data_fattura_segnalatore end,
         case when pagata then coalesce(data_pagamento, invoice_paid_at, issue_date) end
    from ok
  on conflict (invoice_id, referral_id) do nothing
  returning id
)
select jsonb_build_object(
  'run_at', now(),
  'zite_lines', (select count(*) from zite),
  'inserted', (select count(*) from ins),
  'already_there', (select count(*) from ok) - (select count(*) from ins),
  'skipped', (select coalesce(jsonb_agg(jsonb_build_object('zite_id', zite_id, 'qonto_id', qonto_id, 'referral_id', referral_id,
                'why', case when invoice_id is null then 'invoice not in Supabase' when ref_id is null or partner_id is null then 'referral or its partner not in Supabase'
                            else 'credit note, cancelled or removed invoice' end)), '[]')
                from calc where not (invoice_id is not null and ref_id is not null and partner_id is not null and kind = 'invoice' and invoice_status <> 'Annullata' and invoice_removed is null)),
  'amount_differences', (select coalesce(jsonb_agg(jsonb_build_object('zite_id', zite_id, 'zite_cents', round(importo * 100), 'supabase_cents', amount_cents)), '[]')
                from ok where round(importo * 100) <> amount_cents),
  'paid_without_date', (select count(*) from ok where pagata and data_pagamento is null),
  'totals_cents', jsonb_build_object('zite', (select coalesce(sum(round(importo * 100)), 0) from zite),
                                     'supabase_lines_of_these', (select coalesce(sum(c.amount_cents), 0) from public.commissions c join ok on ok.invoice_id = c.invoice_id and ok.referral_id = c.referral_id))
) as report;
