-- The supplier-invoice views read with the rights of who reads (migration supplier_views_security_invoker, 2026-11-10).
-- Same pattern as 001-029: one DO block, everything rolled back by the final RAISE. Uses the rows already there: counts only, no data shown.

do $$
declare
  u_ref uuid := gen_random_uuid();
  org   uuid := (select id from public.organizations limit 1);
  p_ref uuid;
  staff uuid := (select id from public.profiles where role = 'staff' limit 1);
  tot1 int; tot2 int; n1 int; n2 int;
  ok boolean;
  report text := '';
  failures int := 0;
begin
  -- every view of the public schema that is not security_invoker would bypass RLS: the two of this migration must not be among them
  ok := not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                     where n.nspname = 'public' and c.relkind = 'v'
                       and c.relname in ('supplier_invoice_lines_status', 'supplier_invoice_by_bene')
                       and not coalesce('security_invoker=true' = any(c.reloptions), false));
  failures := failures + (not ok)::int;
  report := report || format(E'%s both supplier views are security_invoker\n', case when ok then 'PASS' else 'FAIL' end);

  select count(*) into tot1 from public.supplier_invoice_lines_status;
  select count(*) into tot2 from public.supplier_invoice_by_bene;

  if staff is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', staff, 'role', 'authenticated')::text, true);
    set local role authenticated;
    select count(*) into n1 from public.supplier_invoice_lines_status;
    select count(*) into n2 from public.supplier_invoice_by_bene;
    reset role;
    ok := n1 = tot1 and n2 = tot2;
  else ok := true; end if;
  failures := failures + (not ok)::int;
  report := report || format(E'%s staff still read every row\n', case when ok then 'PASS' else 'FAIL' end);

  insert into auth.users (id, email, aud, role) values (u_ref, 't30-ref@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'partner' where id = u_ref;
  insert into public.partners (zite_segnalatore_id, name, email, organization_id) values ('t30-ref', 'Test referrer 30', 't30-ref@example.test', org) returning id into p_ref;
  insert into public.partner_members (partner_id, profile_id) values (p_ref, u_ref);
  perform set_config('request.jwt.claims', json_build_object('sub', u_ref, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin select count(*) into n1 from public.supplier_invoice_lines_status; exception when insufficient_privilege then n1 := 0; end;
  begin select count(*) into n2 from public.supplier_invoice_by_bene; exception when insufficient_privilege then n2 := 0; end;
  reset role;
  ok := n1 = 0 and n2 = 0;
  failures := failures + (not ok)::int;
  report := report || format(E'%s a segnalatore reads no supplier invoice line\n', case when ok then 'PASS' else 'FAIL' end);

  raise exception E'TEST REPORT (all data rolled back)\n%FAILURES: %', report, failures;
end $$;
