-- Notes and reactions.
--
-- A note is an immutable-identity row with a client-generated id (which makes
-- a retried send idempotent) and server-authoritative timestamps. Notes are a
-- history from day one: "the latest note" is a query, not a special row, so the
-- two partners never write to the same record and cannot overwrite each other.
--
-- Only the author edits a note, and every edit carries the version it was
-- based on. A stale edit is rejected with `version_conflict` rather than
-- silently replacing something newer.

create table public.notes (
  id uuid primary key default gen_random_uuid(),
  couple_id uuid not null references public.couple_spaces (id) on delete cascade,
  author_id uuid references public.profiles (id) on delete set null,
  body text not null default '' check (char_length(body) <= 280),
  style jsonb not null default '{}'::jsonb
    check (jsonb_typeof(style) = 'object' and pg_column_size(style) <= 8192),
  photo_path text,
  drawing_path text,
  origin text not null default 'direct' check (origin in ('direct', 'scheduled')),
  version integer not null default 1,
  seen_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Media can only ever point inside the note's own couple folder.
  constraint notes_photo_path_scoped check (
    photo_path is null
    or photo_path ~ ('^couples/' || couple_id::text || '/[0-9a-f-]{36}\.jpg$')
  ),
  constraint notes_drawing_path_scoped check (
    drawing_path is null
    or drawing_path ~ ('^couples/' || couple_id::text || '/[0-9a-f-]{36}\.png$')
  ),
  constraint notes_has_content check (
    deleted_at is not null
    or char_length(btrim(body)) > 0
    or photo_path is not null
    or drawing_path is not null
  )
);

create index notes_by_couple_recent on public.notes (couple_id, created_at desc, id desc);
create index notes_by_author on public.notes (author_id);

create or replace function app_private.notes_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- A request carrying a user JWT is a client write: the server decides who
  -- wrote it and how it arrived. Only the scheduler (no JWT) sets these itself.
  if auth.uid() is not null then
    new.author_id := auth.uid();
    new.origin := 'direct';
  end if;
  new.version := 1;
  new.seen_at := null;
  new.deleted_at := null;
  new.created_at := now();
  new.updated_at := now();
  return new;
end;
$$;

create trigger notes_before_insert
  before insert on public.notes
  for each row execute function app_private.notes_before_insert();

alter table public.notes enable row level security;
revoke all on table public.notes from anon, authenticated;
grant select on table public.notes to authenticated;
grant insert (id, couple_id, author_id, body, style, photo_path, drawing_path)
  on table public.notes to authenticated;

create policy notes_select_member on public.notes
  for select to authenticated
  using (app_private.is_active_member(couple_id));

create policy notes_insert_member on public.notes
  for insert to authenticated
  with check (
    author_id = (select auth.uid())
    and app_private.is_active_member(couple_id)
  );

create or replace function public.update_note(
  p_note_id uuid,
  p_expected_version integer,
  p_body text,
  p_style jsonb,
  p_photo_path text,
  p_drawing_path text
)
returns public.notes
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  n public.notes;
begin
  select * into n from public.notes where id = p_note_id for update;

  if n.id is null or n.deleted_at is not null or not app_private.is_active_member(n.couple_id) then
    raise exception 'note_not_found';
  end if;
  if n.author_id is distinct from uid then
    raise exception 'not_note_author';
  end if;
  if n.version <> p_expected_version then
    raise exception 'version_conflict';
  end if;

  update public.notes set
    body = coalesce(p_body, ''),
    style = coalesce(p_style, '{}'::jsonb),
    photo_path = p_photo_path,
    drawing_path = p_drawing_path,
    version = n.version + 1,
    updated_at = now()
  where id = p_note_id
  returning * into n;
  return n;
end;
$$;

-- Soft delete. The row stays as a tombstone so the partner's device and widget
-- learn the note is gone; the content itself is erased immediately.
create or replace function public.delete_note(p_note_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  n public.notes;
begin
  select * into n from public.notes where id = p_note_id for update;

  if n.id is null or not app_private.is_active_member(n.couple_id) then
    raise exception 'note_not_found';
  end if;
  if n.author_id is distinct from uid then
    raise exception 'not_note_author';
  end if;
  if n.deleted_at is not null then
    return;
  end if;

  update public.notes set
    deleted_at = now(),
    body = '',
    style = '{}'::jsonb,
    photo_path = null,
    drawing_path = null,
    version = n.version + 1,
    updated_at = now()
  where id = p_note_id;
end;
$$;

-- The acknowledgement: only the recipient can mark a note as seen, once.
create or replace function public.mark_note_seen(p_note_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
begin
  update public.notes set seen_at = now()
  where id = p_note_id
    and seen_at is null
    and deleted_at is null
    and author_id is distinct from uid
    and app_private.is_active_member(couple_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- note_reactions: one reaction per person per note.
-- ---------------------------------------------------------------------------

create table public.note_reactions (
  note_id uuid not null references public.notes (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  -- Denormalised so RLS and Realtime filters need no join.
  couple_id uuid not null references public.couple_spaces (id) on delete cascade,
  kind text not null check (kind in ('love', 'smile', 'laugh', 'hug', 'moved', 'spark')),
  created_at timestamptz not null default now(),
  primary key (note_id, user_id)
);

create index note_reactions_by_couple on public.note_reactions (couple_id);

alter table public.note_reactions enable row level security;
revoke all on table public.note_reactions from anon, authenticated;
grant select on table public.note_reactions to authenticated;
create policy note_reactions_select_member on public.note_reactions
  for select to authenticated
  using (app_private.is_active_member(couple_id));

-- Pass null to remove the reaction. You react to your partner's notes, not
-- your own.
create or replace function public.set_reaction(p_note_id uuid, p_kind text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  n public.notes;
begin
  select * into n from public.notes where id = p_note_id;
  if n.id is null or n.deleted_at is not null or not app_private.is_active_member(n.couple_id) then
    raise exception 'note_not_found';
  end if;
  if n.author_id is not distinct from uid then
    raise exception 'cannot_react_to_own_note';
  end if;

  if p_kind is null then
    delete from public.note_reactions where note_id = p_note_id and user_id = uid;
  else
    insert into public.note_reactions (note_id, user_id, couple_id, kind)
    values (p_note_id, uid, n.couple_id, p_kind)
    on conflict (note_id, user_id) do update set kind = excluded.kind, created_at = now();
  end if;
end;
$$;
