-- Foundation: private helper schema, profiles, audit trail.
--
-- Conventions used by every migration in this project:
--   * Tables in `public` are reachable through the Supabase API, so each one
--     has RLS enabled and its grants stated explicitly. Supabase grants ALL on
--     new public tables to `anon` and `authenticated` by default; we revoke
--     that and grant back only what a policy is written for.
--   * `app_private` holds helpers that policies and triggers call. It is not
--     an exposed API schema, so nothing in it can be invoked over HTTP.
--   * SECURITY DEFINER functions pin `search_path` to '' and qualify names.
--   * Expected failures are raised with a stable snake_case message that the
--     iOS client maps to a typed error. Messages never contain user content.

create schema if not exists app_private;
revoke all on schema app_private from public;
grant usage on schema app_private to authenticated, service_role;

create or replace function app_private.require_user()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not_authenticated';
  end if;
  return uid;
end;
$$;

create or replace function app_private.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default ''
    check (char_length(display_name) <= 40),
  avatar_path text,
  time_zone text not null default 'UTC',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
revoke all on table public.profiles from anon, authenticated;
grant select on table public.profiles to authenticated;
grant update (display_name, avatar_path, time_zone) on table public.profiles to authenticated;

create policy profiles_select_own on public.profiles
  for select to authenticated
  using (id = (select auth.uid()));

create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (
    id = (select auth.uid())
    and (avatar_path is null or avatar_path = (select auth.uid())::text || '/avatar.jpg')
  );

create or replace function app_private.profiles_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.display_name := btrim(new.display_name);
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = new.time_zone) then
    raise exception 'invalid_time_zone';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_validate
  before insert or update on public.profiles
  for each row execute function app_private.profiles_validate();

-- ---------------------------------------------------------------------------
-- audit_events: security-relevant lifecycle events. Never holds note content.
-- No API access at all; written by SECURITY DEFINER functions only.
-- ---------------------------------------------------------------------------

create table public.audit_events (
  id bigint generated always as identity primary key,
  user_id uuid,
  couple_id uuid,
  event text not null,
  created_at timestamptz not null default now()
);

create index audit_events_user_idx on public.audit_events (user_id, created_at desc);

alter table public.audit_events enable row level security;
revoke all on table public.audit_events from anon, authenticated;

create or replace function app_private.audit(p_user uuid, p_couple uuid, p_event text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.audit_events (user_id, couple_id, event) values (p_user, p_couple, p_event);
$$;

revoke all on function app_private.audit(uuid, uuid, text) from public;
