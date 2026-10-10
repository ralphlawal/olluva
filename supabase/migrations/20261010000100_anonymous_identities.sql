-- No sign-up: people start with an anonymous Supabase Auth identity (enable
-- "Allow anonymous sign-ins" in the project's Auth settings) and may later
-- attach their Apple ID as a backup.
--
-- Nothing in the schema has to change for this. An anonymous user has a real
-- row in auth.users, a real user id, and the `authenticated` role, so every
-- policy and function above applies to them exactly as written. No policy may
-- ever be loosened on the grounds that "anonymous users need access": they
-- are authenticated users.
--
-- What it does add is identities that are created and then abandoned, since
-- creating one costs a person nothing. This removes the ones that never did
-- anything.

create or replace function app_private.purge_abandoned_identities()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  purged integer;
begin
  -- Deliberately narrow. Only identities that are still anonymous (never
  -- backed up), never chose a name, never created or joined a space, hold no
  -- subscription, and are over 30 days old. Anyone who got as far as typing a
  -- name is left alone.
  with gone as (
    delete from auth.users u
    where coalesce(u.is_anonymous, false)
      and u.created_at < now() - interval '30 days'
      and exists (select 1 from public.profiles p where p.id = u.id and p.display_name = '')
      and not exists (select 1 from public.couple_members m where m.user_id = u.id)
      and not exists (select 1 from public.subscriptions s where s.user_id = u.id)
    returning 1
  )
  select count(*) into purged from gone;
  return purged;
end;
$$;

revoke all on function app_private.purge_abandoned_identities() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'purge-abandoned-identities', '0 4 * * *',
      'select app_private.purge_abandoned_identities()'
    );
  end if;
end;
$$;
