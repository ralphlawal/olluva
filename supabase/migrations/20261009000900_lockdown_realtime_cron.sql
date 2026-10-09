-- Final pass: function privileges, Realtime publication, scheduled jobs.

-- ---------------------------------------------------------------------------
-- Function privileges. Postgres grants EXECUTE on new functions to PUBLIC, and
-- Supabase additionally grants it to anon/authenticated. Take all of that away
-- and grant back by name, so a function is callable only if it is listed here.
-- ---------------------------------------------------------------------------

revoke execute on all functions in schema public from public, anon, authenticated;
revoke execute on all functions in schema app_private from public, anon;

alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema app_private revoke execute on functions from public, anon, authenticated;

-- Callable by signed-in users.
grant execute on function
  public.create_couple_space(),
  public.create_invitation(),
  public.revoke_invitation(uuid),
  public.preview_invitation(text),
  public.accept_invitation(text),
  public.decline_invitation(text),
  public.leave_couple(boolean),
  public.set_couple_theme(text, text),
  public.update_note(uuid, integer, text, jsonb, text, text),
  public.delete_note(uuid),
  public.mark_note_seen(uuid),
  public.set_reaction(uuid, text),
  public.save_note_to_memories(uuid, text),
  public.update_scheduled_message(uuid, integer, text, jsonb, text, text, timestamptz, text),
  public.cancel_scheduled_message(uuid),
  public.register_device_token(text, text),
  public.unregister_device_token(text),
  public.get_entitlement(),
  public.export_my_data()
to authenticated;

-- Callable only by trusted server code holding the service role key.
grant execute on function
  public.record_subscription(text, uuid, text, text, timestamptz, boolean, text, text),
  public.claim_notifications(integer),
  public.complete_notification(bigint, text, text[]),
  public.claim_storage_purges(integer),
  public.complete_storage_purges(text, text[]),
  public.prepare_account_deletion(uuid)
to service_role;

-- Helpers that RLS policies evaluate as the calling user.
grant execute on function
  app_private.require_user(),
  app_private.is_active_member(uuid),
  app_private.current_couple_id(),
  app_private.is_partner(uuid),
  app_private.can_access_couple_media(text),
  app_private.can_read_avatar(text)
to authenticated;

-- ---------------------------------------------------------------------------
-- Realtime. Only tables whose rows RLS already scopes to the couple. Realtime
-- applies the same SELECT policies before delivering a change.
-- ---------------------------------------------------------------------------

do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array[
      'notes', 'note_reactions', 'couple_spaces', 'couple_members',
      'memories', 'important_dates', 'invitations'
    ] loop
      if not exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
      ) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Scheduled jobs. Requires the pg_cron extension (Supabase: Database >
-- Extensions). The block is skipped where pg_cron is not installed so the same
-- migrations run in the local test database; see SETUP.md for enabling it.
--
-- The two jobs that call Edge Functions (push delivery, storage purge) need
-- the project URL and a shared secret, so they are created from SETUP.md
-- rather than here: no project-specific value is committed to a migration.
-- ---------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'deliver-scheduled-messages', '* * * * *',
      'select app_private.deliver_due_scheduled_messages()'
    );
    perform cron.schedule(
      'enqueue-date-reminders', '5 * * * *',
      'select app_private.enqueue_date_reminders()'
    );
    perform cron.schedule(
      'queue-orphaned-uploads', '20 3 * * *',
      'select app_private.queue_orphaned_uploads()'
    );
    perform cron.schedule(
      'purge-ended-spaces', '40 3 * * *',
      'select app_private.purge_ended_spaces()'
    );
  else
    raise notice 'pg_cron is not installed: scheduled jobs were not created (see SETUP.md)';
  end if;
end;
$$;
