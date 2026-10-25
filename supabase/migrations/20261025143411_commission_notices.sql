-- Commission maturation notices (Linear PRDDISC-22, milestone M4). Zite's avvisoProvvigione.ts, from Supabase: when a commission line matures (its invoice gets
-- paid) the segnalatore gets a portal message and an email, and the Gemina team a bell. Additive (settings, an outbox, functions, a trigger).
--
-- Copied from Zite (src/lib/avvisoProvvigione.ts, maturazione.ts), word for word:
--  * subject / message title   "Provvigione maturata: <pratica>"
--  * message and email text    "La provvigione sulla pratica <pratica> è ora passata allo stato Maturata – Da Fatturare. Invia la tua fattura a Gemina Advisory per richiedere il pagamento della provvigione."
--  * email title               "La tua provvigione è maturata", button "Apri il portale"
--  * bell for the team         "Provvigione maturata per <segnalatore> sulla pratica <pratica>: <segnalatore> può fatturare a Gemina." (event provvigione-maturata, link pratica:<id>)
--  * <pratica> = the pratica code, else the invoice number, else "fattura" (Zite: "code · title"; the mirror has no title yet, so the code alone).
--  * One notice per commission line (not per invoice), only when a line goes from "invoice not paid" to "paid" (Zite haMaturato): a line created on an invoice that
--    is already paid sends nothing (matured_at is set at creation, not by an update). The team = the staff profiles (Zite: everybody in Ruoli who has opened the Gestionale).
--  * Never twice: one outbox row per line (primary key); re-saves, rebuilds and paid -> unpaid -> paid change nothing (matured_at is set once).
--  * An archived segnalatore gets no message and no email (the bridge skips them too); the team bell is still written.
--
-- The switch: the setting 'commission_notices' in private.settings, 'off' by default. While Zite's own notice runs (until the cutover, PRDDISC-28) it stays 'off' and
-- NOTHING is recorded or sent. To switch on, Giacomo, in the SQL editor:   update private.settings set value = 'on' where name = 'commission_notices';
-- A maturation that happened while it was off is never notified afterwards.

-- 1. Settings --------------------------------------------------------------------------------------------------------------------------
create table private.settings (
  name       text not null primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);
comment on table private.settings is 'Named switches Giacomo flips by hand (SQL editor); not exposed by the API';
alter table private.settings enable row level security;
revoke all on private.settings from public, anon, authenticated;
grant all on private.settings to service_role;
insert into private.settings (name, value) values ('commission_notices', 'off');

create function private.setting_on(p_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select lower(btrim(s.value)) = 'on' from private.settings s where s.name = p_name), false);
$$;
revoke execute on function private.setting_on(text) from public, anon, authenticated;

-- 2. Outbox: one row per commission line that matured, so a notice goes out once --------------------------------------------------------
create table public.commission_notices (
  commission_id    uuid not null primary key references public.commissions(id) on delete cascade,
  partner_id       uuid references public.partners(id) on delete set null,
  title            text not null,
  body             text not null,
  message_id       uuid references public.messages(id) on delete set null,
  bells            integer not null default 0,
  created_at       timestamptz not null default now(),
  email_claimed_at timestamptz,
  emailed_at       timestamptz,
  email_result     text check (email_result in ('sent', 'skipped'))
);
create index commission_notices_partner_id_idx on public.commission_notices (partner_id);
create index commission_notices_pending_idx on public.commission_notices (created_at) where emailed_at is null;
comment on table public.commission_notices is 'One row per commission line whose maturation was notified (portal message, team bells, email request); written only by the trigger; the message-emails function sends the email';
alter table public.commission_notices enable row level security;
create policy "commission_notices: staff read" on public.commission_notices for select to authenticated using ((select private.is_staff()));
revoke all on public.commission_notices from public, anon, authenticated;
grant select on public.commission_notices to authenticated;
grant all on public.commission_notices to service_role;

