-- Hardening after the review of "staff follow Ruoli" (2026-10-20).
--
-- 1. Profiles: browsers may only change their own name. INSERT, DELETE and TRUNCATE were still granted to
--    authenticated (blocked today only by the absence of policies, and TRUNCATE ignores RLS).
revoke insert, delete, truncate on public.profiles from authenticated, anon;

-- 2. A person who left the team keeps no write power on their old comments (their last token lives up to 1 hour).
-- (ALTER, not DROP + CREATE: same result, and the Supabase connector used by Claude refuses statements with DROP.)
alter policy "comments: author edits own" on public.comments
  using (author_id = (select auth.uid()) and private.is_staff())
  with check (author_id = (select auth.uid()) and private.is_staff());

-- 3. Replies to a comment by someone who left the team do not notify them.
create or replace function private.notify_on_comment() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  parent_author uuid;
begin
  insert into public.notifications
    (organization_id, recipient_id, kind, actor_id, comment_id, record_type, record_zite_id, label)
  select new.organization_id, m, 'mention', new.author_id, new.id,
         new.record_type, new.record_zite_id, new.record_label
    from unnest(new.mentions) as m
   where m is distinct from new.author_id;

  if new.parent_id is not null then
    select c.author_id into parent_author
      from public.comments c
      join public.profiles p on p.id = c.author_id and p.role = 'staff'
     where c.id = new.parent_id;
    if parent_author is not null and parent_author is distinct from new.author_id
       and not (parent_author = any(new.mentions)) then
      insert into public.notifications
        (organization_id, recipient_id, kind, actor_id, comment_id, record_type, record_zite_id, label)
      values (new.organization_id, parent_author, 'comment_reply', new.author_id, new.id,
              new.record_type, new.record_zite_id, new.record_label);
    end if;
  end if;
  return new;
end $$;
revoke execute on function private.notify_on_comment() from public, anon, authenticated;
