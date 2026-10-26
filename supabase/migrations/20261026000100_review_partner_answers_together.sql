-- The App Review demo partner (ADR 0010) also answers the daily Together
-- question (ADR 0011), so a reviewer on one phone can take a moment all the
-- way to being opened together. The answers are fixed, one per category of
-- question, and only ever go to the demo partner's own space.

create or replace function public.review_partner_tick()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  partner record;
  moment record;
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

  -- Today's Together question: the demo partner answers it, so whoever is
  -- trying the app can see a moment through to being opened together.
  for moment in
    select tm.id, tm.couple_id, q.category, rp.user_id as demo
    from public.together_moments tm
    join public.together_questions q on q.id = tm.question_id
    join public.couple_members m on m.couple_id = tm.couple_id and m.left_at is null
    join public.review_partners rp on rp.user_id = m.user_id
    join public.couple_spaces c on c.id = tm.couple_id and c.status = 'active'
    where tm.revealed_at is null
      and tm.created_at > now() - interval '2 days'
      and not exists (select 1 from public.together_answers a where a.moment_id = tm.id and a.user_id = rp.user_id)
  loop
    insert into public.together_answers (moment_id, user_id, body)
    values (moment.id, moment.demo, case moment.category
      when 'appreciation' then 'The way you always save me the last bite. It’s a small thing, and I notice it every time.'
      when 'memories' then 'That rainy afternoon we got lost and ended up in the best little café.'
      when 'everyday' then 'Ten quiet minutes, a cup of tea, and you.'
      when 'future' then 'A weekend somewhere by the sea, phones off.'
      when 'understanding' then 'A hug, and no questions for the first five minutes.'
      else 'Obviously a very small, very grumpy cat.'
    end)
    on conflict (moment_id, user_id) do nothing;

    update public.together_moments set
      answer_count = (select count(*) from public.together_answers where moment_id = moment.id),
      ready_at = case when (select count(*) from public.together_answers where moment_id = moment.id) = 2
                      then coalesce(ready_at, now()) else ready_at end,
      updated_at = now()
    where id = moment.id;
    written := written + 1;
  end loop;
  return written;
end;
$$;

-- Wake the worker when a demo space gets its question for the day, so the
-- answer is there within seconds rather than at the next five-minute sweep.
create or replace function app_private.review_partner_wake_on_together()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1 from public.couple_members m
    where m.couple_id = new.couple_id and m.left_at is null
      and app_private.is_review_partner(m.user_id)
  ) then
    perform app_private.call_worker('review-partner');
  end if;
  return null;
end;
$$;

revoke all on function app_private.review_partner_wake_on_together() from public, anon, authenticated;

create trigger review_partner_wake_on_together
  after insert on public.together_moments
  for each row execute function app_private.review_partner_wake_on_together();
