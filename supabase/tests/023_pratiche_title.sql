-- Pratica title in the mirror (migration pratiche_title): stored, kept when absent, cleared when null/empty, the rest of the row still synced.
-- One DO block, rolled back by the final RAISE. (Number 023: 022 is the invoice link test of PRDDISC-23.)
do $$
declare
  p1 uuid := gen_random_uuid(); p2 uuid := gen_random_uuid();
  t text; k int; report text := ''; failures int := 0; ok boolean;
begin
  perform private.sync_pratiche(jsonb_build_array(
    jsonb_build_object('id', p1, 'code', 'T23-1', 'title', '  Credito 4.0 | 2027 ', 'zite_azienda_id', 't23-x', 'status', 'In lavorazione', 'is_open', true, 'total_fee_cents', 1000, 'removed', false),
    jsonb_build_object('id', p2, 'code', 'T23-2', 'zite_azienda_id', 't23-x', 'status', 'In lavorazione', 'is_open', true, 'total_fee_cents', 1000, 'removed', false)));
  ok := (select title from public.pratiche where id = p1) = 'Credito 4.0 | 2027' and (select title is null from public.pratiche where id = p2);
  failures := failures + (not ok)::int;
  report := report || format(E'%s title stored trimmed; a row with no title key has none\n', case when ok then 'PASS' else 'FAIL' end);

  perform private.sync_pratiche(jsonb_build_array(
    jsonb_build_object('id', p1, 'code', 'T23-1b', 'zite_azienda_id', 't23-x', 'status', 'Chiusa', 'is_open', false, 'total_fee_cents', 2000, 'removed', false)));
  ok := (select title = 'Credito 4.0 | 2027' and code = 'T23-1b' and status = 'Chiusa' and total_fee_cents = 2000 from public.pratiche where id = p1);
  failures := failures + (not ok)::int;
  report := report || format(E'%s a sync with no title key keeps the stored title and still updates the other fields\n', case when ok then 'PASS' else 'FAIL' end);

  perform private.sync_pratiche(jsonb_build_array(jsonb_build_object('id', p1, 'code', 'T23-1b', 'title', 'Nuovo titolo', 'zite_azienda_id', 't23-x', 'status', 'Chiusa', 'is_open', false, 'total_fee_cents', 2000, 'removed', false)));
  ok := (select title = 'Nuovo titolo' from public.pratiche where id = p1);
  perform private.sync_pratiche(jsonb_build_array(jsonb_build_object('id', p1, 'code', 'T23-1b', 'title', null, 'zite_azienda_id', 't23-x', 'status', 'Chiusa', 'is_open', false, 'total_fee_cents', 2000, 'removed', false)));
  ok := ok and (select title is null from public.pratiche where id = p1);
  perform private.sync_pratiche(jsonb_build_array(jsonb_build_object('id', p1, 'code', 'T23-1b', 'title', 'Ancora', 'zite_azienda_id', 't23-x', 'status', 'Chiusa', 'is_open', false, 'total_fee_cents', 2000, 'removed', false)));
  perform private.sync_pratiche(jsonb_build_array(jsonb_build_object('id', p1, 'code', 'T23-1b', 'title', '   ', 'zite_azienda_id', 't23-x', 'status', 'Chiusa', 'is_open', false, 'total_fee_cents', 2000, 'removed', false)));
  ok := ok and (select title is null from public.pratiche where id = p1);
  failures := failures + (not ok)::int;
  report := report || format(E'%s a new title replaces; null or blank clears\n', case when ok then 'PASS' else 'FAIL' end);

  k := 0;
  begin perform private.sync_pratiche(jsonb_build_array(jsonb_build_object('id', p1, 'code', 'x', 'title', repeat('a', 301), 'zite_azienda_id', 't23-x', 'status', 'x', 'is_open', true, 'total_fee_cents', 1, 'removed', false)));
  exception when check_violation then k := 1; end;
  ok := k = 1;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a title over 300 characters is refused\n', case when ok then 'PASS' else 'FAIL' end);

  ok := not has_function_privilege('authenticated', 'private.sync_pratiche(jsonb, boolean)', 'execute') and not has_function_privilege('anon', 'private.sync_pratiche(jsonb, boolean)', 'execute');
  failures := failures + (not ok)::int;
  report := report || format(E'%s sync_pratiche is still not callable by signed-in or anonymous users\n', case when ok then 'PASS' else 'FAIL' end);

  raise exception E'TEST REPORT (023 pratiche title): % failure(s)\n%', failures, report;
end $$;
