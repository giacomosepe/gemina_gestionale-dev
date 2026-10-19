-- Fix: when a staff member writes in a conversation, the OTHER staff must not be notified
-- (found by tests/002). A staff sender counts as "taking part" from that message on.
-- Rule: staff recipients = staff taking part (conversation_members), minus the sender;
-- only if no staff is taking part AND the sender is not staff, every staff member.

create or replace function private.notify_on_message() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  c public.conversations%rowtype;
  sender_is_staff boolean;
  staff_involved boolean;
begin
  select * into c from public.conversations where id = new.conversation_id;
  select exists (select 1 from public.profiles where id = new.sender_id and role = 'staff')
    into sender_is_staff;
  select sender_is_staff or exists (
    select 1 from public.conversation_members cm
      join public.profiles p on p.id = cm.profile_id
     where cm.conversation_id = c.id and p.role = 'staff'
  ) into staff_involved;

  -- the staff sender becomes a participant (keeps future notifications consistent)
  if sender_is_staff then
    insert into public.conversation_members (conversation_id, profile_id, last_read_at)
    values (c.id, new.sender_id, now())
    on conflict (conversation_id, profile_id) do update set last_read_at = excluded.last_read_at;
  end if;

  insert into public.notifications
    (organization_id, recipient_id, kind, actor_id, conversation_id, message_id, label)
  select c.organization_id, p.id, 'message', new.sender_id, c.id, new.id, c.title
    from public.profiles p
   where p.id is distinct from new.sender_id
     and (
       (p.role = 'staff' and p.organization_id = c.organization_id
         and (not staff_involved or exists (
           select 1 from public.conversation_members cm
            where cm.conversation_id = c.id and cm.profile_id = p.id)))
       or (not new.internal and c.kind = 'partner' and exists (
           select 1 from public.partner_members pm
            where pm.partner_id = c.partner_id and pm.profile_id = p.id))
       or (not new.internal and c.kind = 'client' and exists (
           select 1 from public.company_members m
            where m.company_id = c.company_id and m.profile_id = p.id))
     );
  return new;
end $$;

revoke execute on function private.notify_on_message() from public, anon, authenticated;
