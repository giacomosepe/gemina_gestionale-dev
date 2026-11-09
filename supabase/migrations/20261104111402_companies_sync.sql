-- Recovered on 2026-11-09 from production's migration history (supabase_migrations.schema_migrations, version 20261104111402):
-- applied without a file in the repo (CLAUDE.md rule 2). Text exactly as recorded.

-- Aziende: sincronizzazione Zite -> Supabase (4/11/2026)
-- Fino ad oggi public.companies era stata caricata una sola volta (19/10) e le
-- aziende nuove di Zite non arrivavano. Questa funzione è chiamata dalla
-- portal-bridge (azioni sync_azienda / resync_aziende) e per il recupero iniziale.
-- Regole: chiave zite_azienda_id; crea o aggiorna, non cancella mai; name sempre da Zite;
-- vat_number: chiave assente = mantieni, null o vuota = svuota; qonto_client_id riempito
-- solo se vuoto (un valore diverso è segnalato, mai sovrascritto); righe non valide saltate
-- e segnalate; alla fine ricollega pratiche senza azienda e fatture Qonto (funzioni esistenti).

create or replace function private.sync_companies(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  e jsonb;
  v_zid text; v_name text; v_has_vat boolean; v_vat text; v_qonto text;
  v_old record;
  ins int := 0; upd int := 0; same int := 0;
  skipped jsonb := '[]'::jsonb;
  conflicts jsonb := '[]'::jsonb;
  v_pr int := 0;
  v_links jsonb;
  v_pr_links int;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows must be a json array' using errcode = '22023';
  end if;

  for e in select value from jsonb_array_elements(p_rows) loop
    begin
      v_zid := nullif(btrim(e->>'zite_azienda_id'), '');
      v_name := nullif(btrim(e->>'name'), '');
      if v_zid is null or v_name is null then
        raise exception 'zite_azienda_id e name sono obbligatori';
      end if;
      v_has_vat := e ? 'vat_number';
      v_vat := private.vat_key(e->>'vat_number');
      v_qonto := nullif(btrim(e->>'qonto_client_id'), '');

      select id, name, vat_number, qonto_client_id into v_old
        from public.companies where zite_azienda_id = v_zid for update;

      if v_old.id is null then
        insert into public.companies (name, zite_azienda_id, vat_number)
        values (v_name, v_zid, case when v_has_vat then v_vat end)
        returning id, name, vat_number, qonto_client_id into v_old;
        ins := ins + 1;
      elsif v_old.name is distinct from v_name
            or (v_has_vat and v_old.vat_number is distinct from v_vat) then
        update public.companies
           set name = v_name,
               vat_number = case when v_has_vat then v_vat else vat_number end
         where id = v_old.id;
        upd := upd + 1;
      else
        same := same + 1;
      end if;

      if v_qonto is not null then
        if v_old.qonto_client_id is null then
          begin
            update public.companies set qonto_client_id = v_qonto where id = v_old.id and qonto_client_id is null;
          exception when unique_violation then
            conflicts := conflicts || jsonb_build_object('zite_azienda_id', v_zid, 'name', v_name,
                           'problem', 'Qonto ID già usato da un''altra azienda', 'qonto_client_id', v_qonto);
          end;
        elsif v_old.qonto_client_id <> v_qonto then
          conflicts := conflicts || jsonb_build_object('zite_azienda_id', v_zid, 'name', v_name,
                         'problem', 'Qonto ID diverso da quello in Supabase (non sovrascritto)',
                         'zite', v_qonto, 'supabase', v_old.qonto_client_id);
        end if;
      end if;
    exception when others then
      skipped := skipped || jsonb_build_object('zite_azienda_id', e->>'zite_azienda_id', 'error', sqlerrm);
    end;
  end loop;

  update public.pratiche p set company_id = c.id
    from public.companies c
   where p.company_id is null and p.zite_azienda_id = c.zite_azienda_id;
  get diagnostics v_pr = row_count;

  v_links := private.link_invoices_to_companies_by_vat();
  v_pr_links := private.link_invoices_to_pratiche();

  return jsonb_build_object('inserted', ins, 'updated', upd, 'unchanged', same,
                            'skipped', skipped, 'qonto_conflicts', conflicts,
                            'pratiche_linked', v_pr, 'qonto_invoices_linked_to_company', v_links->'linked',
                            'qonto_invoices_linked_to_pratica', v_pr_links);
end $$;

revoke all on function private.sync_companies(jsonb) from public, anon, authenticated;
comment on function private.sync_companies(jsonb) is
  'Aziende Zite -> public.companies. Chiamata dalla portal-bridge (sync_azienda, resync_aziende). Non cancella mai.';
