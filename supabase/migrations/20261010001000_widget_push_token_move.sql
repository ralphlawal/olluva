-- set_widget_push_token cleared the push token from other rows before
-- checking that the caller's widget token existed, so a call with an unknown
-- widget token could detach a device's push registration. It now touches
-- other rows only after the caller's own row has been updated.

create or replace function public.set_widget_push_token(p_token text, p_push_token text, p_environment text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  hash bytea := sha256(convert_to(coalesce(p_token, ''), 'UTF8'));
begin
  update public.widget_tokens set push_token = lower(p_push_token), push_environment = p_environment
  where token_hash = hash;
  if not found then
    return false;
  end if;
  -- A device has one set of widgets: the same push token must not stay
  -- attached to an older widget token.
  update public.widget_tokens set push_token = null, push_environment = null
  where push_token = lower(p_push_token) and token_hash <> hash;
  return true;
end;
$$;

revoke execute on function public.set_widget_push_token(text, text, text) from public, anon, authenticated;
grant execute on function public.set_widget_push_token(text, text, text) to service_role;
