-- A profile picture always lives at the same path, so a new picture looks
-- identical to the old one to anything that caches by path: the partner's
-- phone would keep showing the previous photo, or none, indefinitely.
--
-- avatar_version counts changes to the picture. Clients cannot write it; it
-- moves whenever avatar_path is written, including to the same value.

alter table public.profiles add column avatar_version integer not null default 0;

create or replace function app_private.profiles_bump_avatar_version()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.avatar_version := old.avatar_version + 1;
  return new;
end;
$$;

create trigger profiles_bump_avatar_version
  before update of avatar_path on public.profiles
  for each row execute function app_private.profiles_bump_avatar_version();

-- A changed name or picture has to reach the partner's phone too. Like an
-- edited note, this is a silent 'sync' entry: it shows nothing and carries
-- nothing, and only asks the app to fetch the current state.
create or replace function app_private.profiles_sync_partner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.display_name is not distinct from old.display_name
     and new.avatar_version = old.avatar_version then
    return new;
  end if;

  insert into public.notification_outbox (user_id, category, payload, dedupe_key)
  select other.user_id, 'sync', '{}'::jsonb,
         'sync:profile:' || new.id::text || ':' || new.avatar_version::text || ':' || md5(new.display_name) || ':' || other.user_id::text
  from public.couple_members mine
  join public.couple_spaces c on c.id = mine.couple_id and c.status = 'active'
  join public.couple_members other on other.couple_id = mine.couple_id and other.left_at is null
  where mine.user_id = new.id and mine.left_at is null
    and other.user_id <> new.id
  on conflict (dedupe_key) do nothing;
  return new;
end;
$$;

revoke all on function app_private.profiles_bump_avatar_version() from public, anon, authenticated;
revoke all on function app_private.profiles_sync_partner() from public, anon, authenticated;

create trigger profiles_sync_partner
  after update on public.profiles
  for each row execute function app_private.profiles_sync_partner();
