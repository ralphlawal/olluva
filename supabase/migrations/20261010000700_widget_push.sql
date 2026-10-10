-- Widget push updates (iOS 26 and later). Apple gives each device's widgets
-- their own push token; a push sent to it makes iOS reload the widget, which
-- then fetches its content with the widget token. This is the supported way
-- to update a widget without the app running, and it works for deletions too.
--
-- The push token is stored against the widget token that registered it, so it
-- is revoked and removed together with it.

alter table public.widget_tokens
  add column push_token text check (push_token is null or push_token ~ '^[0-9a-f]{32,400}$'),
  add column push_environment text check (push_environment is null or push_environment in ('sandbox', 'production'));

create or replace function public.set_widget_push_token(p_token text, p_push_token text, p_environment text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  hash bytea := sha256(convert_to(coalesce(p_token, ''), 'UTF8'));
begin
  -- A device has one set of widgets: the same push token must not stay
  -- attached to an older widget token.
  update public.widget_tokens set push_token = null, push_environment = null
  where push_token = lower(p_push_token) and token_hash <> hash;
  update public.widget_tokens set push_token = lower(p_push_token), push_environment = p_environment
  where token_hash = hash;
  return found;
end;
$$;

revoke execute on function public.set_widget_push_token(text, text, text) from public, anon, authenticated;
grant execute on function public.set_widget_push_token(text, text, text) to service_role;

-- claim_notifications gains the recipient's widget push tokens. The return
-- type changes, so the function is replaced.
drop function public.claim_notifications(integer);

create function public.claim_notifications(p_limit integer default 50)
returns table (
  id bigint,
  user_id uuid,
  category text,
  payload jsonb,
  tokens jsonb,
  widget_push jsonb,
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
      select jsonb_agg(jsonb_build_object('token', w.push_token, 'environment', w.push_environment))
      from public.widget_tokens w where w.user_id = c.user_id and w.push_token is not null
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

revoke execute on function public.claim_notifications(integer) from public, anon, authenticated;
grant execute on function public.claim_notifications(integer) to service_role;

-- A dead widget push token reported by Apple is cleared, not the whole row:
-- the widget token itself is still valid.
create or replace function public.clear_widget_push_tokens(p_push_tokens text[])
returns void
language sql
security definer
set search_path = ''
as $$
  update public.widget_tokens set push_token = null, push_environment = null
  where push_token = any (p_push_tokens);
$$;

revoke execute on function public.clear_widget_push_tokens(text[]) from public, anon, authenticated;
grant execute on function public.clear_widget_push_tokens(text[]) to service_role;
