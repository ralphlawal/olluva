-- Extensions the scheduled jobs rely on. Enabled here, before anything else,
-- so that the cron blocks in later migrations take effect on a fresh project.
-- Guarded so the same file applies cleanly to a plain Postgres (the local test
-- database), where these extensions do not exist.

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema pg_catalog;
  end if;
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create schema if not exists extensions;
    create extension if not exists pg_net with schema extensions;
  end if;
end;
$$;
