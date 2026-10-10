-- A push token belongs to exactly one Apple environment. Which one is decided
-- by how the build was signed, and a client can get that wrong (a Release
-- build run from Xcode is signed for development). If the same token is ever
-- registered under both, Apple rejects the wrong one, and because rejected
-- tokens are removed by token alone, the right one is deleted with it.
--
-- So the latest registration wins: registering a token removes any copy of it
-- under the other environment.

create or replace function public.register_device_token(p_token text, p_environment text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
begin
  -- A device has one signed-in account at a time: registering moves the token.
  insert into public.device_tokens (token, environment, user_id)
  values (lower(p_token), p_environment, uid)
  on conflict (token, environment) do update set user_id = excluded.user_id, updated_at = now();

  delete from public.device_tokens
  where token = lower(p_token) and environment <> p_environment;

  -- Keep the list bounded per account.
  delete from public.device_tokens
  where user_id = uid
    and (token, environment) not in (
      select token, environment from public.device_tokens
      where user_id = uid order by updated_at desc limit 10
    );
end;
$$;

-- Existing duplicates: keep the most recent registration of each token.
delete from public.device_tokens d
using public.device_tokens newer
where newer.token = d.token
  and newer.environment <> d.environment
  and newer.updated_at > d.updated_at;
