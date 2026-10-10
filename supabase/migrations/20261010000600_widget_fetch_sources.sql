-- Records which part of the app last fetched widget content, and how often:
-- the notification extension (a push arrived) or the widget's own timeline
-- (iOS redrew the widget). Counts only. This is what distinguishes "the note
-- reached the phone" from "iOS actually redrew the widget" when diagnosing a
-- widget that looks stale.

alter table public.widget_tokens
  add column push_fetches integer not null default 0,
  add column timeline_fetches integer not null default 0,
  add column last_push_fetch_at timestamptz,
  add column last_timeline_fetch_at timestamptz;

create or replace function public.note_widget_fetch(p_token text, p_source text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.widget_tokens set
    push_fetches = push_fetches + (p_source = 'push')::int,
    timeline_fetches = timeline_fetches + (p_source = 'timeline')::int,
    last_push_fetch_at = case when p_source = 'push' then now() else last_push_fetch_at end,
    last_timeline_fetch_at = case when p_source = 'timeline' then now() else last_timeline_fetch_at end
  where token_hash = sha256(convert_to(coalesce(p_token, ''), 'UTF8'));
$$;

revoke execute on function public.note_widget_fetch(text, text) from public, anon, authenticated;
grant execute on function public.note_widget_fetch(text, text) to service_role;
