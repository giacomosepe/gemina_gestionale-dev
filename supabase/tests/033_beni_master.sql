-- Beni come lista principale su Supabase (migration beni_master, 2026-11-10). One DO block, everything rolled back by the final RAISE.

do $$
declare
  org    uuid := (select id from public.organizations limit 1);
  staff  uuid := (select id from public.profiles where role = 'staff' limit 1);
  u_ref  uuid := gen_random_uuid();
  p_ref  uuid;
  pr     uuid := gen_random_uuid();
  pr2    uuid := gen_random_uuid();
  b_tr   uuid;
  b_pr   uuid;
  segn   uuid;
  n      int;
  ok     boolean;
  report text := '';
  failures int := 0;
begin
  perform private.sync_pratiche(jsonb_build_array(
    jsonb_build_object('id', pr,  'code', 'PR-T33-001', 'zite_azienda_id', null, 'status', 'In lavorazione', 'is_open', true, 'total_fee_cents', null, 'removed', false),
    jsonb_build_object('id', pr2, 'code', 'PR-T33-002', 'zite_azienda_id', null, 'status', 'In lavorazione', 'is_open', true, 'total_fee_cents', null, 'removed', false)));

  -- staff, through the API role
  perform set_config('request.jwt.claims', json_build_object('sub', staff, 'role', 'authenticated')::text, true);
  set local role authenticated;

  insert into public.beni (trattativa_zite_id, name, supplier_hint, order_date) values ('t33-trattativa', 'Tornio CNC', 'Fornitore Spa', '2026-12-01') returning id into b_tr;
  ok := (select pratica_id is null and organization_id = org and not ordered from public.beni where id = b_tr);
  failures := failures + (not ok)::int;
  report := report || format(E'%s a bene can be born on a trattativa (no pratica yet)\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    insert into public.beni (name) values ('Orfano');
    ok := false;
  exception when check_violation then ok := true; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a bene needs a pratica or a trattativa\n', case when ok then 'PASS' else 'FAIL' end);

  update public.beni set pratica_id = pr where id = b_tr;
  ok := (select pratica_id = pr from public.beni where id = b_tr);
  failures := failures + (not ok)::int;
  report := report || format(E'%s the trattativa''s bene passes to the pratica\n', case when ok then 'PASS' else 'FAIL' end);

  begin
    update public.beni set pratica_id = pr2 where id = b_tr;
    ok := false;
  exception when others then ok := sqlerrm like '%non si sposta%'; end;
  failures := failures + (not ok)::int;
  report := report || format(E'%s then it never moves to another pratica\n', case when ok then 'PASS' else 'FAIL' end);

  insert into public.bene_values (bene_id, dato_id, value) values (b_tr, 'dato-coefficiente', '0,2');
  insert into public.bene_values (bene_id, dato_id, value) values (b_tr, 'dato-coefficiente', '0,3')
    on conflict (bene_id, dato_id) do update set value = excluded.value;
  ok := (select count(*) = 1 and min(value) = '0,3' and min(updated_by::text) = staff::text and min(organization_id::text) = org::text from public.bene_values where bene_id = b_tr);
  failures := failures + (not ok)::int;
  report := report || format(E'%s one value per bene and dato; author and organization set by the database\n', case when ok then 'PASS' else 'FAIL' end);
  reset role;

  -- a segnalatore sees nothing
  insert into auth.users (id, email, aud, role) values (u_ref, 't33-ref@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'partner' where id = u_ref;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t33-ref', 'Test referrer 33', 't33-ref@example.test', org) returning id into p_ref;
  insert into public.partner_members (partner_id, profile_id) values (p_ref, u_ref);
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.beni where id = b_tr;
  ok := n = 0 and (select count(*) from public.bene_values where bene_id = b_tr) = 0;
  begin
    insert into public.bene_values (bene_id, dato_id, value) values (b_tr, 'x', 'y');
    ok := false;
  exception when insufficient_privilege then null; end;
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalatore reads and writes no bene and no value\n', case when ok then 'PASS' else 'FAIL' end);

  set local role anon;
  begin
    perform count(*) from public.bene_values;
    ok := false;
  exception when insufficient_privilege then ok := true; end;
  reset role;
  failures := failures + (not ok)::int;
  report := report || format(E'%s anonymous cannot read the values\n', case when ok then 'PASS' else 'FAIL' end);

  -- the invoice import: a placeholder (no zite_bene_id, no allocations) is put aside once a managed bene exists
  insert into public.beni (pratica_id) values (pr2) returning id into segn;
  insert into public.beni (pratica_id, name) values (pr2, 'Bene gestito') returning id into b_pr;
  update public.beni set zite_bene_id = id::text where id = b_pr;
  perform private.sync_pratica_beni(pr2, jsonb_build_array(jsonb_build_object('id', b_pr::text, 'nome', 'Bene gestito', 'fornitore', null)));
  ok := (select removed_at is not null from public.beni where id = segn) and (select removed_at is null from public.beni where id = b_pr);
  failures := failures + (not ok)::int;
  report := report || format(E'%s the import keeps the managed bene and puts the placeholder aside\n', case when ok then 'PASS' else 'FAIL' end);

  delete from public.beni where id = b_tr;
  ok := not exists (select 1 from public.bene_values where bene_id = b_tr);
  failures := failures + (not ok)::int;
  report := report || format(E'%s the values follow their bene\n', case when ok then 'PASS' else 'FAIL' end);

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
