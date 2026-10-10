-- Push delivery: wake the send-push function the moment a notification is
-- queued, with a once-a-minute sweep as the safety net for anything missed.
--
-- The function URL and the shared secret are read from Supabase Vault
-- (`project_url` and `cron_secret`), so nothing project-specific or secret is
-- written in a migration. Where pg_net or the Vault entries are missing (the
-- local test database, or a project not yet configured) this does nothing.

create or replace function app_private.call_worker(p_function text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  base_url text;
  secret text;
begin
  if to_regnamespace('net') is null or to_regclass('vault.decrypted_secrets') is null then
    return;
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = ''project_url''' into base_url;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = ''cron_secret''' into secret;
  if base_url is null or secret is null then
    return;
  end if;
  -- pg_net queues the request and returns at once; the caller's transaction
  -- is never held up by, or failed because of, the network.
  execute 'select net.http_post(url := $1, headers := $2, body := $3)'
    using base_url || '/functions/v1/' || p_function,
          jsonb_build_object('content-type', 'application/json', 'x-cron-secret', secret),
          '{}'::jsonb;
exception
  when others then
    -- Delivery is best-effort here; the sweep below retries.
    null;
end;
$$;

revoke all on function app_private.call_worker(text) from public, anon, authenticated;

create or replace function app_private.outbox_wake_worker()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.call_worker('send-push');
  return null;
end;
$$;

-- Once per statement, not per row: a statement that queues several
-- notifications makes one call, and the function drains them all.
create trigger notification_outbox_wake_worker
  after insert on public.notification_outbox
  for each statement execute function app_private.outbox_wake_worker();

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('send-push-sweep', '* * * * *', $job$select app_private.call_worker('send-push')$job$);
    perform cron.schedule('purge-storage', '10 * * * *', $job$select app_private.call_worker('purge-storage')$job$);
  end if;
end;
$$;
