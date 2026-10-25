-- Segnalatore IVA rate in the partners mirror (Linear PRDDISC-25, milestone M4). The cash-flow page needs the rate of each segnalatore (Zite Segnalatori."aliquotaIva")
-- to split a commission into amount and IVA. Zite sends it with every segnalatore sync (portal-bridge v14, action sync_partner).
--  * vat_rate: the rate in percent as Zite has it; null = Zite has none (the cash flow then uses its default rate, as it always did).
--  * vat_rate_synced_at: when Zite last sent the rate. null = never sent, so the rate is NOT known (null in vat_rate would otherwise look like "use the default"):
--    the Gestionale refuses to compute a commission's IVA for such a segnalatore instead of guessing.
-- A sync_partner call without a "vat_rate" key (an older caller) leaves both columns alone. Additive: two nullable columns.

alter table public.partners
  add column vat_rate numeric check (vat_rate >= 0 and vat_rate <= 100),
  add column vat_rate_synced_at timestamptz;
comment on column public.partners.vat_rate is 'Zite Aliquota IVA of the segnalatore (percent); null = none set in Zite (default rate applies). Only meaningful when vat_rate_synced_at is set';
comment on column public.partners.vat_rate_synced_at is 'When Zite last sent vat_rate; null = the rate has never been sent';
