-- All current segnalatori (3 active, the managers' own portal accounts, tests) go to Giacomo Sepe (12 Nov 2026).
update public.partners
   set reference_manager_id = (select id from public.profiles where zite_user_id = 'StN9624KxH6Ul3a5eAb6GOAnM3uwjAyE' and role = 'staff')
 where reference_manager_id is null;