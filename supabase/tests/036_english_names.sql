-- Guard: every name in the database is English (glossary in docs/migrazione/glossary.md, Linear PM-191). Looks at tables, views, columns, functions,
-- constraints, indexes, policies, triggers and enum values of schemas public and private; fails when a name has a word (split on _ or space) that is in the
-- Italian list below. Known exceptions, each to go with a later step (see docs/migrazione/rename-inventory.md): names with "zite" (they become legacy_id when
-- the import runner is built). Same pattern as 001-035: one DO block, nothing is written, the message is the report.

do $$
declare
  italian text[] := array[
    'pratica','pratiche','bene','beni','scadenza','scadenze','azienda','aziende','trattativa','trattative','segnalatore','segnalatori','segnalazione','segnalazioni',
    'provvigione','provvigioni','fattura','fatture','messaggio','messaggi','attivita','contatto','contatti','servizio','servizi','fornitore','fornitori',
    'bando','bandi','firma','firme','allegato','allegati','dato','dati','nome','numero','tipo','ordine','ricevuta','archiviata','archiviato','consegnata',
    'bilancio','socio','soci','categoria','categorie','fase','fasi','lista','liste','campagna','campagne','obiettivo','notifica','notifiche','utente','utenti'];
  r record;
  report text := '';
  failures int := 0;
begin
  for r in
    select kind, name from (
      select 'table' as kind, n.nspname || '.' || c.relname as name, c.relname as word_source
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname in ('public', 'private') and c.relkind in ('r', 'p', 'v', 'm')
      union all
      select 'column', n.nspname || '.' || c.relname || '.' || a.attname, a.attname
        from pg_class c join pg_namespace n on n.oid = c.relnamespace join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
       where n.nspname in ('public', 'private') and c.relkind in ('r', 'p', 'v', 'm')
      union all
      select 'function', n.nspname || '.' || p.proname, p.proname
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('public', 'private')
      union all
      select 'constraint', c.conrelid::regclass || '.' || c.conname, c.conname
        from pg_constraint c where c.connamespace in ('public'::regnamespace, 'private'::regnamespace)
      union all
      select 'index', i.schemaname || '.' || i.indexname, i.indexname from pg_indexes i where i.schemaname in ('public', 'private')
      union all
      select 'policy', p.schemaname || '.' || p.tablename || '.' || p.policyname, p.policyname from pg_policies p where p.schemaname in ('public', 'private')
      union all
      select 'trigger', t.tgrelid::regclass || '.' || t.tgname, t.tgname
        from pg_trigger t where not t.tgisinternal and t.tgrelid in (select oid from pg_class where relnamespace in ('public'::regnamespace, 'private'::regnamespace))
      union all
      select 'enum value', ty.typname || '.' || e.enumlabel, e.enumlabel
        from pg_enum e join pg_type ty on ty.oid = e.enumtypid where ty.typnamespace in ('public'::regnamespace, 'private'::regnamespace)
    ) x
    where word_source not like '%zite%'
      and exists (select 1 from regexp_split_to_table(lower(word_source), '[^a-z0-9]+') w where w = any (italian))
    order by 1, 2
  loop
    failures := failures + 1;
    report := report || format(E'FAIL %s %s has an Italian word\n', r.kind, r.name);
  end loop;
  if failures = 0 then report := E'PASS every table, view, column, function, constraint, index, policy, trigger and enum value is English (names with zite are the known exception)\n'; end if;
  raise exception E'TEST REPORT (036 english names): % failure(s)\n%', failures, report;
end $$;
