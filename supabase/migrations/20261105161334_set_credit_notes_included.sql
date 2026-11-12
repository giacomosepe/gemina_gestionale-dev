-- Recovered on 2026-11-09 from production's migration history (supabase_migrations.schema_migrations, version 20261105161334):
-- applied without a file in the repo (CLAUDE.md rule 2). Text exactly as recorded.


create or replace function public.set_credit_notes_included(p_pratica uuid, p_invoice_ids uuid[], p_included boolean)
 returns integer language plpgsql security invoker set search_path to ''
as $function$
declare v_n integer;
begin
  if not (select private.is_staff()) then raise exception 'Non autorizzato' using errcode = '42501'; end if;
  update public.supplier_invoices
     set credit_note_included = coalesce(p_included, false)
   where pratica_id = p_pratica and id = any(p_invoice_ids) and sign < 0 and removed_at is null
     and credit_note_included is distinct from coalesce(p_included, false);
  get diagnostics v_n = row_count;
  return v_n;
end $function$;
revoke all on function public.set_credit_notes_included(uuid, uuid[], boolean) from public, anon;
grant execute on function public.set_credit_notes_included(uuid, uuid[], boolean) to authenticated;
