-- Postgres grants EXECUTE on every new function to PUBLIC, and that default
-- cannot be removed per schema, so each new function has to be revoked by
-- name. The trigger function added in the previous migration was missed.
-- (A trigger function cannot be invoked directly in any case; this keeps the
-- "nothing is executable unless listed" rule exact.)

revoke all on function app_private.outbox_wake_worker() from public, anon, authenticated;
