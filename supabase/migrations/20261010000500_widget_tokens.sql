-- Lets the widget (and the notification extension) fetch the one thing they
-- display, without the app being awake and without sharing the app's session.
--
-- A widget token is a separate, narrow credential:
--   * it can do exactly one thing: read what the widget shows (the partner's
--     latest note, their name, the space's theme);
--   * it cannot write anything, read history, or act as the user;
--   * only its hash is stored; it is revoked on sign-out and removed with the
--     account; each identity keeps at most three (one per device).
-- It is deliberately not the app's session: extensions refreshing a shared
-- session would race the app and could sign the person out.

create table public.widget_tokens (
  token_hash bytea primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);

create index widget_tokens_by_user on public.widget_tokens (user_id, created_at desc);

alter table public.widget_tokens enable row level security;
revoke all on table public.widget_tokens from anon, authenticated;

create or replace function public.issue_widget_token()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  token text;
begin
  -- 244 random bits from the server's cryptographic RNG, as 64 hex characters.
  token := encode(uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid()), 'hex');
  insert into public.widget_tokens (token_hash, user_id)
  values (sha256(convert_to(token, 'UTF8')), uid);

  delete from public.widget_tokens
  where user_id = uid
    and token_hash not in (
      select token_hash from public.widget_tokens
      where user_id = uid order by created_at desc limit 3
    );
  return token;
end;
$$;

create or replace function public.revoke_widget_token(p_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
begin
  delete from public.widget_tokens
  where token_hash = sha256(convert_to(coalesce(p_token, ''), 'UTF8')) and user_id = uid;
end;
$$;

-- Service role only: called by the widget-snapshot Edge Function, which is
-- what the widget talks to. Returns null for an unknown or revoked token.
create or replace function public.widget_snapshot(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid;
  my_couple uuid;
  space public.couple_spaces;
  partner public.profiles;
  latest public.notes;
begin
  update public.widget_tokens set last_used_at = now()
  where token_hash = sha256(convert_to(coalesce(p_token, ''), 'UTF8'))
  returning user_id into uid;
  if uid is null then
    return null;
  end if;

  select c.* into space
  from public.couple_members m
  join public.couple_spaces c on c.id = m.couple_id
  where m.user_id = uid and m.left_at is null and c.status = 'active';
  my_couple := space.id;

  if my_couple is not null then
    select p.* into partner
    from public.couple_members m
    join public.profiles p on p.id = m.user_id
    where m.couple_id = my_couple and m.left_at is null and m.user_id <> uid;
  end if;

  if partner.id is null then
    return jsonb_build_object('state', 'unpaired');
  end if;

  -- Exactly what the widget shows: the newest note the partner wrote that
  -- has not been deleted. Never the person's own notes, never history.
  select n.* into latest
  from public.notes n
  where n.couple_id = my_couple and n.deleted_at is null and n.author_id is distinct from uid
  order by n.created_at desc, n.id desc
  limit 1;

  return jsonb_build_object(
    'state', case when latest.id is null then 'empty' else 'note' end,
    'partner_name', partner.display_name,
    'theme_id', space.theme_id,
    'accent_hex', space.accent_hex,
    'note', case when latest.id is null then null else jsonb_build_object(
      'id', latest.id,
      'body', latest.body,
      'style', latest.style,
      'photo_path', latest.photo_path,
      'drawing_path', latest.drawing_path,
      'created_at', latest.created_at,
      'is_unseen', latest.seen_at is null
    ) end
  );
end;
$$;

revoke execute on function public.issue_widget_token(), public.revoke_widget_token(text), public.widget_snapshot(text)
  from public, anon, authenticated;
grant execute on function public.issue_widget_token(), public.revoke_widget_token(text) to authenticated;
grant execute on function public.widget_snapshot(text) to service_role;
