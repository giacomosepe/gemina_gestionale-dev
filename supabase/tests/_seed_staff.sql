-- Made-up staff for the tests that expect the accounts production has: one admin and two managers.
-- The runner runs this file and the test in ONE transaction; the test ends in an exception, so the
-- accounts are rolled back with everything else and nothing stays in the database.
do $$
declare a uuid := gen_random_uuid(); m1 uuid := gen_random_uuid(); m2 uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role) values
    (a,  'seed-admin@example.test', 'authenticated', 'authenticated'),
    (m1, 'seed-manager-1@example.test', 'authenticated', 'authenticated'),
    (m2, 'seed-manager-2@example.test', 'authenticated', 'authenticated');
  update public.profiles set role = 'staff', staff_role = 'admin',   zite_user_id = 'seed-zite-admin' where id = a;
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 'seed-zite-mgr-1' where id = m1;
  update public.profiles set role = 'staff', staff_role = 'manager', zite_user_id = 'seed-zite-mgr-2' where id = m2;
end $$;
