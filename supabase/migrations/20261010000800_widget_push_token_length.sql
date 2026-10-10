-- Widget push tokens are longer than ordinary device tokens. The first
-- version capped them at 400 hex characters, which rejected real ones.

alter table public.widget_tokens drop constraint widget_tokens_push_token_check;
alter table public.widget_tokens add constraint widget_tokens_push_token_check
  check (push_token is null or push_token ~ '^[0-9a-f]{32,4096}$');
