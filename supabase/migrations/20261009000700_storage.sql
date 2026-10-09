-- Private media storage.
--
--   couple-media   couples/<couple_id>/<uuid>.jpg|png   notes, memories, surprises
--   avatars        <user_id>/avatar.jpg                 profile pictures
--
-- Both buckets are private. The app reads media through short-lived signed
-- URLs, and Storage evaluates the SELECT policy below when it signs one, so a
-- URL can only be minted by a current member of the couple that owns the file.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('couple-media', 'couple-media', false, 5242880, array['image/jpeg', 'image/png']),
  ('avatars', 'avatars', false, 1048576, array['image/jpeg'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- True when `p_name` is a well-formed media path inside a couple the caller
-- currently belongs to. Malformed names fail closed instead of raising.
create or replace function app_private.can_access_couple_media(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  parts text[] := string_to_array(p_name, '/');
begin
  if array_length(parts, 1) <> 3 or parts[1] <> 'couples' then
    return false;
  end if;
  if parts[2] !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  if parts[3] !~ '^[0-9a-f-]{36}\.(jpg|png)$' then
    return false;
  end if;
  return app_private.is_active_member(parts[2]::uuid);
end;
$$;

create or replace function app_private.can_read_avatar(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  parts text[] := string_to_array(p_name, '/');
  owner_id uuid;
begin
  if array_length(parts, 1) <> 2 or parts[2] <> 'avatar.jpg' then
    return false;
  end if;
  if parts[1] !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  owner_id := parts[1]::uuid;
  return owner_id = auth.uid() or app_private.is_partner(owner_id);
end;
$$;

create policy couple_media_select on storage.objects
  for select to authenticated
  using (bucket_id = 'couple-media' and app_private.can_access_couple_media(name));

-- Uploads are write-once. There is no UPDATE policy, so a file that a note or
-- memory points at can never be swapped for different content afterwards, and
-- no DELETE policy: removal is done by the purge worker once nothing refers to
-- the file any more.
create policy couple_media_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'couple-media' and app_private.can_access_couple_media(name));

create policy avatars_select on storage.objects
  for select to authenticated
  using (bucket_id = 'avatars' and app_private.can_read_avatar(name));

create policy avatars_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg');

create policy avatars_update on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg')
  with check (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg');

create policy avatars_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg');

-- ---------------------------------------------------------------------------
-- Purge queue. Storage objects must be removed through the Storage API, so the
-- database records what to remove and the `purge-storage` Edge Function does it.
-- ---------------------------------------------------------------------------

create table public.storage_purge_queue (
  bucket_id text not null,
  path text not null,
  queued_at timestamptz not null default now(),
  primary key (bucket_id, path)
);

alter table public.storage_purge_queue enable row level security;
revoke all on table public.storage_purge_queue from anon, authenticated;

create or replace function app_private.media_path_referenced(p_path text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.notes where photo_path = p_path or drawing_path = p_path)
      or exists (select 1 from public.memories where photo_path = p_path or drawing_path = p_path)
      or exists (
        select 1 from public.scheduled_messages
        where status = 'pending' and (photo_path = p_path or drawing_path = p_path)
      );
$$;

create index notes_photo_path on public.notes (photo_path) where photo_path is not null;
create index notes_drawing_path on public.notes (drawing_path) where drawing_path is not null;
create index memories_photo_path on public.memories (photo_path) where photo_path is not null;
create index memories_drawing_path on public.memories (drawing_path) where drawing_path is not null;

create or replace function app_private.queue_media_if_orphaned(p_path text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_path is not null and not app_private.media_path_referenced(p_path) then
    insert into public.storage_purge_queue (bucket_id, path)
    values ('couple-media', p_path)
    on conflict do nothing;
  end if;
end;
$$;

-- Fires after a row stops pointing at a file. The file is queued for removal
-- only if no note, memory or pending surprise still uses it.
create or replace function app_private.media_release()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    perform app_private.queue_media_if_orphaned(old.photo_path);
    perform app_private.queue_media_if_orphaned(old.drawing_path);
    return old;
  end if;
  if old.photo_path is distinct from new.photo_path then
    perform app_private.queue_media_if_orphaned(old.photo_path);
  end if;
  if old.drawing_path is distinct from new.drawing_path then
    perform app_private.queue_media_if_orphaned(old.drawing_path);
  end if;
  return new;
end;
$$;

-- A surprise stops holding its media once it is no longer pending. (Delivery
-- hands the same files to the new note, which then holds them instead.)
create or replace function app_private.scheduled_media_release_on_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status = 'pending' and new.status <> 'pending' then
    perform app_private.queue_media_if_orphaned(new.photo_path);
    perform app_private.queue_media_if_orphaned(new.drawing_path);
  end if;
  return new;
end;
$$;

create trigger notes_media_release
  after update or delete on public.notes
  for each row execute function app_private.media_release();
create trigger memories_media_release
  after update or delete on public.memories
  for each row execute function app_private.media_release();
create trigger scheduled_media_release
  after update or delete on public.scheduled_messages
  for each row execute function app_private.media_release();
create trigger scheduled_media_release_on_status
  after update of status on public.scheduled_messages
  for each row execute function app_private.scheduled_media_release_on_status();

create or replace function app_private.profiles_avatar_release()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.avatar_path is not null and (tg_op = 'DELETE' or new.avatar_path is null) then
    insert into public.storage_purge_queue (bucket_id, path)
    values ('avatars', old.avatar_path)
    on conflict do nothing;
  end if;
  return coalesce(new, old);
end;
$$;

create trigger profiles_avatar_release
  after update or delete on public.profiles
  for each row execute function app_private.profiles_avatar_release();

-- Uploads whose note was never saved (the app was killed mid-send, say).
-- Anything in the bucket for more than a day with nothing pointing at it goes.
create or replace function app_private.queue_orphaned_uploads()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  queued integer;
begin
  with orphans as (
    insert into public.storage_purge_queue (bucket_id, path)
    select o.bucket_id, o.name
    from storage.objects o
    where o.bucket_id = 'couple-media'
      and o.created_at < now() - interval '24 hours'
      and not app_private.media_path_referenced(o.name)
    on conflict do nothing
    returning 1
  )
  select count(*) into queued from orphans;
  return queued;
end;
$$;

revoke all on function app_private.queue_orphaned_uploads() from public;

-- Worker interface for the purge-storage Edge Function (service role only).
create or replace function public.claim_storage_purges(p_limit integer default 100)
returns table (bucket_id text, path text)
language sql
security definer
set search_path = ''
as $$
  select q.bucket_id, q.path
  from public.storage_purge_queue q
  -- Re-check at claim time: a queued file may have been referenced again.
  where q.bucket_id <> 'couple-media' or not app_private.media_path_referenced(q.path)
  order by q.queued_at
  limit greatest(1, least(p_limit, 500));
$$;

create or replace function public.complete_storage_purges(p_bucket_id text, p_paths text[])
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.storage_purge_queue where bucket_id = p_bucket_id and path = any (p_paths);
$$;
