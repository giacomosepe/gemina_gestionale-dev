-- Qonto invoices and credit notes in Supabase (Linear PRDDISC-2, milestone M1).
--
-- Money rules decided by Giacomo on 2026-10-23 (PRDDISC-1): every amount is an integer number of cents, as Qonto returns it
-- (total_amount_cents, vat_amount_cents); net = total - VAT. No setup-fee exclusion and no DSO formula here: the database only
-- keeps issue_date and paid_at (null when Qonto has none, never replaced by the issue date). "Fully paid" and "Scaduta" are
-- derived in views, not stored.
-- Status mapping, as in Zite statoDaQonto: paid -> Incassata; canceled -> Annullata; unpaid, late, partial -> Emessa.
-- Draft invoices are not imported. status_qonto keeps the raw Qonto value.
-- Access: staff read; partners and clients nothing; writes only by the service role (the qonto-sync Edge Function, PRDDISC-4).
-- Additive only.

-- 1. Documents --------------------------------------------------------------------------------------------------------------------
create table public.qonto_documents (
  id               uuid not null default gen_random_uuid() primary key,
  qonto_id         text not null unique check (char_length(qonto_id) between 1 and 100),
  kind             text not null check (kind in ('invoice', 'credit_note')),
  number           text check (char_length(number) <= 100),
  status_qonto     text not null check (char_length(status_qonto) <= 50),
  status           text not null check (status in ('Emessa', 'Incassata', 'Annullata')),
  issue_date       date not null,
  due_date         date,
  paid_at          date,
  currency         text not null default 'EUR' check (char_length(currency) = 3),
  total_cents      bigint not null,
  vat_cents        bigint not null,
  net_cents        bigint generated always as (total_cents - vat_cents) stored,
  company_id       uuid references public.companies(id) on delete set null,
  qonto_client_id  text check (char_length(qonto_client_id) <= 100),
  zite_pratica_id  text check (char_length(zite_pratica_id) <= 100),
  description      text,
  raw              jsonb not null,
  synced_at        timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index qonto_documents_company_id_idx on public.qonto_documents (company_id) where company_id is not null;
create index qonto_documents_qonto_client_id_idx on public.qonto_documents (qonto_client_id) where qonto_client_id is not null;
create index qonto_documents_zite_pratica_id_idx on public.qonto_documents (zite_pratica_id) where zite_pratica_id is not null;
create index qonto_documents_issue_date_idx on public.qonto_documents (issue_date desc);
create index qonto_documents_paid_at_idx on public.qonto_documents (paid_at) where paid_at is not null;

comment on table public.qonto_documents is 'One row per Qonto invoice or credit note (drafts are not imported); written only by the qonto-sync function';
comment on column public.qonto_documents.qonto_id is 'Qonto id of the invoice or credit note; the key of the sync (upsert)';
comment on column public.qonto_documents.status_qonto is 'Raw Qonto status (paid, unpaid, late, partial, canceled…)';
comment on column public.qonto_documents.status is 'Zite statoDaQonto: paid -> Incassata, canceled -> Annullata, unpaid/late/partial -> Emessa. Scaduta is never stored: views derive it';
comment on column public.qonto_documents.paid_at is 'Payment date from Qonto; null when Qonto has none (never replaced by issue_date)';
comment on column public.qonto_documents.total_cents is 'Qonto total_amount_cents, integer cents, VAT included; credit notes as Qonto gives them (views subtract)';
comment on column public.qonto_documents.vat_cents is 'Qonto vat_amount_cents, integer cents';
comment on column public.qonto_documents.net_cents is 'total_cents - vat_cents (imponibile)';
comment on column public.qonto_documents.company_id is 'Matched azienda (PRDDISC-3 backfill); null until matched';
comment on column public.qonto_documents.zite_pratica_id is 'Zite pratica the document is linked to (filled in M2)';
comment on column public.qonto_documents.raw is 'Full Qonto payload';

create trigger qonto_documents_updated_at before update on public.qonto_documents
  for each row execute function extensions.moddatetime(updated_at);

-- 2. Sync runs --------------------------------------------------------------------------------------------------------------------
create table public.qonto_sync_runs (
  id             uuid not null default gen_random_uuid() primary key,
  started_at     timestamptz not null default now(),
  finished_at    timestamptz,
  fetched_count  integer not null default 0 check (fetched_count >= 0),
  inserted_count integer not null default 0 check (inserted_count >= 0),
  updated_count  integer not null default 0 check (updated_count >= 0),
  error          text
);
create index qonto_sync_runs_started_at_idx on public.qonto_sync_runs (started_at desc);
comment on table public.qonto_sync_runs is 'One row per run of the Qonto sync: counts and, if it failed, the error text';

-- 3. Access -----------------------------------------------------------------------------------------------------------------------
alter table public.qonto_documents enable row level security;
alter table public.qonto_sync_runs enable row level security;

create policy "qonto_documents: staff read" on public.qonto_documents
  for select to authenticated using ((select private.is_staff()));
create policy "qonto_sync_runs: staff read" on public.qonto_sync_runs
  for select to authenticated using ((select private.is_staff()));

revoke all on public.qonto_documents, public.qonto_sync_runs from public, anon, authenticated;
grant select on public.qonto_documents, public.qonto_sync_runs to authenticated;
grant all on public.qonto_documents, public.qonto_sync_runs to service_role;
