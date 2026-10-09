-- Data export, account deletion, retention.

-- Everything the signed-in user has put into the product, as one JSON
-- document. Includes what they authored in spaces that have since ended (which
-- RLS no longer lets them browse) and excludes anything their partner wrote.
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
  return jsonb_build_object(
    'exported_at', now(),
    'format_version', 1,
    'profile', (
      select jsonb_build_object(
        'id', p.id, 'display_name', p.display_name, 'time_zone', p.time_zone,
        'has_avatar', p.avatar_path is not null, 'created_at', p.created_at
      ) from public.profiles p where p.id = uid
    ),
    'notification_preferences', (
      select to_jsonb(np) - 'user_id' from public.notification_preferences np where np.user_id = uid
    ),
    'spaces', coalesce((
      select jsonb_agg(jsonb_build_object(
        'couple_id', m.couple_id, 'joined_at', m.joined_at, 'left_at', m.left_at
      ) order by m.joined_at)
      from public.couple_members m where m.user_id = uid
    ), '[]'::jsonb),
    'notes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', n.id, 'couple_id', n.couple_id, 'body', n.body, 'style', n.style,
        'photo_path', n.photo_path, 'drawing_path', n.drawing_path,
        'origin', n.origin, 'created_at', n.created_at, 'updated_at', n.updated_at
      ) order by n.created_at)
      from public.notes n where n.author_id = uid and n.deleted_at is null
    ), '[]'::jsonb),
    'reactions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'note_id', r.note_id, 'kind', r.kind, 'created_at', r.created_at
      ) order by r.created_at)
      from public.note_reactions r where r.user_id = uid
    ), '[]'::jsonb),
    'memories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', me.id, 'kind', me.kind, 'title', me.title, 'caption', me.caption,
        'body', me.body, 'photo_path', me.photo_path, 'drawing_path', me.drawing_path,
        'occurred_on', me.occurred_on, 'created_at', me.created_at
      ) order by me.created_at)
      from public.memories me where me.created_by = uid
    ), '[]'::jsonb),
    'important_dates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', d.id, 'title', d.title, 'kind', d.kind, 'starts_on', d.starts_on,
        'recurrence', d.recurrence, 'visibility', d.visibility,
        'remind_days_before', d.remind_days_before
      ) order by d.starts_on)
      from public.important_dates d where d.created_by = uid
    ), '[]'::jsonb),
    'scheduled_messages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id, 'body', s.body, 'style', s.style, 'deliver_at', s.deliver_at,
        'time_zone', s.time_zone, 'status', s.status
      ) order by s.deliver_at)
      from public.scheduled_messages s where s.author_id = uid
    ), '[]'::jsonb),
    'subscriptions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'product_id', su.product_id, 'status', su.status, 'expires_at', su.expires_at
      ))
      from public.subscriptions su where su.user_id = uid
    ), '[]'::jsonb)
  );
end;
$$;

-- Step one of account deletion, run by the `delete-account` Edge Function with
-- the service role immediately before it removes the auth user. Removes what
-- the person authored and ends their space; the cascade from auth.users then
-- removes the profile and everything keyed to it.
create or replace function public.prepare_account_deletion(p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  their_couple uuid;
begin
  perform app_private.lock_user_pairing(p_user);

  select couple_id into their_couple
  from public.couple_members where user_id = p_user and left_at is null;

  if their_couple is not null then
    perform 1 from public.couple_spaces where id = their_couple for update;
    update public.couple_members set left_at = now()
    where couple_id = their_couple and left_at is null;
    update public.couple_spaces set status = 'ended', ended_at = now() where id = their_couple;
    update public.invitations set status = 'revoked', responded_at = now()
    where couple_id = their_couple and status = 'pending';
  end if;

  -- Deleting (not tombstoning) releases the media through the purge triggers.
  delete from public.notes where author_id = p_user;
  delete from public.memories where created_by = p_user;
  delete from public.scheduled_messages where author_id = p_user;
  update public.profiles set avatar_path = null where id = p_user and avatar_path is not null;

  perform app_private.audit(p_user, their_couple, 'account_deletion_prepared');
end;
$$;

-- Daily. Thirty days after a space ends, its remaining content is destroyed.
create or replace function app_private.purge_ended_spaces()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  purged integer;
begin
  with gone as (
    delete from public.couple_spaces
    where status = 'ended' and ended_at < now() - interval '30 days'
    returning 1
  )
  select count(*) into purged from gone;

  delete from public.invitation_attempts where attempted_at < now() - interval '7 days';
  delete from public.notification_outbox where created_at < now() - interval '7 days';
  delete from public.audit_events where created_at < now() - interval '180 days';
  return purged;
end;
$$;

revoke all on function app_private.purge_ended_spaces() from public;
