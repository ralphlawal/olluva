-- Shared memories, important dates, scheduled messages.

-- ---------------------------------------------------------------------------
-- memories: the couple's scrapbook. A memory owns a copy of its content, so
-- it survives the deletion of the note it was saved from.
-- ---------------------------------------------------------------------------

create table public.memories (
  id uuid primary key default gen_random_uuid(),
  couple_id uuid not null references public.couple_spaces (id) on delete cascade,
  created_by uuid references public.profiles (id) on delete set null,
  kind text not null check (kind in ('note', 'photo', 'drawing', 'moment')),
  title text not null default '' check (char_length(title) <= 80),
  caption text not null default '' check (char_length(caption) <= 300),
  body text not null default '' check (char_length(body) <= 280),
  style jsonb not null default '{}'::jsonb
    check (jsonb_typeof(style) = 'object' and pg_column_size(style) <= 8192),
  photo_path text,
  drawing_path text,
  source_note_id uuid references public.notes (id) on delete set null,
  occurred_on date not null default current_date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint memories_photo_path_scoped check (
    photo_path is null
    or photo_path ~ ('^couples/' || couple_id::text || '/[0-9a-f-]{36}\.jpg$')
  ),
  constraint memories_drawing_path_scoped check (
    drawing_path is null
    or drawing_path ~ ('^couples/' || couple_id::text || '/[0-9a-f-]{36}\.png$')
  ),
  constraint memories_has_content check (
    char_length(btrim(title)) > 0
    or char_length(btrim(caption)) > 0
    or char_length(btrim(body)) > 0
    or photo_path is not null
    or drawing_path is not null
  )
);

-- A note can be saved to memories once.
create unique index memories_one_per_source_note
  on public.memories (couple_id, source_note_id) where source_note_id is not null;
create index memories_timeline on public.memories (couple_id, occurred_on desc, id desc);

create or replace function app_private.memories_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_count integer;
begin
  if auth.uid() is not null then
    new.created_by := auth.uid();
  end if;
  new.created_at := now();
  new.updated_at := now();

  -- Lock the couple row so two simultaneous saves cannot both slip under the limit.
  perform 1 from public.couple_spaces where id = new.couple_id for update;
  select count(*) into current_count from public.memories where couple_id = new.couple_id;
  if current_count >= app_private.couple_limit(new.couple_id, 'memories') then
    raise exception 'memory_limit_reached';
  end if;
  return new;
end;
$$;

create trigger memories_before_insert
  before insert on public.memories
  for each row execute function app_private.memories_before_insert();

create trigger memories_touch
  before update on public.memories
  for each row execute function app_private.touch_updated_at();

alter table public.memories enable row level security;
revoke all on table public.memories from anon, authenticated;
grant select, delete on table public.memories to authenticated;
grant insert (id, couple_id, created_by, kind, title, caption, photo_path, drawing_path, occurred_on)
  on table public.memories to authenticated;
grant update (title, caption, occurred_on) on table public.memories to authenticated;

create policy memories_select_member on public.memories
  for select to authenticated
  using (app_private.is_active_member(couple_id));

-- Direct inserts are for moments, photos and drawings. Saving a note goes
-- through save_note_to_memories so the copy is taken server-side.
create policy memories_insert_member on public.memories
  for insert to authenticated
  with check (
    created_by = (select auth.uid())
    and kind <> 'note'
    and app_private.is_active_member(couple_id)
  );

-- The scrapbook is shared: either partner may edit a caption or remove an entry.
create policy memories_update_member on public.memories
  for update to authenticated
  using (app_private.is_active_member(couple_id))
  with check (app_private.is_active_member(couple_id));

create policy memories_delete_member on public.memories
  for delete to authenticated
  using (app_private.is_active_member(couple_id));

create or replace function public.save_note_to_memories(p_note_id uuid, p_caption text default '')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  n public.notes;
  memory_id uuid;
