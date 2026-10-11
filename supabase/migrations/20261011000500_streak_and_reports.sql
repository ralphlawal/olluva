-- Two small additions.
--
-- 1. The streak: how many days running both people in a space have written.
--    Days are counted in the caller's own time zone, so "today" means their
--    today. A day counts when each of them wrote at least once. The run is
--    counted back from today if today already counts, otherwise from
--    yesterday, so it is not shown as broken during a day that is not over.
--
-- 2. Reporting a note. Someone who receives something they should not have
--    can flag it. The report is a row for the operator to read; it changes
--    nothing for either person and the author is not told.

create or replace function public.get_streak()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  space uuid;
  zone text;
  today date;
  cursor_day date;
  run integer := 0;
  me_today boolean := false;
  partner_today boolean := false;
begin
  select m.couple_id into space
  from public.couple_members m
  join public.couple_spaces c on c.id = m.couple_id and c.status = 'active'
  where m.user_id = uid and m.left_at is null;
  if space is null then
    return jsonb_build_object('days', 0, 'me_today', false, 'partner_today', false);
  end if;

  select time_zone into zone from public.profiles where id = uid;
  if zone is null or not exists (select 1 from pg_catalog.pg_timezone_names where name = zone) then
    zone := 'UTC';
  end if;
  today := (now() at time zone zone)::date;

  select coalesce(bool_or(n.author_id = uid), false), coalesce(bool_or(n.author_id <> uid), false)
  into me_today, partner_today
  from public.notes n
  where n.couple_id = space and n.author_id is not null
    and n.created_at >= (today::timestamp at time zone zone)
    and n.created_at < ((today + 1)::timestamp at time zone zone);

  cursor_day := case when me_today and partner_today then today else today - 1 end;
  -- Each step looks at one day's notes through the (couple, time) index.
  while run < 1100 and (
    select coalesce(bool_or(n.author_id = uid) and bool_or(n.author_id <> uid), false)
    from public.notes n
    where n.couple_id = space and n.author_id is not null
      and n.created_at >= (cursor_day::timestamp at time zone zone)
      and n.created_at < ((cursor_day + 1)::timestamp at time zone zone)
  ) loop
    run := run + 1;
    cursor_day := cursor_day - 1;
  end loop;

  return jsonb_build_object('days', run, 'me_today', me_today, 'partner_today', partner_today);
end;
$$;

create table public.note_reports (
  id uuid primary key default gen_random_uuid(),
  note_id uuid not null,
  couple_id uuid not null,
  reporter_id uuid references public.profiles (id) on delete set null,
  author_id uuid,
  -- What was reported, as it stood then: the note itself may be edited or
  -- deleted afterwards.
  body text not null default '',
  photo_path text,
  drawing_path text,
  created_at timestamptz not null default now(),
  unique (note_id, reporter_id)
);

alter table public.note_reports enable row level security;
revoke all on table public.note_reports from anon, authenticated;

create or replace function public.report_note(p_note_id uuid)
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
  if n.id is null or not app_private.is_active_member(n.couple_id) then
    raise exception 'note_not_found';
  end if;
  if n.author_id is not distinct from uid then
    raise exception 'not_allowed';
  end if;

  insert into public.note_reports (note_id, couple_id, reporter_id, author_id, body, photo_path, drawing_path)
  values (n.id, n.couple_id, uid, n.author_id, n.body, n.photo_path, n.drawing_path)
  on conflict (note_id, reporter_id) do nothing;
  perform app_private.audit(uid, n.couple_id, 'note_reported');
end;
$$;

revoke all on function public.get_streak() from public, anon;
revoke all on function public.report_note(uuid) from public, anon;
grant execute on function public.get_streak() to authenticated;
grant execute on function public.report_note(uuid) to authenticated;
