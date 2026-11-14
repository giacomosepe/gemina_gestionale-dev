-- Attributes of composite types are named too (the first rename covered tables and views only):
-- private.si_attr.bene_ids becomes asset_ids, which the supplier invoice functions return and read (their bodies are rewritten in 20261114190000).
do $$
begin
  if exists (select 1 from pg_attribute a where a.attrelid = 'private.si_attr'::regclass and a.attname = 'bene_ids' and not a.attisdropped) then
    alter type private.si_attr rename attribute bene_ids to asset_ids;
  end if;
end $$;
