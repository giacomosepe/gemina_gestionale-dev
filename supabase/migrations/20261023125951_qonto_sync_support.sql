-- What the Edge Function qonto-sync needs (Linear PRDDISC-4, milestone M1). Additive; replaces one column comment.
--
-- 1. removed_at: a Qonto document that is no longer returned by Qonto is marked, never deleted.
-- 2. Credit notes are stored as negative amounts (PRDDISC-4: "Credit notes stored as negative amounts"; Zite does the same).
--    The comment of 20261023124424 said "views subtract": it is replaced, views just sum.
-- 3. The run log also counts documents with no matching azienda, skipped drafts and newly marked removals.
-- 4. An internal secret for the function lives in Vault (generated here, never written in a file), like message_emails_secret.
--    The nightly schedule (PRDDISC-5) will send it in the header x-sync-secret.

alter table public.qonto_documents add column removed_at timestamptz;
comment on column public.qonto_documents.removed_at is 'Set when Qonto no longer returns the document (kept, never deleted); cleared if it comes back';
create index qonto_documents_removed_at_idx on public.qonto_documents (removed_at) where removed_at is not null;

alter table public.qonto_documents
  add constraint qonto_documents_credit_note_negative check (kind <> 'credit_note' or total_cents <= 0);
comment on column public.qonto_documents.total_cents is
  'Qonto total_amount_cents, integer cents, VAT included; negative for credit notes (so sums of net_cents already net them off)';

alter table public.qonto_sync_runs
  add column unmatched_count integer not null default 0 check (unmatched_count >= 0),
  add column skipped_count   integer not null default 0 check (skipped_count >= 0),
  add column removed_count   integer not null default 0 check (removed_count >= 0);
comment on column public.qonto_sync_runs.unmatched_count is 'Documents of the run whose Qonto client matches no company (company_id null)';
comment on column public.qonto_sync_runs.skipped_count is 'Drafts, unknown statuses and unusable credit notes, not imported';
comment on column public.qonto_sync_runs.removed_count is 'Documents newly marked removed (no longer returned by Qonto)';

select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'qonto_sync_secret',
                           'Shared by the database (schedule) and the Edge Function qonto-sync')
 where not exists (select 1 from vault.secrets where name = 'qonto_sync_secret');
