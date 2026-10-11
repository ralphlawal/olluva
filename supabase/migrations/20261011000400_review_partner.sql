-- A demo partner for App Review.
--
-- Almost everything in the app needs a second person, and a reviewer has one
-- phone. So one invitation code, given to Apple in the review notes, is kept
-- permanently redeemable: behind it waits a "Demo Partner" identity, alone in
-- a space of its own. The reviewer redeems the code through the ordinary
-- pairing flow, which is not changed or special-cased in any way, and finds
-- themselves paired with it. It greets them and answers each note they send.
--
-- What keeps this safe:
--   * A demo partner is a separate identity in a separate space. Redeeming the
--     code gives access to that space and to nothing else.
--   * It cannot sign in: nobody holds its session.
--   * The code itself is not in the database or the repository. It is an Edge
--     Function secret; only its hash is stored, as for any invitation. Removing
--     the secret retires the code.
--   * Use is bounded: a limited number of demo partners per day, a limited
--     number of replies per space, and everything is deleted after 14 days or
--     as soon as the other person leaves.
--
-- The functions here are callable only by trusted server code. The
-- `review-partner` Edge Function drives them.

create table public.review_partners (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.review_partners enable row level security;
revoke all on table public.review_partners from anon, authenticated;

create or replace function app_private.is_review_partner(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.review_partners where user_id = p_user);
$$;
revoke all on function app_private.is_review_partner(uuid) from public, anon, authenticated;

-- True when the code currently has nobody waiting behind it and today's
-- allowance is not used up.
create or replace function public.review_partner_needed(p_code text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  h bytea := app_private.hash_invite_code(p_code);
begin
  if char_length(app_private.normalize_invite_code(p_code)) <> 10 then
    return false;
  end if;
  if (select count(*) from public.review_partners where created_at > now() - interval '1 day') >= 30 then
    return false;
  end if;
  -- A real person happens to hold this very code: leave it alone.
  if exists (
    select 1 from public.invitations
    where code_hash = h and not app_private.is_review_partner(created_by)
  ) then
    return false;
  end if;
  return not exists (
    select 1
    from public.invitations i
    join public.couple_spaces c on c.id = i.couple_id and c.status = 'active'
    where i.code_hash = h
      and i.status = 'pending'
      and i.expires_at > now()
      and app_private.is_review_partner(i.created_by)
      and app_private.active_member_count(i.couple_id) = 1
  );
end;
$$;

-- Turns a freshly created identity into the demo partner waiting behind the code.
create or replace function public.review_partner_provision(p_user uuid, p_code text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  h bytea := app_private.hash_invite_code(p_code);
  space uuid;
begin
  if char_length(app_private.normalize_invite_code(p_code)) <> 10 then
    raise exception 'invalid_code';
  end if;
  if not exists (select 1 from public.profiles where id = p_user)
     or exists (select 1 from public.couple_members where user_id = p_user) then
    raise exception 'identity_not_fresh';
  end if;
  -- The code must never collide with one a real person is holding.
  if exists (
    select 1 from public.invitations
    where code_hash = h and not app_private.is_review_partner(created_by)
  ) then
    raise exception 'code_in_use';
  end if;

  -- Earlier demo invitations for this code have been used. Free the hash: an
  -- invitation's code is unique for as long as its row exists.
  update public.invitations
  set code_hash = sha256(convert_to(id::text || ':' || gen_random_uuid()::text, 'UTF8')),
      status = case when status = 'pending' then 'revoked' else status end
  where code_hash = h;

  insert into public.review_partners (user_id) values (p_user);
  update public.profiles set display_name = 'Demo Partner' where id = p_user;

  insert into public.couple_spaces (created_by) values (p_user) returning id into space;
  insert into public.couple_members (couple_id, user_id) values (space, p_user);
  insert into public.invitations (couple_id, created_by, code_hash, expires_at)
  values (space, p_user, h, now() + interval '30 days');
  return space;
end;
$$;

-- Retires the code: nobody new can redeem it.
create or replace function public.review_partner_retire()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  affected integer;
begin
  update public.invitations set status = 'revoked', responded_at = now()
  where status = 'pending' and app_private.is_review_partner(created_by);
  get diagnostics affected = row_count;
  return affected;
end;
$$;

-- Greets whoever has just paired with a demo partner and answers their notes.
create or replace function public.review_partner_tick()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  partner record;
  mine integer;
  latest_author uuid;
  written integer := 0;
  replies text[] := array[
    'Got it! This reply came from the demo partner.',
    'That one reached my Home Screen widget.',
    'Try the pencil to draw, or send a photo.',
    'You can save a note you like to Memories.',
    'Lovely. Try scheduling a note for later, too.'
  ];
  body text;
begin
  -- The waiting invitation must not lapse.
  update public.invitations set expires_at = now() + interval '30 days'
  where status = 'pending' and expires_at < now() + interval '7 days'
    and app_private.is_review_partner(created_by);

  for partner in
    select rp.user_id, m.couple_id
    from public.review_partners rp
    join public.couple_members m on m.user_id = rp.user_id and m.left_at is null
    join public.couple_spaces c on c.id = m.couple_id and c.status = 'active'
    where app_private.active_member_count(m.couple_id) = 2
  loop
    select count(*) into mine from public.notes
    where couple_id = partner.couple_id and author_id = partner.user_id;
    select author_id into latest_author from public.notes
    where couple_id = partner.couple_id and deleted_at is null
    order by created_at desc, id desc limit 1;

    if mine = 0 then
      body := 'Hello! I''m a demo partner, here so you can try Olluva. Send me a note and I''ll write back.';
    elsif latest_author is distinct from partner.user_id and mine < 25 then
      body := replies[1 + ((mine - 1) % array_length(replies, 1))];
    else
      continue;
    end if;

    insert into public.notes (couple_id, author_id, body, style)
    values (partner.couple_id, partner.user_id, body,
            jsonb_build_object('paper', 'blush', 'ink', 'rose', 'typeface', 'hand'));
    written := written + 1;
  end loop;
  return written;
end;
$$;

-- Demo partners that are finished with: the one waiting behind the code is
-- never among them.
create or replace function public.review_partners_expired()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select rp.user_id
  from public.review_partners rp
  where not exists (
      select 1 from public.invitations i
      where i.created_by = rp.user_id and i.status = 'pending'
    )
    and (
      rp.created_at < now() - interval '14 days'
      or not exists (
        select 1
        from public.couple_members m
        join public.couple_spaces c on c.id = m.couple_id and c.status = 'active'
        where m.user_id = rp.user_id and m.left_at is null
          and app_private.active_member_count(m.couple_id) = 2
      )
    );
$$;

revoke all on function
  public.review_partner_needed(text),
  public.review_partner_provision(uuid, text),
  public.review_partner_retire(),
  public.review_partner_tick(),
  public.review_partners_expired()
from public, anon, authenticated;

grant execute on function
  public.review_partner_needed(text),
  public.review_partner_provision(uuid, text),
  public.review_partner_retire(),
  public.review_partner_tick(),
  public.review_partners_expired()
to service_role;

-- Wake the worker the moment there is something for it to do, so a reviewer
-- is greeted and answered in seconds and the code is refilled straight away.
create or replace function app_private.review_partner_wake_on_pairing()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'accepted' and old.status is distinct from 'accepted'
     and app_private.is_review_partner(new.created_by) then
    perform app_private.call_worker('review-partner');
  end if;
  return null;
end;
$$;

create or replace function app_private.review_partner_wake_on_note()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not app_private.is_review_partner(new.author_id) and exists (
    select 1 from public.couple_members m
    where m.couple_id = new.couple_id and m.left_at is null
      and app_private.is_review_partner(m.user_id)
  ) then
    perform app_private.call_worker('review-partner');
  end if;
  return null;
end;
$$;

revoke all on function app_private.review_partner_wake_on_pairing() from public, anon, authenticated;
revoke all on function app_private.review_partner_wake_on_note() from public, anon, authenticated;

create trigger review_partner_wake_on_pairing
  after update of status on public.invitations
  for each row execute function app_private.review_partner_wake_on_pairing();

create trigger review_partner_wake_on_note
  after insert on public.notes
  for each row execute function app_private.review_partner_wake_on_note();

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('review-partner', '*/5 * * * *', $job$select app_private.call_worker('review-partner')$job$);
  end if;
end;
$$;
