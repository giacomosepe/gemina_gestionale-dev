-- Segnalatore IVA rate in the partners mirror (migration partners_vat_rate, PRDDISC-25). One DO block, rolled back by the final RAISE.
do $$
declare
  org uuid := (select id from public.organizations limit 1);
  pa uuid; k int; report text := ''; failures int := 0; ok boolean;
begin
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t26-a', 'T26 A', 't26-a@example.test', org) returning id into pa;
  ok := (select vat_rate is null and vat_rate_synced_at is null from public.partners where id = pa);
  failures := failures + (not ok)::int;
  report := report || format(E'%s a new partner has no rate and was never synced (rate unknown, not "default")\n', case when ok then 'PASS' else 'FAIL' end);

  update public.partners set vat_rate = 0, vat_rate_synced_at = now() where id = pa;
  ok := (select vat_rate = 0 and vat_rate_synced_at is not null from public.partners where id = pa);
  update public.partners set vat_rate = 22.5, vat_rate_synced_at = now() where id = pa;
  ok := ok and (select vat_rate = 22.5 from public.partners where id = pa);
  update public.partners set vat_rate = null, vat_rate_synced_at = now() where id = pa;
  ok := ok and (select vat_rate is null and vat_rate_synced_at is not null from public.partners where id = pa);
  failures := failures + (not ok)::int;
  report := report || format(E'%s rate 0 (no IVA), a decimal rate and "synced, none set in Zite" (null with a sync time) are all stored\n', case when ok then 'PASS' else 'FAIL' end);

  k := 0;
  begin update public.partners set vat_rate = -1 where id = pa; exception when check_violation then k := k + 1; end;
  begin update public.partners set vat_rate = 100.01 where id = pa; exception when check_violation then k := k + 1; end;
  ok := k = 2;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a rate below 0 or above 100 is refused (%s of 2)\n', case when ok then 'PASS' else 'FAIL' end, k);

  raise exception E'TEST REPORT (026 partners vat rate): % failure(s)\n%', failures, report;
end $$;
