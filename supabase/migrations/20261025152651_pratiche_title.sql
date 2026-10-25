-- Pratica title in the pratiche mirror. Zite sends it (the Titolo is derived there by aggiornaTitolo); Supabase only stores it, so notices, the invoice
-- link dialog and later screens can name a pratica without asking Zite. Additive: a nullable column, and sync_pratiche (replaced) that fills it.
-- A row that carries no "title" key (an older caller) leaves the stored title alone; "title": null or "" clears it.

alter table public.pratiche add column title text check (char_length(title) <= 300);
comment on column public.pratiche.title is 'Zite Titolo (derived there, e.g. "Credito 4.0 | 2027"); null until Zite has sent it';

create or replace function private.sync_pratiche(p_rows jsonb, p_mark_missing boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  ins  int := 0;
  upd  int := 0;
  gone int := 0;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows must be a json array' using errcode = '22023';
  end if;
  with up as (
    insert into public.pratiche as t (id, code, zite_azienda_id, status, is_open, total_fee_cents, removed_at, synced_at)
    select r.id, r.code, r.zite_azienda_id, r.status, r.is_open, r.total_fee_cents, case when r.removed then now() end, now()
      from jsonb_to_recordset(p_rows) as r(id uuid, code text, zite_azienda_id text, status text, is_open boolean,
                                           total_fee_cents bigint, removed boolean)
    on conflict (id) do update set
      code = excluded.code, zite_azienda_id = excluded.zite_azienda_id, status = excluded.status, is_open = excluded.is_open,
      total_fee_cents = excluded.total_fee_cents,
      removed_at = case when excluded.removed_at is null then null else coalesce(t.removed_at, excluded.removed_at) end,
      synced_at = now()
    returning (xmax = 0) as inserted)
  select count(*) filter (where inserted), count(*) filter (where not inserted) into ins, upd from up;

  -- the title, only for the rows that carry the key
  update public.pratiche t set title = nullif(btrim(e->>'title'), '')
    from jsonb_array_elements(p_rows) e
   where e ? 'title' and t.id = (e->>'id')::uuid;

  if p_mark_missing and jsonb_array_length(p_rows) > 0 then
    update public.pratiche set removed_at = now()
     where removed_at is null and id not in (select (e->>'id')::uuid from jsonb_array_elements(p_rows) e);
    get diagnostics gone = row_count;
  end if;
  perform private.link_invoices_to_pratiche();
  return jsonb_build_object('inserted', ins, 'updated', upd, 'marked_removed', gone);
end $$;

revoke execute on function private.sync_pratiche(jsonb, boolean) from public, anon, authenticated;
