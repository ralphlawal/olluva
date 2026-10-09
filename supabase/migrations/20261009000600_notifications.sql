-- Push notification plumbing: device tokens, per-user preferences, and an
-- outbox drained by the `send-push` Edge Function.
--
-- The outbox stores identifiers only. Note text is read at send time, and only
-- when the recipient has opted in to previews.

create table public.notification_preferences (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  new_notes boolean not null default true,
  surprises boolean not null default true,
  important_dates boolean not null default true,
  pairing boolean not null default true,
  account boolean not null default true,
  -- Private by default: a lock screen shows "Alex left you a note", not the note.
  show_previews boolean not null default false,
  updated_at timestamptz not null default now()
);

create trigger notification_preferences_touch
  before update on public.notification_preferences
  for each row execute function app_private.touch_updated_at();

alter table public.notification_preferences enable row level security;
revoke all on table public.notification_preferences from anon, authenticated;
grant select on table public.notification_preferences to authenticated;
grant update (new_notes, surprises, important_dates, pairing, account, show_previews)
  on table public.notification_preferences to authenticated;
create policy notification_preferences_select_own on public.notification_preferences
  for select to authenticated using (user_id = (select auth.uid()));
create policy notification_preferences_update_own on public.notification_preferences
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- Every new auth user gets a profile and default preferences.
create or replace function app_private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, left(btrim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), 40))
  on conflict (id) do nothing;
  insert into public.notification_preferences (user_id) values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app_private.handle_new_user();

-- ---------------------------------------------------------------------------
-- device_tokens
-- ---------------------------------------------------------------------------

create table public.device_tokens (
  token text not null check (token ~ '^[0-9a-f]{64,200}$'),
  environment text not null check (environment in ('sandbox', 'production')),
  user_id uuid not null references public.profiles (id) on delete cascade,
  updated_at timestamptz not null default now(),
  primary key (token, environment)
);

create index device_tokens_by_user on public.device_tokens (user_id);

-- A token identifies a device for delivery and nothing more. It is never an
-- input to any authorisation decision, and it is not readable through the API.
alter table public.device_tokens enable row level security;
revoke all on table public.device_tokens from anon, authenticated;

