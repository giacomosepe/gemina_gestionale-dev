-- Companies: VAT number and Qonto client id (Linear PRDDISC-3, milestone M1).
--
-- Zite links an invoice to a client through the azienda's "Qonto ID"; the sync (PRDDISC-4) needs the same link in Supabase to
-- fill qonto_documents.company_id. vat_number = partita IVA as plain text (leading zeros matter, foreign numbers allowed, so no
-- format check). Both columns are filled by supabase/scripts/backfill_companies_qonto.sql. Additive only: no existing column
-- and no RLS changes (companies keeps its policies: members read, staff manage).

alter table public.companies
  add column vat_number      text check (char_length(vat_number) between 1 and 30),
  add column qonto_client_id text check (char_length(qonto_client_id) between 1 and 100);

create unique index companies_qonto_client_id_key on public.companies (qonto_client_id) where qonto_client_id is not null;
create index companies_vat_number_idx on public.companies (vat_number) where vat_number is not null;

comment on column public.companies.vat_number is 'Partita IVA, text as written in Zite (trimmed)';
comment on column public.companies.qonto_client_id is 'Qonto client id (Zite Aziende "Qonto ID"); unique where set; the sync uses it to attach invoices';
