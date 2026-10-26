-- Together (20261013000200, 20261026000100) was withdrawn at the owner's
-- request before it reached anyone. This removes everything it added and
-- puts back what it changed: the notification queue, the data export, the
-- demo partner's routine, live updates and the morning job.
--
-- When this was written the tables held two empty test moments, no answers,
-- no saved memories and no notifications. Migrations are never edited once
-- applied, so the earlier files stay and this one undoes them.

do $$
begin
  -- Dynamic, because cron.job does not exist where pg_cron is not installed.
  if to_regclass('cron.job') is not null then
    execute $q$select cron.unschedule(jobid) from cron.job where jobname = 'together-announce'$q$;
  end if;
  if exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'together_moments'
  ) then
    alter publication supabase_realtime drop table public.together_moments;
  end if;
end;
$$;

-- The demo partner goes back to answering notes only.
drop trigger if exists review_partner_wake_on_together on public.together_moments;
drop function if exists app_private.review_partner_wake_on_together();

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


-- The export as it was.
drop function public.export_my_data();
alter function app_private.export_my_data_before_together() set schema public;
alter function public.export_my_data_before_together() rename to export_my_data;
revoke all on function public.export_my_data() from public, anon;
grant execute on function public.export_my_data() to authenticated;

-- Notifications as they were.
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

delete from public.notification_outbox where category = 'together';
alter table public.notification_outbox drop constraint notification_outbox_category_check;
alter table public.notification_outbox add constraint notification_outbox_category_check
  check (category in ('new_note', 'surprise', 'important_date', 'pairing', 'account', 'sync'));

alter table public.notification_preferences drop column together, drop column together_daily;
alter table public.memories drop column together_moment_id;

drop function if exists public.together_today();
drop function if exists public.together_submit(uuid, text);
drop function if exists public.together_reveal(uuid);
drop function if exists public.together_moment(uuid);
drop function if exists public.together_history(date, integer);
drop function if exists public.together_save_memory(uuid);
drop function if exists public.together_unsave_memory(uuid);
drop function if exists app_private.together_announce();
drop function if exists app_private.together_state(public.together_moments, uuid);
drop function if exists app_private.together_pick_question(uuid, date);
drop function if exists app_private.together_day(uuid, uuid);
drop function if exists app_private.together_couple(uuid);

drop table public.together_answers;
drop table public.together_moments;
drop table public.together_settings;
drop table public.together_questions;