create or replace function public.register_device_token(p_token text, p_environment text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
begin
  -- A device has one signed-in account at a time: registering moves the token.
  insert into public.device_tokens (token, environment, user_id)
  values (lower(p_token), p_environment, uid)
  on conflict (token, environment) do update set user_id = excluded.user_id, updated_at = now();

  -- Keep the list bounded per account.
  delete from public.device_tokens
  where user_id = uid
    and (token, environment) not in (
      select token, environment from public.device_tokens
      where user_id = uid order by updated_at desc limit 10
    );
end;
$$;

-- Called on sign-out so a signed-out phone stops receiving this account's pushes.
create or replace function public.unregister_device_token(p_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
begin
  delete from public.device_tokens where token = lower(p_token) and user_id = uid;
end;
$$;

-- ---------------------------------------------------------------------------
-- notification_outbox
-- ---------------------------------------------------------------------------

create table public.notification_outbox (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  category text not null
    check (category in ('new_note', 'surprise', 'important_date', 'pairing', 'account')),
  payload jsonb not null default '{}'::jsonb,
  -- Makes enqueueing idempotent: the same event can never notify twice.
  dedupe_key text not null unique,
  status text not null default 'pending'
    check (status in ('pending', 'sending', 'sent', 'failed', 'skipped')),
  attempts integer not null default 0,
  claimed_at timestamptz,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

create index notification_outbox_pending on public.notification_outbox (id)
  where status in ('pending', 'sending');

alter table public.notification_outbox enable row level security;
revoke all on table public.notification_outbox from anon, authenticated;

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

create or replace function app_private.notes_notify_partner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  recipient uuid;
begin
  for recipient in
    select user_id from public.couple_members
    where couple_id = new.couple_id and left_at is null
      and user_id is distinct from new.author_id
  loop
    perform app_private.enqueue_notification(
      recipient,
      case when new.origin = 'scheduled' then 'surprise' else 'new_note' end,
      jsonb_build_object('note_id', new.id, 'author_id', new.author_id),
      'note:' || new.id::text || ':' || recipient::text
    );
  end loop;
  return new;
end;
$$;

create trigger notes_notify_partner
  after insert on public.notes
  for each row execute function app_private.notes_notify_partner();

create or replace function app_private.invitations_notify_creator()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status in ('accepted', 'declined') and old.status = 'pending' then
    perform app_private.enqueue_notification(
      new.created_by, 'pairing',
      jsonb_build_object('event', new.status, 'partner_id', new.responded_by),
      'invitation:' || new.id::text || ':' || new.status
    );
  end if;
  return new;
end;
$$;

create trigger invitations_notify_creator
  after update on public.invitations
  for each row execute function app_private.invitations_notify_creator();

create or replace function app_private.couple_members_notify_left()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Tell the partner who did not initiate the unlink. auth.uid() is the leaver.
  if old.left_at is null and new.left_at is not null
     and new.user_id is distinct from auth.uid()
     and exists (select 1 from public.couple_spaces where id = new.couple_id and paired_at is not null) then
    perform app_private.enqueue_notification(
      new.user_id, 'account',
      jsonb_build_object('event', 'space_ended'),
      'space_ended:' || new.couple_id::text || ':' || new.user_id::text
    );
  end if;
  return new;
end;
$$;

create trigger couple_members_notify_left
  after update on public.couple_members
  for each row execute function app_private.couple_members_notify_left();

-- Hourly. Sends each reminder once, at or after 09:00 in the recipient's own
-- time zone, on the day it falls due for them.
create or replace function app_private.enqueue_date_reminders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  queued integer := 0;
begin
  for r in
    select d.id as date_id, d.title, d.kind, m.user_id, occ.next_on, (occ.next_on - loc.today) as days_left
    from public.important_dates d
    join public.couple_spaces c on c.id = d.couple_id and c.status = 'active'
    join public.couple_members m on m.couple_id = d.couple_id and m.left_at is null
    join public.profiles p on p.id = m.user_id
    cross join lateral (
      select (now() at time zone p.time_zone)::date as today,
             extract(hour from now() at time zone p.time_zone)::integer as hour
    ) loc
    cross join lateral (
      select app_private.next_occurrence(d.starts_on, d.recurrence, loc.today) as next_on
    ) occ
    where d.notify
      and (d.visibility = 'shared' or d.created_by = m.user_id)
      and loc.hour >= 9
      and occ.next_on is not null
      and (occ.next_on - loc.today)::smallint = any (d.remind_days_before)
  loop
    perform app_private.enqueue_notification(
      r.user_id, 'important_date',
      jsonb_build_object('date_id', r.date_id, 'days_left', r.days_left),
      'date:' || r.date_id::text || ':' || r.user_id::text || ':' || r.next_on::text || ':' || r.days_left::text
    );
    queued := queued + 1;
  end loop;
  return queued;
end;
$$;

revoke all on function app_private.enqueue_date_reminders() from public;

-- ---------------------------------------------------------------------------
-- Worker interface for the send-push Edge Function (service role only).
-- ---------------------------------------------------------------------------

create or replace function public.claim_notifications(p_limit integer default 50)
returns table (
  id bigint,
  user_id uuid,
  category text,
  payload jsonb,
  tokens jsonb,
  sender_name text,
  preview text,
  date_title text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  with picked as (
    select o.id
    from public.notification_outbox o
    where o.attempts < 5
      and o.created_at > now() - interval '24 hours'
      and (
        o.status = 'pending'
        -- A worker that died mid-send releases its claim after five minutes.
        or (o.status = 'sending' and o.claimed_at < now() - interval '5 minutes')
      )
    order by o.id
    limit greatest(1, least(p_limit, 200))
    for update skip locked
  ),
  claimed as (
    update public.notification_outbox o
    set status = 'sending', attempts = o.attempts + 1, claimed_at = now()
    from picked
    where o.id = picked.id
    returning o.id, o.user_id, o.category, o.payload
  )
  select
    c.id,
    c.user_id,
    c.category,
    c.payload,
    coalesce((
      select jsonb_agg(jsonb_build_object('token', t.token, 'environment', t.environment))
      from public.device_tokens t where t.user_id = c.user_id
    ), '[]'::jsonb),
    coalesce((
      select nullif(pr.display_name, '') from public.profiles pr
      where pr.id = coalesce(
        nullif(c.payload ->> 'author_id', '')::uuid,
        nullif(c.payload ->> 'partner_id', '')::uuid
      )
    ), ''),
    case
      when c.category in ('new_note', 'surprise') and prefs.show_previews then (
        select left(n.body, 140) from public.notes n
        where n.id = nullif(c.payload ->> 'note_id', '')::uuid and n.deleted_at is null
      )
      else null
    end,
    case
      when c.category = 'important_date' then (
        select d.title from public.important_dates d
        where d.id = nullif(c.payload ->> 'date_id', '')::uuid
      )
      else null
    end
  from claimed c
  left join public.notification_preferences prefs on prefs.user_id = c.user_id;
end;
$$;

create or replace function public.complete_notification(
  p_id bigint, p_status text, p_invalid_tokens text[] default '{}'
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_status not in ('sent', 'failed', 'skipped', 'pending') then
    raise exception 'invalid_status';
  end if;
  update public.notification_outbox
  set status = p_status, sent_at = case when p_status = 'sent' then now() else sent_at end
  where id = p_id;
  -- APNs told us these tokens are dead; stop sending to them.
  if coalesce(array_length(p_invalid_tokens, 1), 0) > 0 then
    delete from public.device_tokens where token = any (p_invalid_tokens);
  end if;
end;
$$;
