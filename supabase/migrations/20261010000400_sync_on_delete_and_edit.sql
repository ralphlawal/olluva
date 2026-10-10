-- When a note is deleted or edited, the other person's phone has to find out
-- even if the app is closed: otherwise a note someone took back would stay on
-- their partner's widget until the app was next opened.
--
-- A 'sync' entry in the outbox is sent as a silent background push. It shows
-- nothing and carries no content; it only asks the app to fetch the current
-- state and redraw its widget. It is not subject to notification preferences,
-- because it is not a notification: turning alerts off must not leave deleted
-- content on screen.

alter table public.notification_outbox drop constraint notification_outbox_category_check;
alter table public.notification_outbox add constraint notification_outbox_category_check
  check (category in ('new_note', 'surprise', 'important_date', 'pairing', 'account', 'sync'));

create or replace function app_private.notes_sync_partner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    -- Only when what is shown changes. Marking a note seen is not a reason
    -- to wake the author's phone.
    if new.deleted_at is not distinct from old.deleted_at
       and new.body is not distinct from old.body
       and new.style is not distinct from old.style
       and new.photo_path is not distinct from old.photo_path
       and new.drawing_path is not distinct from old.drawing_path then
      return new;
    end if;
  end if;

  insert into public.notification_outbox (user_id, category, payload, dedupe_key)
  select m.user_id, 'sync', jsonb_build_object('note_id', old.id),
         'sync:' || old.id::text || ':' || coalesce(new.version, 0)::text || ':' || tg_op || ':' || m.user_id::text
  from public.couple_members m
  join public.couple_spaces c on c.id = m.couple_id and c.status = 'active'
  where m.couple_id = old.couple_id and m.left_at is null
    and m.user_id is distinct from old.author_id
  on conflict (dedupe_key) do nothing;
  return coalesce(new, old);
end;
$$;

revoke all on function app_private.notes_sync_partner() from public, anon, authenticated;

create trigger notes_sync_partner
  after update or delete on public.notes
  for each row execute function app_private.notes_sync_partner();