-- 3. The notice ------------------------------------------------------------------------------------------------------------------------
create function private.commission_matured_notice() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_inv record;
  v_pa record;
  v_pratica text;
  v_title text;
  v_body text;
  v_name text;
  v_conv uuid;
  v_msg uuid;
  v_n int;
  v_bells int := 0;
begin
  if not private.setting_on('commission_notices') then
    return null;
  end if;
  begin
    select d.number, d.pratica_id into v_inv from public.qonto_documents d where d.id = new.invoice_id;
    select pa.name, pa.archived, pa.zite_segnalatore_id into v_pa from public.partners pa where pa.id = new.partner_id;
    v_pratica := coalesce(nullif(btrim((select p.code from public.pratiche p where p.id = v_inv.pratica_id)), ''), v_inv.number, 'fattura');
    v_title := left('Provvigione maturata: ' || v_pratica, 200);
    v_body := 'La provvigione sulla pratica ' || v_pratica || ' è ora passata allo stato Maturata – Da Fatturare. Invia la tua fattura a Gemina Advisory per richiedere il pagamento della provvigione.';
    v_name := coalesce(nullif(btrim(v_pa.name), ''), 'Il segnalatore');

    insert into public.commission_notices (commission_id, partner_id, title, body) values (new.id, new.partner_id, v_title, v_body) on conflict do nothing;
    get diagnostics v_n = row_count;
    if v_n = 0 then
      return null;   -- already notified
    end if;

    -- 1. the portal message: what the bridge's post_automatic_message writes (signed Gemina Advisory, no sender); same subject = same conversation
    if not coalesce(v_pa.archived, true) then
      insert into public.conversations (kind, title, partner_id, created_by, zite_azienda_id, zite_pratica_id, zite_provvigione_id)
      values ('partner', v_title, new.partner_id, null, null, v_inv.pratica_id::text, new.id::text)
      on conflict (partner_id, (lower(btrim(title)))) where kind = 'partner'
      do update set title = public.conversations.title
      returning id into v_conv;
      select m.id into v_msg from public.messages m
       where m.conversation_id = v_conv and m.automatic and m.body = v_body and m.created_at > now() - interval '10 minutes' limit 1;
      if v_msg is null then
        insert into public.messages (conversation_id, sender_id, body, automatic) values (v_conv, null, v_body, true) returning id into v_msg;
      end if;
      update public.commission_notices set message_id = v_msg where commission_id = new.id;
    end if;

    -- 2. the bell of the team (Zite: everybody in Ruoli; here the staff profiles), once per person and line
    insert into public.notifications (organization_id, recipient_id, kind, actor_id, label, event, link, event_key)
    select p.organization_id, p.id, 'event', null,
           left('Provvigione maturata per ' || v_name || ' sulla pratica ' || v_pratica || ': ' || v_name || ' può fatturare a Gemina.', 300),
           'provvigione-maturata',
           case when v_inv.pratica_id is not null then 'pratica:' || v_inv.pratica_id::text else 'segnalatore:' || coalesce(v_pa.zite_segnalatore_id, '') end,
           'cm:' || new.id::text || ':' || p.id::text
      from public.profiles p where p.role = 'staff'
    on conflict do nothing;
    get diagnostics v_bells = row_count;
    update public.commission_notices set bells = v_bells where commission_id = new.id;

    -- 3. the email: asked of message-emails (mode commission); a sweep every 5 minutes retries what failed
    perform private.call_message_emails(jsonb_build_object('mode', 'commission', 'commission_id', new.id));
  exception when others then
    insert into public.commission_rebuild_errors (invoice_id, sqlstate, message) values (new.invoice_id, sqlstate, left('notice: ' || sqlerrm, 500));
  end;
  return null;
end $$;
revoke execute on function private.commission_matured_notice() from public, anon, authenticated;

create trigger commissions_matured_notice after update of matured_at on public.commissions
  for each row when (old.matured_at is null and new.matured_at is not null and new.matured_at > new.created_at)
  execute function private.commission_matured_notice();
