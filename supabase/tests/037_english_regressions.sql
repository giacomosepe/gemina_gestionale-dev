-- Regression checks for the English rename (PM-191): things the name guard (036) cannot see because they only fail when a function runs.
-- One DO block, everything rolled back by the final RAISE.

do $$
declare
  n int;
  report text := '';
  failures int := 0;
begin
  -- the composite type that the supplier invoice functions return has the English attribute
  if exists (select 1 from pg_attribute where attrelid = 'private.si_attr'::regclass and attname = 'bene_ids' and not attisdropped)
     or not exists (select 1 from pg_attribute where attrelid = 'private.si_attr'::regclass and attname = 'asset_ids' and not attisdropped) then
    failures := failures + 1; report := report || E'\nFAIL private.si_attr has not asset_ids';
  else report := report || E'\nok   private.si_attr.asset_ids'; end if;

  -- the functions run (an unknown attribute fails only at run time)
  begin
    select count(*) into n from private.si_attrs(gen_random_uuid());
    select count(*) into n from private.si_filtered(gen_random_uuid(), '{"asset": ["x"]}'::jsonb);
    perform private.si_facets(gen_random_uuid(), '{}'::jsonb);
    perform public.supplier_invoices_summary(gen_random_uuid(), '{}'::jsonb);
    perform public.supplier_invoices_page(gen_random_uuid(), 0, 10, 5, '{}'::jsonb);
    report := report || E'\nok   supplier invoice functions run';
  exception when others then
    failures := failures + 1; report := report || E'\nFAIL supplier invoice functions: ' || sqlerrm;
  end;

  -- the signers check accepts the English values only
  begin
    perform 1 from pg_constraint where conname = 'signature_attachments_signers_check' and pg_get_constraintdef(oid) like '%client%' and pg_get_constraintdef(oid) not like '%cliente%';
    if not found then raise exception 'signers check has not the English values'; end if;
    if exists (select 1 from public.signature_attachments where 'cliente' = any (signers)) then raise exception 'rows with cliente left'; end if;
    report := report || E'\nok   signers are English';
  exception when others then
    failures := failures + 1; report := report || E'\nFAIL ' || sqlerrm;
  end;

  raise exception 'TEST REPORT 037 english regressions: % failure(s)%', failures, report;
end $$;
