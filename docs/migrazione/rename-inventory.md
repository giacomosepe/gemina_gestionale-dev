# Italian names in the database (read from production, 14 Nov 2026)

**Status, 14 Nov 2026: the rename below is applied on staging (migration `20261114160000_english_names.sql`), tests 001-035 follow the new names and guard test 036 keeps them English. Production only at the cutover.** What was deliberately left for later steps is at the end of this file.

The schema is already mostly English. What remains, and what it becomes (words from `glossary.md`). Linear: PM-191.

## Tables and views

| Today | Becomes |
| -- | -- |
| `pratiche` | `cases` |
| `scadenze` | `deadlines` |
| `beni` | `assets` |
| `bene_values` | `asset_values` |
| `bene_documents` | `asset_documents` |
| `pratica_payment_status_v` | `case_payment_status_v` |
| `supplier_invoice_by_bene` | `supplier_invoice_by_asset` |
| `supplier_invoice_pratica_summary` | `supplier_invoice_case_summary` |

## Columns

- `pratica_id`, `zite_pratica_id`, `pratica_code`, `pratica_title`, `pratica_link_source` → `case_id`, `case_code`, `case_title`, `case_link_source` (tables: `beni`, `commission_lines_v`, `commission_stages_v`, `qonto_documents`, `scadenze`, `signature_attachments`, `signature_attachments_v`, `supplier_invoices`, `supplier_invoice_*` views, `upload_portal_files`, `review_invoices_v`, `reminders`, `conversations`, `documents`, `invoice_*_v`).
- `bene_id`, `new_bene_id`, `old_bene_id`, `bene_name`, `on_beni_pct`, `on_beni_amount` → `asset_id`, `new_asset_id`, `old_asset_id`, `asset_name`, `on_assets_pct`, `on_assets_amount`.
- `scadenze.nome`, `numero`, `tipo`, `archiviata` → `name`, `number`, `type`, `archived`; `signature_attachments.scadenza_id` → `deadline_id`.
- `reminders.pratica_title` → `case_title`.

## Zite id columns (`zite_*`)

`zite_azienda_id`, `zite_segnalatore_id`, `zite_pratica_id`, `zite_trattativa_id`, `zite_attivita_id`, `zite_provvigione_id`, `zite_messaggio_id`, `zite_bene_id`, `trattativa_zite_id` exist on about 15 tables as the link to the Zite record.

Decision for the cutover: the final schema keeps one `legacy_id` text column per table that was imported (for traceability and for the reconciliation report), and the Zite-specific names go away. The import runner maps Zite ids to the new keys in one place.

## Functions and triggers

- `private.bene_documents_before_write`, `bene_values_before_write`, `beni_before_write`, `pratiche_before_write`, `pratiche_lock_company`, `scadenze_before_write`, `sync_pratiche`, `sync_pratica_beni`, `pratica_for_company`, `documents_link_pratica`, `import_pratica_invoices`, `link_invoices_to_pratiche`, `set_invoice_pratica`.
- `public.invoice_pratica_options`, `link_invoice_to_pratica`, `unlink_invoice_pratica`, `partner_pratica_invoiced`, `pratica_beni`, `set_pratica_beneficiary`.

Each becomes the same name with `case` or `asset` in place of `pratica` or `bene`.

## Not Italian, left alone

`partners` (referrers), `referrals`, `companies`, `commissions`, `documents`, `messages`, `reminders`, `qonto_*`, `vat_settlements`, `supplier_*` and the `archived`, `note` and `credit_note_included` columns are English words. Edge Function folders and TypeScript names are renamed with the domain they belong to.

## How the rename is applied

1. It is not additive, so it is applied on staging first (rule 3 of `CLAUDE.md`), never built on production.
2. One migration renames tables and columns. Policies, foreign keys, indexes and views follow by themselves; function bodies, trigger functions and Edge Functions that name the old words are rewritten in the same change.
3. Tests 001–035 are updated to the new names and run after it.
4. A guard test (036) fails when a table, column or function name contains a glossary word in Italian. Until the rename is applied it lists the names above as known exceptions, and the list is emptied by the rename.
5. The same names are used in the new tables of every later milestone from the start.

## Values (second part, applied on staging 14 Nov 2026, migrations 20261114190000 and 20261114190500)

Invoice statuses (`issued`, `paid`, `cancelled`, `overdue`), commission stages (`theoretical`, `invoiced`, `matured`, `received`), notification events (`messages`, `documents`, `reminders`), signature states (`to_prepare`, `ready`, `sent`, `partly_signed`, `signed`, `archived`), supplier invoice states and facet keys, signers (`client`, `gemina`), the JSON keys of the supplier invoice, case beneficiary and import functions, and the permission keys (`cases.set_beneficiary`, `deadlines.manage`, `assets.manage`, `invoices.link_case`). Guard test 036 also fails if an old value comes back in a function or view.

## Left for later (known exceptions of guard test 036)

- The `zite_*`, `record_zite_id` and `trattativa_zite_id` columns (and the indexes and constraints that carry `zite` in their name): they become one `legacy_id` column when the import runner is built (M1). The same step maps the Italian values that come from Zite (for example `cases.status`).
- Edge Function folder names (`beni`, `segnalatori`, `aziende-sync`, `allegati-firma`, `fatture-import`, `portale-fatture`), their action names, and the one-off scripts in `supabase/scripts`: renamed when the new app calls them.
- Texts the user reads (messages, labels, permission area names, the default asset name "Bene 1") stay Italian on purpose; so do the stop words of `private.name_tokens`.
- Local variable and alias names inside function bodies (for example `v_pratica`, `da_assegnare` as a column alias in `si_attrs`): invisible from outside, renamed when a function is next rewritten.
