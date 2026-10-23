# Qonto reconciliation: Zite Fatture vs Supabase qonto_documents

PRDDISC-7 (milestone M1). Read-only on both sides.

- **Run at:** 2026-10-23 13:17 UTC (15:17 Rome), against production `gsnmtfugfhhrutmlvhzt` and the Zite workspace "Gemina Revenue System".
- **Date range covered:** issue dates 2026-09-01 to 2026-10-06 (all documents in both systems).
- **Repeatable with:** `supabase/scripts/reconcile_qonto.sql` (the header says how to refresh the Zite rows).
- **Note:** the Zite table is called `Fatture`, not `Documenti`. Zite has no VAT field, so VAT = Totale - Imponibile.

## Verdict

**Zero unexplained differences.** Count, status, dates, net, VAT, total, monthly revenue, quarterly VAT, overdue count and DSO all match.
The only difference is one labelled cause (below), and it is a gap in Zite, not in Supabase.

## 1. Presence (by Qonto id)

| | Count |
|---|---|
| Zite Fatture | 4 (all `Origine = Qonto`) |
| Supabase qonto_documents | 4 |
| In both | 4 |
| Only in Zite | 0 |
| Only in Supabase | 0 |
| Manual Zite invoices (no Qonto id) | **0** |

No manual invoices exist today, so for now there is no case for a manual-invoice path in M1.

## 2. Per document (GA001 to GA004)

Compared: status, issue date, due date, payment date, net, VAT, total, client. All equal except the client of two documents:

| Doc | Field | Zite | Supabase | Cause |
|---|---|---|---|---|
| GA002 | azienda (client) | none | Mac Impianti Srl | unmatched client (Zite side) |
| GA003 | azienda (client) | none | Stein Warz Srl | unmatched client (Zite side) |

Explanation: in Zite, GA002 and GA003 have an empty `Azienda` link (they are linked to a pratica only); GA001 and GA004 are linked to their azienda.
Supabase resolves the company from the Qonto client id (`companies.qonto_client_id`, filled by PRDDISC-3), so all four are attached. The two Qonto clients are
the ones Zite itself holds as `Qonto ID` on those aziende, so the Supabase answer is the consistent one. Suggested fix on the Zite side (not done: read-only):
set `Azienda` on GA002 and GA003. No change to the sync or the views is needed.

Also noted (not differences): Zite links GA002, GA003 and GA004 to a pratica and GA001 to none; Supabase `zite_pratica_id` is still empty on purpose (milestone M2).

## 3. Aggregates

| Check | Zite | Supabase | Equal |
|---|---|---|---|
| Revenue (net) September 2026 | 6,200.00 | 6,200.00 | yes |
| Revenue (net) October 2026 | 2,600.00 | 2,600.00 | yes |
| VAT 2026-Q3 | 1,364.00 | 1,364.00 | yes |
| VAT 2026-Q4 | 572.00 | 572.00 | yes |
| Overdue invoices (today) | 0 | 0 | yes |
| DSO, payments of October 2026 (3 invoices) | 21.7 days | 21.7 days | yes |

Rules used on both sides are Zite's: Annullata left out, credit notes negative, revenue and VAT by issue date, overdue = Emessa with due date before today in Rome,
DSO = average days from issue to payment of paid invoices (by month of payment). DSO is only compared here; the formula lives in the app.

## 4. What this run could not test (small sample)

Four invoices, all Emessa or Incassata, none overdue, no credit note, no cancelled, no partial payment, no draft. So these are **not yet verified** and should be
re-run when such documents exist:

- **Date fallback.** Zite sets the payment date of a paid invoice to the issue date when Qonto has none, and the due date to the issue date when Qonto has none.
  Supabase keeps `paid_at` and `due_date` null (PRDDISC-1). When this happens the report will show it as cause "date fallback". Both Zite behaviours then need a decision.
- **Credit notes.** Zite settles a credit note on its issue date (paid on that day); Supabase stores `paid_at` null.
- **Rounding.** Qonto gives integer cents, Zite stores euros rounded to 2 decimals; no case with a difference yet.
- **Removed documents** (`removed_at`) and **manual invoices**: none exist.

## 5. Sign-off (Giacomo, 2026-10-23)

1. GA002 and GA003 client differences: **accepted**. Zite lacks the link; Supabase picked the right client from the Qonto client id.
2. Payment date: **Supabase keeps `paid_at` null** when Qonto has none (a fallback to the issue date would make a late payer look fast in DSO). The app shows
   "paid, date missing". Such cases will appear as differences against Zite, which fills the date in. They are listed in `invoice_payments_v` and `invoice_review_v`.
3. Due date: an invoice with no due date could never become overdue, so it goes to the **review list** (`invoice_review_v`, reason `due_date_missing`).
4. Credit notes: **`paid_at` stays null**; a credit note is not paid and does not count in DSO. Zite's settlement on the issue date is the quirk, not the rule.
5. Re-run `reconcile_qonto.sql` once a credit note and an overdue invoice exist. Until then **Zite stays the source for any screen the team relies on**.
