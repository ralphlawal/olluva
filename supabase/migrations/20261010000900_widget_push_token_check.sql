-- The previous checks used a regex repetition count above 255, which Postgres
-- rejects when it evaluates the pattern, so no push token could ever be
-- stored. Length is now checked separately.

alter table public.widget_tokens drop constraint widget_tokens_push_token_check;
alter table public.widget_tokens add constraint widget_tokens_push_token_check
  check (push_token is null or (push_token ~ '^[0-9a-f]+$' and char_length(push_token) between 32 and 4096));
