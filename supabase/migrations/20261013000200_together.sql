-- Olluva Together: one question a day, answered separately, revealed together.
--
-- The rule this file exists to enforce: nobody can read their partner's answer
-- until both have answered and one of them has chosen to reveal. That is a
-- property of the server, not of what the app chooses to show.
--
-- How it is enforced:
--   * Answers live in `together_answers`, on which the API roles hold no
--     privileges at all. There is no policy to get wrong, because there is no
--     grant for a policy to qualify.
--   * Every read and write goes through the functions below, which decide
--     what to return from the caller's identity and the moment's state.
--   * `together_moments` is readable by the couple (it drives live updates) and
--     holds no answer text: only which question, how many have answered, and
--     whether it has been revealed.
--
-- The day. A couple has one moment per calendar day. The day is reckoned in a
-- time zone fixed for the couple the first time either of them opens the
-- feature (that person's zone at the time), so both partners always agree on
-- which day it is, wherever each of them happens to be.
--
-- Missed days. A day both people did not finish is simply left behind: it is
-- not shown in the history, nothing chases it, and whatever one person wrote
-- stays private to them. A day both answered but never revealed stays ready
-- to reveal for as long as the space exists.

-- ---------------------------------------------------------------------------
-- Questions
-- ---------------------------------------------------------------------------

create table public.together_questions (
  id integer primary key,
  category text not null
    check (category in ('appreciation', 'memories', 'everyday', 'future', 'understanding', 'playful')),
  body text not null check (char_length(body) between 10 and 80),
  is_active boolean not null default true
);

alter table public.together_questions enable row level security;
revoke all on table public.together_questions from anon, authenticated;

insert into public.together_questions (id, category, body) values
  (1, 'appreciation', 'What’s one little thing I did recently that made you happy?'),
  (2, 'memories', 'What’s a memory of us that always makes you smile?'),
  (3, 'everyday', 'What’s one small thing we could do to make this week better?'),
  (4, 'future', 'What’s something new you’d love us to try together?'),
  (5, 'understanding', 'What helps you most when you’ve had a hard day?'),
  (6, 'playful', 'If we had a whole day with no plans, what would we do?'),
  (7, 'appreciation', 'What’s something about us that you’re grateful for?'),
  (8, 'memories', 'What do you remember about the day we met?'),
  (9, 'everyday', 'What was the best part of your day today?'),
  (10, 'future', 'Where would you like us to go next, near or far?'),
  (11, 'understanding', 'What makes you feel most loved?'),
  (12, 'playful', 'What would we call a café we opened together?'),
  (13, 'appreciation', 'What do I do that makes an ordinary day better?'),
  (14, 'memories', 'When did you feel especially close to me?'),
  (15, 'everyday', 'What’s been on your mind lately?'),
  (16, 'future', 'What’s something you’d like us to learn together?'),
  (17, 'understanding', 'What’s something about you that you’d like me to understand better?'),
  (18, 'playful', 'Which film character is the most like me?'),
  (19, 'appreciation', 'When did you last feel proud of me?'),
  (20, 'memories', 'What’s a trip or outing of ours you’d happily repeat?'),
  (21, 'everyday', 'What would make tomorrow morning a little easier for you?'),
  (22, 'future', 'What’s a tradition you’d like us to start?'),
  (23, 'understanding', 'How do you like to be cheered up?'),
  (24, 'playful', 'What’s the silliest thing you love about me?'),
  (25, 'appreciation', 'What’s a habit of mine you’d miss if it stopped?'),
  (26, 'memories', 'What’s the funniest thing that has happened to us?'),
  (27, 'everyday', 'What’s something you’re looking forward to this week?'),
  (28, 'future', 'What does a really good year look like for us?'),
  (29, 'understanding', 'What’s something you find hard to ask for?'),
  (30, 'playful', 'If we swapped lives for a day, what would you do first?'),
  (31, 'appreciation', 'What’s something I’m good at that I don’t give myself credit for?'),
  (32, 'memories', 'What’s a meal we shared that you still think about?'),
  (33, 'everyday', 'What’s a part of our routine you really like?'),
  (34, 'future', 'What’s a small goal we could work towards together?'),
  (35, 'understanding', 'When do you feel most like yourself?'),
  (36, 'playful', 'What would be our team name on a quiz show?'),
  (37, 'appreciation', 'What’s a small kindness of mine you still remember?'),
  (38, 'memories', 'What’s a moment from our first year you’d love to relive?'),
  (39, 'everyday', 'What’s been tiring you out lately, and how can I help?'),
  (40, 'future', 'What’s a place you’d love to show me one day?'),
  (41, 'understanding', 'What’s a worry I could help you carry?'),
  (42, 'playful', 'What snack best describes each of us?'),
  (43, 'appreciation', 'What’s one way I make you feel looked after?'),
  (44, 'memories', 'What’s a photo of us you love, and why that one?'),
  (45, 'everyday', 'What’s a little thing you’d like us to do more often?'),
  (46, 'future', 'What’s something you’re hoping for in the next few months?'),
  (47, 'understanding', 'What does a restful day mean to you?'),
  (48, 'playful', 'If we could have any pet, however unlikely, what would it be?'),
  (49, 'appreciation', 'What’s something you’ve learned from me?'),
  (50, 'memories', 'When did you first think this might be something special?'),
  (51, 'everyday', 'What would your ideal evening in with me look like?'),
  (52, 'future', 'What would you like our weekends to feel like?'),
  (53, 'understanding', 'What’s something you need more of right now?'),
  (54, 'playful', 'What’s a talent you secretly wish you had?'),
  (55, 'appreciation', 'What’s your favourite thing about how we are together?'),
  (56, 'memories', 'What’s a small, ordinary moment with me you’ve never forgotten?'),
  (57, 'everyday', 'What’s something you’d like to hand over to me for a week?'),
  (58, 'future', 'What’s a dream of yours I could help with?'),
  (59, 'understanding', 'What’s a compliment that really stays with you?'),
  (60, 'playful', 'What would be the title of a film about us?'),
  (61, 'appreciation', 'When did I last make you laugh properly?'),
  (62, 'memories', 'What’s the best surprise we’ve given each other?'),
  (63, 'everyday', 'What made you smile today?'),
  (64, 'future', 'What’s one thing you’d love us to build or make together?'),
  (65, 'understanding', 'What’s the best way for me to say sorry?'),
  (66, 'playful', 'What’s the best worst joke you know?'),
  (67, 'appreciation', 'What’s something I do that makes you feel at home?'),
  (68, 'memories', 'What’s a song that takes you straight back to a moment with me?'),
  (69, 'everyday', 'What’s something you wish we had more time for?'),
  (70, 'future', 'What would you like us to celebrate next?'),
  (71, 'understanding', 'What’s something you value that people don’t always notice?'),
  (72, 'playful', 'If we won a holiday tomorrow, where are we going?');

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.together_settings (
  couple_id uuid primary key references public.couple_spaces (id) on delete cascade,
  time_zone text not null,
  created_at timestamptz not null default now()
);

alter table public.together_settings enable row level security;
revoke all on table public.together_settings from anon, authenticated;

create table public.together_moments (
  id uuid primary key default gen_random_uuid(),
  couple_id uuid not null references public.couple_spaces (id) on delete cascade,
  day date not null,
  question_id integer not null references public.together_questions (id),
  -- How many of the two have answered. Not the answers: this row is readable
  -- by the couple and carries live updates.
  answer_count smallint not null default 0 check (answer_count between 0 and 2),
  ready_at timestamptz,
  revealed_at timestamptz,
  revealed_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (couple_id, day)
);

create index together_moments_history on public.together_moments (couple_id, day desc);

alter table public.together_moments enable row level security;
revoke all on table public.together_moments from anon, authenticated;
grant select on table public.together_moments to authenticated;

create policy together_moments_select_member on public.together_moments
  for select to authenticated
  using (app_private.is_active_member(couple_id));

create table public.together_answers (
  moment_id uuid not null references public.together_moments (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (moment_id, user_id)
);

-- No grants and no policies, deliberately. See the header.
alter table public.together_answers enable row level security;
revoke all on table public.together_answers from anon, authenticated;

-- A completed moment can be kept in the scrapbook. One memory per moment,
-- whoever saves it; removing the memory leaves the moment and its answers.
alter table public.memories
  add column together_moment_id uuid references public.together_moments (id) on delete cascade;
create unique index memories_one_per_together_moment
  on public.memories (together_moment_id) where together_moment_id is not null;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- The caller's space, if they are in one with a partner.
create or replace function app_private.together_couple(p_user uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.couple_id
  from public.couple_members m
  join public.couple_spaces c on c.id = m.couple_id and c.status = 'active'
  where m.user_id = p_user and m.left_at is null
    and app_private.active_member_count(m.couple_id) = 2
  limit 1;
$$;

-- Today's date for a couple, fixing its time zone on first use.
create or replace function app_private.together_day(p_couple uuid, p_user uuid)
returns date
language plpgsql
security definer
set search_path = ''
as $$
declare
  zone text;
begin
  select time_zone into zone from public.together_settings where couple_id = p_couple;
  if zone is null then
    select time_zone into zone from public.profiles where id = p_user;
    if zone is null or not exists (select 1 from pg_catalog.pg_timezone_names where name = zone) then
      zone := 'UTC';
    end if;
    insert into public.together_settings (couple_id, time_zone) values (p_couple, zone)
    on conflict (couple_id) do nothing;
    select time_zone into zone from public.together_settings where couple_id = p_couple;
  end if;
  return (now() at time zone zone)::date;
end;
$$;

-- Which question a couple gets on a day. Deterministic for a given history:
-- nothing asked in their last sixty moments, a different category from the
-- previous one where possible, and otherwise an order fixed by couple and day.
create or replace function app_private.together_pick_question(p_couple uuid, p_day date)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  with recent as (
    select question_id, day from public.together_moments
    where couple_id = p_couple and day < p_day
    order by day desc limit 60
  ),
  previous as (
    select q.category from recent r join public.together_questions q on q.id = r.question_id
    order by r.day desc limit 1
  )
  select q.id
  from public.together_questions q
  where q.is_active
  order by
    (q.id in (select question_id from recent)),
    (q.category = (select category from previous)) nulls first,
    md5(p_couple::text || ':' || p_day::text || ':' || q.id::text)
  limit 1;
$$;

-- What one person is allowed to know about a moment. The single place the
-- reveal rule is applied to outgoing data.
create or replace function app_private.together_state(p_moment public.together_moments, p_user uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  mine public.together_answers;
  theirs public.together_answers;
  question public.together_questions;
  is_revealed boolean := p_moment.revealed_at is not null;
  status text;
begin
  select * into mine from public.together_answers where moment_id = p_moment.id and user_id = p_user;
  select * into theirs from public.together_answers where moment_id = p_moment.id and user_id <> p_user limit 1;
  select * into question from public.together_questions where id = p_moment.question_id;

  status := case
    when is_revealed then 'revealed'
    when mine.user_id is not null and theirs.user_id is not null then 'ready'
    when mine.user_id is not null then 'waiting'
    else 'open'
  end;

  return jsonb_build_object(
    'id', p_moment.id,
    'day', p_moment.day,
    'question', jsonb_build_object('id', question.id, 'category', question.category, 'body', question.body),
    'status', status,
    'my_answer', mine.body,
    'partner_answered', theirs.user_id is not null,
    -- The whole feature rests on this line.
    'partner_answer', case when is_revealed then theirs.body else null end,
    'revealed_at', p_moment.revealed_at,
    'memory_id', (select id from public.memories where together_moment_id = p_moment.id)
  );
end;
$$;

revoke all on function app_private.together_couple(uuid) from public, anon, authenticated;
revoke all on function app_private.together_day(uuid, uuid) from public, anon, authenticated;
revoke all on function app_private.together_pick_question(uuid, date) from public, anon, authenticated;
revoke all on function app_private.together_state(public.together_moments, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------------

alter table public.notification_preferences
  add column together boolean not null default true,
  add column together_daily boolean not null default true;
grant update (together, together_daily) on table public.notification_preferences to authenticated;

alter table public.notification_outbox drop constraint notification_outbox_category_check;
alter table public.notification_outbox add constraint notification_outbox_category_check
  check (category in ('new_note', 'surprise', 'important_date', 'pairing', 'account', 'sync', 'together'));

create or replace function app_private.enqueue_notification(
  p_user uuid, p_category text, p_payload jsonb, p_dedupe_key text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  prefs public.notification_preferences;
  wanted boolean;
begin
  select * into prefs from public.notification_preferences where user_id = p_user;
  wanted := case p_category
    when 'new_note' then coalesce(prefs.new_notes, true)
    when 'surprise' then coalesce(prefs.surprises, true)
    when 'important_date' then coalesce(prefs.important_dates, true)
    when 'pairing' then coalesce(prefs.pairing, true)
    when 'account' then coalesce(prefs.account, true)
    when 'together' then
      case when p_payload ->> 'event' = 'new'
        then coalesce(prefs.together_daily, true)
        else coalesce(prefs.together, true)
      end
    else false
  end;
  if not wanted then
    return;
  end if;
  insert into public.notification_outbox (user_id, category, payload, dedupe_key)
  values (p_user, p_category, p_payload, p_dedupe_key)
  on conflict (dedupe_key) do nothing;
end;
$$;

revoke all on function app_private.enqueue_notification(uuid, text, jsonb, text) from public;

-- ---------------------------------------------------------------------------
-- The API
-- ---------------------------------------------------------------------------

-- Today's moment for the caller's couple, created on first asking.
create or replace function public.together_today()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  couple uuid := app_private.together_couple(uid);
  today date;
  m public.together_moments;
begin
  if couple is null then
    return jsonb_build_object('status', 'unpaired');
  end if;
  today := app_private.together_day(couple, uid);

  -- Both partners may arrive at the same instant. The unique key lets one of
  -- them create the row; the other finds it. Either way they pick the same
  -- question, because the choice depends only on the couple, the day and
  -- what came before.
  insert into public.together_moments (couple_id, day, question_id)
  values (couple, today, app_private.together_pick_question(couple, today))
  on conflict (couple_id, day) do nothing;

  select * into m from public.together_moments where couple_id = couple and day = today;
  return app_private.together_state(m, uid);
end;
$$;

-- Submits or edits the caller's own answer.
create or replace function public.together_submit(p_moment uuid, p_body text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  couple uuid := app_private.together_couple(uid);
  m public.together_moments;
  cleaned text := btrim(coalesce(p_body, ''));
  had_answer boolean;
  answers integer;
  partner uuid;
begin
  -- The row lock serialises the two partners, and a reveal, on this moment.
  select * into m from public.together_moments where id = p_moment for update;
  if m.id is null or couple is null or m.couple_id <> couple then
    raise exception 'moment_not_found';
  end if;
  if m.revealed_at is not null then
    raise exception 'already_revealed';
  end if;
  if char_length(cleaned) < 1 or char_length(cleaned) > 500 then
    raise exception 'invalid_answer';
  end if;

  had_answer := exists (select 1 from public.together_answers where moment_id = m.id and user_id = uid);
  answers := (select count(*) from public.together_answers where moment_id = m.id);
  -- A day that has passed is closed, unless both answers are already in and
  -- it is only waiting to be revealed (then the caller may still edit theirs).
  if m.day <> app_private.together_day(couple, uid) and not (had_answer and answers = 2) then
    raise exception 'moment_closed';
  end if;

  -- The key includes the caller, so this can only ever touch their own row.
  insert into public.together_answers (moment_id, user_id, body) values (m.id, uid, cleaned)
  on conflict (moment_id, user_id) do update set body = excluded.body, updated_at = now();

  answers := (select count(*) from public.together_answers where moment_id = m.id);
  update public.together_moments set
    answer_count = answers,
    ready_at = case when answers = 2 then coalesce(ready_at, now()) else ready_at end,
    updated_at = now()
  where id = m.id
  returning * into m;

  -- Told once, on a first answer, never on an edit, and never what was said.
  if not had_answer then
    select user_id into partner from public.couple_members
    where couple_id = couple and left_at is null and user_id <> uid;
    if partner is not null then
      perform app_private.enqueue_notification(
        partner, 'together',
        jsonb_build_object('event', case when answers = 2 then 'ready' else 'answered' end, 'partner_id', uid, 'moment_id', m.id),
        'together:' || case when answers = 2 then 'ready' else 'answered' end || ':' || m.id::text || ':' || partner::text
      );
    end if;
  end if;

  return app_private.together_state(m, uid);
end;
$$;

-- Reveals a moment for both people. Allowed only once both have answered;
-- safe to call twice, or from both phones at once.
create or replace function public.together_reveal(p_moment uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  couple uuid := app_private.together_couple(uid);
  m public.together_moments;
begin
  select * into m from public.together_moments where id = p_moment for update;
  if m.id is null or couple is null or m.couple_id <> couple then
    raise exception 'moment_not_found';
  end if;
  if (select count(*) from public.together_answers where moment_id = m.id) < 2 then
    raise exception 'not_ready';
  end if;
  if m.revealed_at is null then
    update public.together_moments
    set revealed_at = now(), revealed_by = uid, updated_at = now()
    where id = m.id
    returning * into m;
    perform app_private.audit(uid, couple, 'together_revealed');
  end if;
  return app_private.together_state(m, uid);
end;
$$;

create or replace function public.together_moment(p_moment uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  couple uuid := app_private.together_couple(uid);
  m public.together_moments;
begin
  select * into m from public.together_moments where id = p_moment;
  if m.id is null or couple is null or m.couple_id <> couple then
    raise exception 'moment_not_found';
  end if;
  return app_private.together_state(m, uid);
end;
$$;

-- Moments both people answered, newest first: revealed ones, and any still
-- waiting to be revealed.
create or replace function public.together_history(p_before date default null, p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  couple uuid := app_private.together_couple(uid);
begin
  if couple is null then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(app_private.together_state(m, uid) order by m.day desc)
    from (
      select * from public.together_moments
      where couple_id = couple
        and (revealed_at is not null or answer_count = 2)
        and (p_before is null or day < p_before)
      order by day desc
      limit least(greatest(coalesce(p_limit, 20), 1), 50)
    ) m
  ), '[]'::jsonb);
end;
$$;

-- Keeps a revealed moment in the scrapbook. One memory however many times,
-- and by whichever of them, it is saved.
create or replace function public.together_save_memory(p_moment uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  couple uuid := app_private.together_couple(uid);
  m public.together_moments;
  memory_id uuid;
begin
  select * into m from public.together_moments where id = p_moment for update;
  if m.id is null or couple is null or m.couple_id <> couple then
    raise exception 'moment_not_found';
  end if;
  if m.revealed_at is null then
    raise exception 'not_revealed';
  end if;

  select id into memory_id from public.memories where together_moment_id = m.id;
  if memory_id is not null then
    return memory_id;
  end if;

  insert into public.memories (couple_id, created_by, kind, title, caption, occurred_on, together_moment_id)
  values (
    couple, uid, 'moment',
    (select body from public.together_questions where id = m.question_id),
    'A question you both answered.', m.day, m.id
  )
  returning id into memory_id;
  return memory_id;
end;
$$;

create or replace function public.together_unsave_memory(p_moment uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  couple uuid := app_private.together_couple(uid);
begin
  if couple is null or not exists (
    select 1 from public.together_moments where id = p_moment and couple_id = couple
  ) then
    raise exception 'moment_not_found';
  end if;
  delete from public.memories where together_moment_id = p_moment and couple_id = couple;
end;
$$;

revoke all on function
  public.together_today(),
  public.together_submit(uuid, text),
  public.together_reveal(uuid),
  public.together_moment(uuid),
  public.together_history(date, integer),
  public.together_save_memory(uuid),
  public.together_unsave_memory(uuid)
from public, anon;

grant execute on function
  public.together_today(),
  public.together_submit(uuid, text),
  public.together_reveal(uuid),
  public.together_moment(uuid),
  public.together_history(date, integer),
  public.together_save_memory(uuid),
  public.together_unsave_memory(uuid)
to authenticated;

-- ---------------------------------------------------------------------------
-- The daily nudge
-- ---------------------------------------------------------------------------
-- At about nine in the couple's morning, one notification each, and only for
-- couples who have answered a question in the last week: someone who has
-- stopped using this is not chased, and a missed day creates no backlog.

create or replace function app_private.together_announce()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  target record;
  queued integer := 0;
begin
  for target in
    select s.couple_id, m.user_id, (now() at time zone s.time_zone)::date as today
    from public.together_settings s
    join public.couple_spaces c on c.id = s.couple_id and c.status = 'active'
    join public.couple_members m on m.couple_id = s.couple_id and m.left_at is null
    where extract(hour from now() at time zone s.time_zone) = 9
      and app_private.active_member_count(s.couple_id) = 2
      and exists (
        select 1 from public.together_moments recent
        where recent.couple_id = s.couple_id and recent.answer_count > 0
          and recent.day >= (now() at time zone s.time_zone)::date - 7
      )
  loop
    if not exists (
      select 1
      from public.together_moments tm
      join public.together_answers a on a.moment_id = tm.id and a.user_id = target.user_id
      where tm.couple_id = target.couple_id and tm.day = target.today
    ) then
      perform app_private.enqueue_notification(
        target.user_id, 'together', jsonb_build_object('event', 'new'),
        'together:new:' || target.user_id::text || ':' || target.today::text
      );
      queued := queued + 1;
    end if;
  end loop;
  return queued;
end;
$$;

revoke all on function app_private.together_announce() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Export, live updates, schedule
-- ---------------------------------------------------------------------------

-- "Export my data" gains what the person wrote here, and only that.
alter function public.export_my_data() rename to export_my_data_before_together;
alter function public.export_my_data_before_together() set schema app_private;
revoke all on function app_private.export_my_data_before_together() from public, anon, authenticated;

create or replace function public.export_my_data()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
begin
  return app_private.export_my_data_before_together() || jsonb_build_object(
    'together_answers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'day', m.day, 'question', q.body, 'answer', a.body,
        'created_at', a.created_at, 'updated_at', a.updated_at
      ) order by m.day)
      from public.together_answers a
      join public.together_moments m on m.id = a.moment_id
      join public.together_questions q on q.id = m.question_id
      where a.user_id = uid
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.export_my_data() from public, anon;
grant execute on function public.export_my_data() to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'together_moments'
     ) then
    alter publication supabase_realtime add table public.together_moments;
  end if;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('together-announce', '5 * * * *', $job$select app_private.together_announce()$job$);
  end if;
end;
$$;
