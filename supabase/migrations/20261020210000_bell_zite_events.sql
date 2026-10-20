-- The bell reads Supabase (step 5, 2026-10-20). Besides the notifications made here by triggers (messages,
-- mentions, replies), it shows the events Zite creates: task assigned, signature requested or done, comment on a
-- task, opinion asked, chat, mention in a note, message from a segnalatore, new referral, first login,
-- commission due. Zite's one function for them (lib/notifiche/crea.ts notifica) sends each one here through the
-- portal-bridge action `notify`; the bridge inserts it with full rights. Browsers still cannot insert.
--
-- kind 'event': the label is Zite's own bell text (it may hold a short snippet, as the Zite bell does today).
-- The future unread-email job must skip kind 'event' (Zite already emails those).
-- event_key = the id of the Zite notification row: the same event cannot arrive twice.
-- (No DROP anywhere: the connector Claude uses refuses it.)

alter type public.notification_kind add value if not exists 'event';

alter table public.notifications
  add column event text check (char_length(event) <= 60),
  add column link text check (char_length(link) <= 200),
  add column event_key text check (char_length(event_key) <= 100);
alter table public.notifications add constraint notifications_label_length check (char_length(label) <= 300);
create unique index notifications_event_key_key on public.notifications (event_key) where event_key is not null;

comment on column public.notifications.event is 'Zite event code (EVENTO_NOTIFICA), kind event only';
comment on column public.notifications.link is 'Where the bell takes the user (Zite vaiA, e.g. pratica:<id>), kind event only';
comment on column public.notifications.event_key is 'Id of the Zite notification row: makes each event arrive once';
