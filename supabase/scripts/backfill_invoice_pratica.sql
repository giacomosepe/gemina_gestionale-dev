-- One-off, idempotent backfill of qonto_documents.pratica_id from the Zite Fatture -> Pratica links (PRDDISC-12).
-- Source: workspace "Gemina Revenue System", table Fatture, field "Pratica", read on 2026-10-23 (4 invoices). To repeat it, replace the rows of `zite`
-- with (Qonto ID, Zite id of the linked pratica or null) from Zite. Links from Zite are stored with source 'zite' and are never overwritten by the rule.
-- Only documents with no link yet are touched, so running it again changes nothing. Needs migration 20261023145446_invoice_pratica_link.sql and the mirror
-- (public.pratiche, resync_pratiche) filled. One json row comes back: the report.

begin;

create temporary table zite_links (qonto_id text primary key, pratica_id uuid) on commit drop;
insert into zite_links (qonto_id, pratica_id) values
  ('01a05d1d-5d67-7858-8b68-47effc941db6', null),
  ('01a080f6-61f2-7c1b-a5ea-754e2ce64eba', 'af5f2cde-e5fd-437b-8662-e3b751f08b08'),
  ('01a0ce5e-908d-7d23-badb-192ac1b870a1', '0ae0abd8-5643-4a28-9498-0670a1105086'),
  ('01a0f715-9da9-7a85-bd85-b7d0729501a0', '7e76e2f9-e5ff-4db2-b826-b04f97027394');

update public.qonto_documents d
   set pratica_id = z.pratica_id, pratica_link_source = 'zite', zite_pratica_id = z.pratica_id::text
  from zite_links z
 where d.qonto_id = z.qonto_id and z.pratica_id is not null
   and d.pratica_id is null and d.pratica_link_source is null
   and exists (select 1 from public.pratiche p where p.id = z.pratica_id);

-- Then the rule for everything else that is still unlinked.
select private.link_invoices_to_pratiche();

select jsonb_build_object(
  'zite_links', (select count(*) from zite_links where pratica_id is not null),
  'supabase_linked', (select count(*) from public.qonto_documents where pratica_id is not null),
  'differences', (select coalesce(jsonb_agg(jsonb_build_object('qonto_id', z.qonto_id, 'zite', z.pratica_id, 'supabase', d.pratica_id, 'source', d.pratica_link_source)), '[]')
                    from zite_links z join public.qonto_documents d using (qonto_id)
                   where z.pratica_id is distinct from d.pratica_id),
  'zite_pratica_missing_in_mirror', (select coalesce(jsonb_agg(z.qonto_id), '[]') from zite_links z
                                      where z.pratica_id is not null and not exists (select 1 from public.pratiche p where p.id = z.pratica_id)),
  'unlinked_for_review', (select coalesce(jsonb_agg(jsonb_build_object('number', number, 'reason', reason_code)), '[]') from public.review_invoices_v)
) as report;

commit;