begin
  select * into n from public.notes where id = p_note_id;
  if n.id is null or n.deleted_at is not null or not app_private.is_active_member(n.couple_id) then
    raise exception 'note_not_found';
  end if;

  select id into memory_id from public.memories
  where couple_id = n.couple_id and source_note_id = n.id;
  if memory_id is not null then
    return memory_id;
  end if;

  insert into public.memories (
    couple_id, created_by, kind, caption, body, style,
    photo_path, drawing_path, source_note_id, occurred_on
  ) values (
    n.couple_id, uid, 'note', left(coalesce(p_caption, ''), 300), n.body, n.style,
    n.photo_path, n.drawing_path, n.id, (n.created_at at time zone 'UTC')::date
  )
  returning id into memory_id;
  return memory_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- important_dates
-- ---------------------------------------------------------------------------

create table public.important_dates (
  id uuid primary key default gen_random_uuid(),
  couple_id uuid not null references public.couple_spaces (id) on delete cascade,
  created_by uuid not null references public.profiles (id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 60),
  kind text not null default 'custom'
    check (kind in ('anniversary', 'birthday', 'first_meeting', 'milestone', 'custom')),
  starts_on date not null,
  recurrence text not null default 'yearly' check (recurrence in ('none', 'monthly', 'yearly')),
  -- 'private' dates are visible only to the person who added them, which is
  -- what makes planning a surprise possible.
  visibility text not null default 'shared' check (visibility in ('shared', 'private')),
  notify boolean not null default true,
  remind_days_before smallint[] not null default '{0}'
    check (
      remind_days_before <@ array[0, 1, 3, 7, 14, 30]::smallint[]
      and coalesce(array_length(remind_days_before, 1), 0) <= 4
    ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index important_dates_by_couple on public.important_dates (couple_id, starts_on);

create or replace function app_private.important_dates_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then
      new.created_by := auth.uid();
    end if;
    perform 1 from public.couple_spaces where id = new.couple_id for update;
    if (select count(*) from public.important_dates where couple_id = new.couple_id)
       >= app_private.couple_limit(new.couple_id, 'important_dates') then
      raise exception 'date_limit_reached';
    end if;
  else
    new.couple_id := old.couple_id;
    new.created_by := old.created_by;
    new.created_at := old.created_at;
    -- Only the owner can change who may see a date.
    if new.visibility is distinct from old.visibility and auth.uid() is distinct from old.created_by then
      raise exception 'not_date_owner';
    end if;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger important_dates_guard
  before insert or update on public.important_dates
  for each row execute function app_private.important_dates_guard();

alter table public.important_dates enable row level security;
revoke all on table public.important_dates from anon, authenticated;
grant select, delete on table public.important_dates to authenticated;
grant insert (id, couple_id, created_by, title, kind, starts_on, recurrence, visibility, notify, remind_days_before)
  on table public.important_dates to authenticated;
grant update (title, kind, starts_on, recurrence, visibility, notify, remind_days_before)
  on table public.important_dates to authenticated;

create policy important_dates_select on public.important_dates
  for select to authenticated
  using (
    app_private.is_active_member(couple_id)
    and (visibility = 'shared' or created_by = (select auth.uid()))
  );

create policy important_dates_insert on public.important_dates
  for insert to authenticated
  with check (created_by = (select auth.uid()) and app_private.is_active_member(couple_id));

create policy important_dates_update on public.important_dates
  for update to authenticated
  using (
    app_private.is_active_member(couple_id)
    and (visibility = 'shared' or created_by = (select auth.uid()))
  )
  with check (app_private.is_active_member(couple_id));

create policy important_dates_delete on public.important_dates
  for delete to authenticated
  using (
    app_private.is_active_member(couple_id)
    and (visibility = 'shared' or created_by = (select auth.uid()))
  );

-- The next occurrence on or after `p_today`. Interval arithmetic clamps
-- 29 February to the 28th in non-leap years and the 31st to shorter months,
-- matching Calendar's behaviour in the iOS Domain module.
create or replace function app_private.next_occurrence(p_starts_on date, p_recurrence text, p_today date)
returns date
language plpgsql
immutable
set search_path = ''
as $$
declare
  n integer;
  candidate date;
begin
  if p_recurrence = 'none' then
    return case when p_starts_on >= p_today then p_starts_on else null end;
  end if;
  if p_starts_on >= p_today then
    return p_starts_on;
  end if;

  if p_recurrence = 'yearly' then
    n := extract(year from p_today)::integer - extract(year from p_starts_on)::integer;
    candidate := (p_starts_on + make_interval(years => n))::date;
    if candidate < p_today then
      candidate := (p_starts_on + make_interval(years => n + 1))::date;
    end if;
  else
    n := (extract(year from p_today)::integer - extract(year from p_starts_on)::integer) * 12
       + (extract(month from p_today)::integer - extract(month from p_starts_on)::integer);
    candidate := (p_starts_on + make_interval(months => n))::date;
    if candidate < p_today then
      candidate := (p_starts_on + make_interval(months => n + 1))::date;
    end if;
  end if;
  return candidate;
end;
$$;

-- ---------------------------------------------------------------------------
-- scheduled_messages: a durable server-side queue. Delivery never depends on
-- the sender's phone being awake.
-- ---------------------------------------------------------------------------

create table public.scheduled_messages (
  id uuid primary key default gen_random_uuid(),
  couple_id uuid not null references public.couple_spaces (id) on delete cascade,
  author_id uuid not null references public.profiles (id) on delete cascade,
  body text not null default '' check (char_length(body) <= 280),
  style jsonb not null default '{}'::jsonb
    check (jsonb_typeof(style) = 'object' and pg_column_size(style) <= 8192),
  photo_path text,
  drawing_path text,
  -- An absolute instant. `time_zone` records the zone the sender chose it in,
  -- purely so the app can show "9:00 in Lisbon" back to them later.
  deliver_at timestamptz not null,
  time_zone text not null default 'UTC',
  status text not null default 'pending'
    check (status in ('pending', 'delivered', 'cancelled', 'failed')),
  failure_reason text,
  delivered_at timestamptz,
  delivered_note_id uuid references public.notes (id) on delete set null,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint scheduled_photo_path_scoped check (
    photo_path is null
    or photo_path ~ ('^couples/' || couple_id::text || '/[0-9a-f-]{36}\.jpg$')
  ),
  constraint scheduled_drawing_path_scoped check (
    drawing_path is null
    or drawing_path ~ ('^couples/' || couple_id::text || '/[0-9a-f-]{36}\.png$')
  ),
  constraint scheduled_has_content check (
    char_length(btrim(body)) > 0 or photo_path is not null or drawing_path is not null
  )
);

create index scheduled_due on public.scheduled_messages (deliver_at) where status = 'pending';
create index scheduled_by_author on public.scheduled_messages (author_id, deliver_at);

create or replace function app_private.validate_delivery_time(p_deliver_at timestamptz, p_time_zone text)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if p_deliver_at is null or p_deliver_at < now() + interval '1 minute' then
    raise exception 'deliver_at_too_soon';
  end if;
  if p_deliver_at > now() + interval '2 years' then
    raise exception 'deliver_at_too_far';
  end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = p_time_zone) then
    raise exception 'invalid_time_zone';
  end if;
end;
$$;

create or replace function app_private.scheduled_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is not null then
    new.author_id := auth.uid();
  end if;
  new.status := 'pending';
  new.failure_reason := null;
  new.delivered_at := null;
  new.delivered_note_id := null;
  new.version := 1;
  new.created_at := now();
  new.updated_at := now();

  perform app_private.validate_delivery_time(new.deliver_at, new.time_zone);

  perform 1 from public.couple_spaces where id = new.couple_id for update;
  if (select count(*) from public.scheduled_messages
      where couple_id = new.couple_id and author_id = new.author_id and status = 'pending')
     >= app_private.couple_limit(new.couple_id, 'scheduled_pending') then
    raise exception 'scheduled_limit_reached';
  end if;
  return new;
end;
$$;

create trigger scheduled_before_insert
  before insert on public.scheduled_messages
  for each row execute function app_private.scheduled_before_insert();

alter table public.scheduled_messages enable row level security;
revoke all on table public.scheduled_messages from anon, authenticated;
grant select on table public.scheduled_messages to authenticated;
grant insert (id, couple_id, author_id, body, style, photo_path, drawing_path, deliver_at, time_zone)
  on table public.scheduled_messages to authenticated;

-- A surprise is a secret: only its author can see it before it is delivered.
create policy scheduled_select_author on public.scheduled_messages
  for select to authenticated
  using (author_id = (select auth.uid()));

create policy scheduled_insert_author on public.scheduled_messages
  for insert to authenticated
  with check (author_id = (select auth.uid()) and app_private.is_active_member(couple_id));

create or replace function public.update_scheduled_message(
  p_id uuid,
  p_expected_version integer,
  p_body text,
  p_style jsonb,
  p_photo_path text,
  p_drawing_path text,
  p_deliver_at timestamptz,
  p_time_zone text
)
returns public.scheduled_messages
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  m public.scheduled_messages;
begin
  select * into m from public.scheduled_messages where id = p_id for update;
  if m.id is null or m.author_id <> uid then
    raise exception 'scheduled_not_found';
  end if;
  if m.status <> 'pending' then
    raise exception 'scheduled_not_pending';
  end if;
  if m.version <> p_expected_version then
    raise exception 'version_conflict';
  end if;
  perform app_private.validate_delivery_time(p_deliver_at, p_time_zone);

  update public.scheduled_messages set
    body = coalesce(p_body, ''),
    style = coalesce(p_style, '{}'::jsonb),
    photo_path = p_photo_path,
    drawing_path = p_drawing_path,
    deliver_at = p_deliver_at,
    time_zone = p_time_zone,
    version = m.version + 1,
    updated_at = now()
  where id = p_id
  returning * into m;
  return m;
end;
$$;

create or replace function public.cancel_scheduled_message(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  m public.scheduled_messages;
begin
  -- The row lock is what makes cancel-versus-deliver safe: whichever of the
  -- two takes the lock first wins, and the other sees the new status.
  select * into m from public.scheduled_messages where id = p_id for update;
  if m.id is null or m.author_id <> uid then
    raise exception 'scheduled_not_found';
  end if;
  if m.status = 'cancelled' then
    return;
  end if;
  if m.status <> 'pending' then
    raise exception 'scheduled_not_pending';
  end if;
  update public.scheduled_messages
  set status = 'cancelled', version = m.version + 1, updated_at = now()
  where id = p_id;
end;
$$;

-- The worker. Run every minute by pg_cron. Safe to run concurrently and safe to
-- run again after a crash:
--   * SKIP LOCKED means two overlapping runs never pick the same row.
--   * The delivered note reuses the scheduled message's id, so even a replay
--     of an already-delivered row cannot create a second note.
--   * The note insert and the status change commit together or not at all.
create or replace function app_private.deliver_due_scheduled_messages(p_batch integer default 200)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  m public.scheduled_messages;
  delivered integer := 0;
begin
  for m in
    select * from public.scheduled_messages
    where status = 'pending' and deliver_at <= now()
    order by deliver_at
    limit p_batch
    for update skip locked
  loop
    -- Re-check authority at the moment of delivery, not at scheduling time:
    -- the couple may have unlinked since.
    if not exists (
      select 1
      from public.couple_members cm
      join public.couple_spaces c on c.id = cm.couple_id
      where cm.couple_id = m.couple_id and cm.user_id = m.author_id
        and cm.left_at is null and c.status = 'active'
    ) or app_private.active_member_count(m.couple_id) < 2 then
      update public.scheduled_messages
      set status = 'failed', failure_reason = 'not_paired', updated_at = now()
      where id = m.id;
      continue;
    end if;

    insert into public.notes (id, couple_id, author_id, body, style, photo_path, drawing_path, origin)
    values (m.id, m.couple_id, m.author_id, m.body, m.style, m.photo_path, m.drawing_path, 'scheduled')
    on conflict (id) do nothing;

    update public.scheduled_messages
    set status = 'delivered', delivered_at = now(), delivered_note_id = m.id, updated_at = now()
    where id = m.id;
    delivered := delivered + 1;
  end loop;
  return delivered;
end;
$$;

revoke all on function app_private.deliver_due_scheduled_messages(integer) from public;
