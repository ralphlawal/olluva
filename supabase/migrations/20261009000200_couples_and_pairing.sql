-- Couple spaces, membership, invitations, blocks.
--
-- Product rules enforced here (not in the client):
--   * A user belongs to at most one active couple space.
--   * A couple space has at most two active members.
--   * Membership only ever changes through the functions in this file.
--   * Invitation codes are stored hashed, expire, are single-use and revocable,
--     and redemption attempts are rate limited per account.

create table public.themes (
  id text primary key,
  is_premium boolean not null default false,
  sort_order integer not null default 0
);

alter table public.themes enable row level security;
revoke all on table public.themes from anon, authenticated;
grant select on table public.themes to authenticated;
create policy themes_read on public.themes for select to authenticated using (true);

insert into public.themes (id, is_premium, sort_order) values
  ('paper', false, 0),
  ('plum', false, 1),
  ('linen', true, 2),
  ('dusk', true, 3),
  ('sage', true, 4),
  ('ink', true, 5);

create table public.couple_spaces (
  id uuid primary key default gen_random_uuid(),
  created_by uuid references public.profiles (id) on delete set null,
  status text not null default 'active' check (status in ('active', 'ended')),
  theme_id text not null default 'paper' references public.themes (id),
  accent_hex text check (accent_hex ~ '^#[0-9A-Fa-f]{6}$'),
  paired_at timestamptz,
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger couple_spaces_touch
  before update on public.couple_spaces
  for each row execute function app_private.touch_updated_at();

create table public.couple_members (
  couple_id uuid not null references public.couple_spaces (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  primary key (couple_id, user_id)
);

-- The single-couple rule. Everything else is a convenience on top of this index.
create unique index couple_members_one_active_per_user
  on public.couple_members (user_id) where left_at is null;

create index couple_members_active_by_couple
  on public.couple_members (couple_id) where left_at is null;

-- ---------------------------------------------------------------------------
-- Membership helpers used by RLS policies across the schema.
-- SECURITY DEFINER so policies on couple_members do not recurse into themselves.
-- ---------------------------------------------------------------------------

create or replace function app_private.is_active_member(p_couple uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.couple_members m
    join public.couple_spaces c on c.id = m.couple_id
    where m.couple_id = p_couple
      and m.user_id = auth.uid()
      and m.left_at is null
      and c.status = 'active'
  );
$$;

create or replace function app_private.current_couple_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.couple_id
  from public.couple_members m
  join public.couple_spaces c on c.id = m.couple_id
  where m.user_id = auth.uid() and m.left_at is null and c.status = 'active';
$$;

create or replace function app_private.is_partner(p_other uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.couple_members mine
    join public.couple_members theirs on theirs.couple_id = mine.couple_id
    join public.couple_spaces c on c.id = mine.couple_id
    where mine.user_id = auth.uid()
      and theirs.user_id = p_other
      and theirs.user_id <> mine.user_id
      and mine.left_at is null
      and theirs.left_at is null
      and c.status = 'active'
  );
$$;

create or replace function app_private.active_member_count(p_couple uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer from public.couple_members
  where couple_id = p_couple and left_at is null;
$$;

alter table public.couple_spaces enable row level security;
revoke all on table public.couple_spaces from anon, authenticated;
grant select on table public.couple_spaces to authenticated;
create policy couple_spaces_select_member on public.couple_spaces
  for select to authenticated
  using (app_private.is_active_member(id));

alter table public.couple_members enable row level security;
revoke all on table public.couple_members from anon, authenticated;
grant select on table public.couple_members to authenticated;
create policy couple_members_select_member on public.couple_members
  for select to authenticated
  using (left_at is null and app_private.is_active_member(couple_id));

-- A partner may read the other partner's profile, and nobody else's.
create policy profiles_select_partner on public.profiles
  for select to authenticated
  using (app_private.is_partner(id));

-- ---------------------------------------------------------------------------
-- blocks: a user can refuse any future pairing with a specific account.
-- ---------------------------------------------------------------------------

create table public.blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

alter table public.blocks enable row level security;
revoke all on table public.blocks from anon, authenticated;
grant select, delete on table public.blocks to authenticated;
create policy blocks_select_own on public.blocks
  for select to authenticated using (blocker_id = (select auth.uid()));
create policy blocks_delete_own on public.blocks
  for delete to authenticated using (blocker_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- invitations
-- ---------------------------------------------------------------------------

create table public.invitations (
  id uuid primary key default gen_random_uuid(),
  couple_id uuid not null references public.couple_spaces (id) on delete cascade,
  created_by uuid not null references public.profiles (id) on delete cascade,
  code_hash bytea not null unique,
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'declined', 'revoked', 'expired')),
  expires_at timestamptz not null,
  responded_by uuid references public.profiles (id) on delete set null,
  responded_at timestamptz,
  created_at timestamptz not null default now()
);

create index invitations_by_creator on public.invitations (created_by, created_at desc);
create index invitations_pending_by_couple on public.invitations (couple_id) where status = 'pending';

alter table public.invitations enable row level security;
revoke all on table public.invitations from anon, authenticated;
-- The creator can watch the status of their invitation. The hash is never
-- readable through the API, and nobody but the creator can list invitations.
grant select (id, couple_id, created_by, status, expires_at, responded_at, created_at)
  on table public.invitations to authenticated;
create policy invitations_select_creator on public.invitations
  for select to authenticated
  using (created_by = (select auth.uid()));

-- Redemption attempts, successful or not. Backs the brute-force limiter.
create table public.invitation_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  succeeded boolean not null,
  attempted_at timestamptz not null default now()
);

create index invitation_attempts_recent on public.invitation_attempts (user_id, attempted_at desc);
alter table public.invitation_attempts enable row level security;
revoke all on table public.invitation_attempts from anon, authenticated;

-- 10 characters from a 32-symbol alphabet with no look-alikes (no 0/O, 1/I):
-- 50 bits of entropy. Bytes are taken from a v4 UUID, skipping the bytes that
-- carry the fixed version/variant bits, so every symbol is uniformly random and
-- comes from the server's cryptographic RNG.
create or replace function app_private.generate_invite_code()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  alphabet constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  positions constant integer[] := array[0, 1, 2, 3, 4, 5, 10, 11, 12, 13];
  raw bytea := uuid_send(gen_random_uuid());
  code text := '';
  p integer;
begin
  foreach p in array positions loop
    code := code || substr(alphabet, (get_byte(raw, p) & 31) + 1, 1);
  end loop;
  return code;
end;
$$;

-- Accept what people actually type: lower case, spaces, dashes.
create or replace function app_private.normalize_invite_code(p_code text)
returns text
language sql
immutable
set search_path = ''
as $$
  select upper(regexp_replace(coalesce(p_code, ''), '[^0-9A-Za-z]', '', 'g'));
$$;

create or replace function app_private.hash_invite_code(p_code text)
returns bytea
language sql
immutable
set search_path = ''
as $$
  select sha256(convert_to(app_private.normalize_invite_code(p_code), 'UTF8'));
$$;

create or replace function app_private.invite_rate_limited(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select count(*) >= 5
  from public.invitation_attempts
  where user_id = p_user
    and not succeeded
    and attempted_at > now() - interval '15 minutes';
$$;

create or replace function app_private.log_invite_attempt(p_user uuid, p_succeeded boolean)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.invitation_attempts (user_id, succeeded) values (p_user, p_succeeded);
$$;

-- Serialises every pairing operation for one account, so two devices signed in
-- to the same account cannot race each other into two different spaces.
create or replace function app_private.lock_user_pairing(p_user uuid)
returns void
language sql
set search_path = ''
as $$
  select pg_advisory_xact_lock(hashtextextended('pairing:' || p_user::text, 0));
$$;

create or replace function public.create_couple_space()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  new_id uuid;
begin
  perform app_private.lock_user_pairing(uid);

  if exists (select 1 from public.couple_members where user_id = uid and left_at is null) then
    raise exception 'already_in_space';
  end if;

  insert into public.couple_spaces (created_by) values (uid) returning id into new_id;
  insert into public.couple_members (couple_id, user_id) values (new_id, uid);
  perform app_private.audit(uid, new_id, 'space_created');
  return new_id;
end;
$$;

-- Returns the plaintext code exactly once. It is not recoverable afterwards;
-- asking again issues a fresh code and revokes the previous one.
create or replace function public.create_invitation()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  my_couple uuid;
  new_code text;
  new_id uuid;
  new_expiry timestamptz := now() + interval '48 hours';
begin
  perform app_private.lock_user_pairing(uid);

  select m.couple_id into my_couple
  from public.couple_members m
  join public.couple_spaces c on c.id = m.couple_id
  where m.user_id = uid and m.left_at is null and c.status = 'active';

  if my_couple is null then
    raise exception 'no_space';
  end if;
  if app_private.active_member_count(my_couple) >= 2 then
    raise exception 'already_paired';
  end if;
  if (select count(*) from public.invitations
      where created_by = uid and created_at > now() - interval '24 hours') >= 10 then
    raise exception 'rate_limited';
  end if;

  update public.invitations set status = 'revoked', responded_at = now()
  where couple_id = my_couple and status = 'pending';

  new_code := app_private.generate_invite_code();
  insert into public.invitations (couple_id, created_by, code_hash, expires_at)
  values (my_couple, uid, app_private.hash_invite_code(new_code), new_expiry)
  returning id into new_id;

  perform app_private.audit(uid, my_couple, 'invitation_created');
  return jsonb_build_object('id', new_id, 'code', new_code, 'expires_at', new_expiry);
end;
$$;

create or replace function public.revoke_invitation(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
begin
  update public.invitations set status = 'revoked', responded_at = now()
  where id = p_invitation_id and created_by = uid and status = 'pending';
  if not found then
    raise exception 'invitation_unavailable';
  end if;
  perform app_private.audit(uid, null, 'invitation_revoked');
end;
$$;

-- The three redemption functions return a result object instead of raising for
-- an unusable code. Raising would roll back the attempt log and defeat the
-- rate limiter. Every "this code cannot be used" case other than expiry returns
-- the same answer, so a caller learns nothing about which codes ever existed.
create or replace function app_private.resolve_invitation(p_user uuid, p_code text, p_lock boolean)
returns public.invitations
language plpgsql
security definer
set search_path = ''
as $$
declare
  inv public.invitations;
  h bytea := app_private.hash_invite_code(p_code);
begin
  if p_lock then
    select * into inv from public.invitations where code_hash = h for update;
  else
    select * into inv from public.invitations where code_hash = h;
  end if;

  if inv.id is null then
    return null;
  end if;
  -- A blocked pairing looks exactly like a code that does not exist.
  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = p_user and b.blocked_id = inv.created_by)
       or (b.blocker_id = inv.created_by and b.blocked_id = p_user)
  ) then
    return null;
  end if;
  return inv;
end;
$$;

revoke all on function app_private.resolve_invitation(uuid, text, boolean) from public;

create or replace function public.preview_invitation(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  inv public.invitations;
  inviter_name text;
begin
  if app_private.invite_rate_limited(uid) then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  inv := app_private.resolve_invitation(uid, p_code, false);

  if inv.id is null or inv.status not in ('pending', 'expired') then
    perform app_private.log_invite_attempt(uid, false);
    return jsonb_build_object('ok', false, 'error', 'invitation_unavailable');
  end if;
  if inv.status = 'expired' or inv.expires_at <= now() then
    perform app_private.log_invite_attempt(uid, false);
    return jsonb_build_object('ok', false, 'error', 'invitation_expired');
  end if;
  if inv.created_by = uid then
    return jsonb_build_object('ok', false, 'error', 'own_invitation');
  end if;

  select display_name into inviter_name from public.profiles where id = inv.created_by;
  return jsonb_build_object(
    'ok', true,
    'inviter_name', coalesce(inviter_name, ''),
    'expires_at', inv.expires_at
  );
end;
$$;

create or replace function public.accept_invitation(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  inv public.invitations;
  my_couple uuid;
  target_status text;
begin
  perform app_private.lock_user_pairing(uid);

  if app_private.invite_rate_limited(uid) then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  -- First read without locks, only to learn which couple rows are involved.
  inv := app_private.resolve_invitation(uid, p_code, false);
  if inv.id is null then
    perform app_private.log_invite_attempt(uid, false);
    return jsonb_build_object('ok', false, 'error', 'invitation_unavailable');
  end if;
  if inv.created_by = uid then
    return jsonb_build_object('ok', false, 'error', 'own_invitation');
  end if;

  select couple_id into my_couple
  from public.couple_members where user_id = uid and left_at is null;

  -- Lock every couple row involved in a fixed order. Two partners redeeming
  -- each other's codes at the same instant therefore queue up instead of
  -- deadlocking, and the second one re-validates against the first's result.
  perform 1 from public.couple_spaces
  where id in (inv.couple_id, my_couple)
  order by id
  for update;

  -- Everything read before the locks is stale; read it again.
  inv := app_private.resolve_invitation(uid, p_code, true);
  select couple_id into my_couple
  from public.couple_members where user_id = uid and left_at is null;

  if my_couple is not null and app_private.active_member_count(my_couple) >= 2 then
    return jsonb_build_object('ok', false, 'error', 'already_paired');
  end if;

  if inv.id is null or inv.status not in ('pending', 'expired') then
    perform app_private.log_invite_attempt(uid, false);
    return jsonb_build_object('ok', false, 'error', 'invitation_unavailable');
  end if;
  if inv.status = 'expired' or inv.expires_at <= now() then
    update public.invitations set status = 'expired' where id = inv.id and status = 'pending';
    perform app_private.log_invite_attempt(uid, false);
    return jsonb_build_object('ok', false, 'error', 'invitation_expired');
  end if;

  select status into target_status from public.couple_spaces where id = inv.couple_id;
  if target_status is distinct from 'active'
     or app_private.active_member_count(inv.couple_id) <> 1
     or not exists (
       select 1 from public.couple_members
       where couple_id = inv.couple_id and user_id = inv.created_by and left_at is null
     ) then
    perform app_private.log_invite_attempt(uid, false);
    return jsonb_build_object('ok', false, 'error', 'invitation_unavailable');
  end if;

  -- The caller may be waiting alone in a space of their own. Close it: they are
  -- joining their partner's space instead.
  if my_couple is not null then
    update public.couple_members set left_at = now()
    where couple_id = my_couple and user_id = uid and left_at is null;
    update public.couple_spaces set status = 'ended', ended_at = now() where id = my_couple;
    update public.invitations set status = 'revoked', responded_at = now()
    where couple_id = my_couple and status = 'pending';
  end if;

  insert into public.couple_members (couple_id, user_id) values (inv.couple_id, uid)
  on conflict (couple_id, user_id) do update set left_at = null, joined_at = now();

  update public.couple_spaces set paired_at = now() where id = inv.couple_id;
  update public.invitations
  set status = 'accepted', responded_by = uid, responded_at = now()
  where id = inv.id;
  -- Any other outstanding code for this space is now meaningless.
  update public.invitations set status = 'revoked', responded_at = now()
  where couple_id = inv.couple_id and status = 'pending';

  perform app_private.log_invite_attempt(uid, true);
  perform app_private.audit(uid, inv.couple_id, 'invitation_accepted');
  return jsonb_build_object('ok', true, 'couple_id', inv.couple_id);
exception
  when unique_violation then
    -- couple_members_one_active_per_user fired: the account was paired by a
    -- concurrent request after our checks.
    return jsonb_build_object('ok', false, 'error', 'already_paired');
end;
$$;

create or replace function public.decline_invitation(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  inv public.invitations;
begin
  if app_private.invite_rate_limited(uid) then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  inv := app_private.resolve_invitation(uid, p_code, true);
  if inv.id is null or inv.status <> 'pending' or inv.expires_at <= now() or inv.created_by = uid then
    perform app_private.log_invite_attempt(uid, false);
    return jsonb_build_object('ok', false, 'error', 'invitation_unavailable');
  end if;

  update public.invitations
  set status = 'declined', responded_by = uid, responded_at = now()
  where id = inv.id;
  perform app_private.audit(uid, inv.couple_id, 'invitation_declined');
  return jsonb_build_object('ok', true);
end;
$$;

-- Unlinking. Ends the space for both partners immediately: neither can read or
-- write its content afterwards. The rows are kept for a 30 day retention window
-- (so each person can still export what they authored) and then purged.
-- Unlinking does not delete either account.
create or replace function public.leave_couple(p_block_partner boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  my_couple uuid;
  partner uuid;
begin
  perform app_private.lock_user_pairing(uid);

  select couple_id into my_couple
  from public.couple_members where user_id = uid and left_at is null;
  if my_couple is null then
    raise exception 'no_space';
  end if;

  perform 1 from public.couple_spaces where id = my_couple for update;

  select user_id into partner
  from public.couple_members
  where couple_id = my_couple and user_id <> uid and left_at is null;

  update public.couple_members set left_at = now()
  where couple_id = my_couple and left_at is null;
  update public.couple_spaces set status = 'ended', ended_at = now() where id = my_couple;
  update public.invitations set status = 'revoked', responded_at = now()
  where couple_id = my_couple and status = 'pending';

  if p_block_partner and partner is not null then
    insert into public.blocks (blocker_id, blocked_id) values (uid, partner)
    on conflict do nothing;
  end if;

  perform app_private.audit(uid, my_couple, 'space_left');
  if partner is not null then
    perform app_private.audit(partner, my_couple, 'space_ended_by_partner');
  end if;
end;
$$;

create or replace function public.set_couple_theme(p_theme_id text, p_accent_hex text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  my_couple uuid := app_private.current_couple_id();
  premium_theme boolean;
begin
  if my_couple is null then
    raise exception 'no_space';
  end if;
  select is_premium into premium_theme from public.themes where id = p_theme_id;
  if premium_theme is null then
    raise exception 'unknown_theme';
  end if;
  if p_accent_hex is not null and p_accent_hex !~ '^#[0-9A-Fa-f]{6}$' then
    raise exception 'invalid_accent';
  end if;
  -- Premium themes and custom accents are shared premium features. The check
  -- is deferred to couple_is_premium, defined with the entitlement tables.
  if (premium_theme or p_accent_hex is not null) and not app_private.couple_is_premium(my_couple) then
    raise exception 'premium_required';
  end if;

  update public.couple_spaces set theme_id = p_theme_id, accent_hex = p_accent_hex
  where id = my_couple;
end;
$$;
