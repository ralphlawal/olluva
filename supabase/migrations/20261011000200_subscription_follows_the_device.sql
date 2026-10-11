-- With no accounts, a person's identity is replaced whenever they reinstall
-- or start over, but their Apple subscription is not: it stays with their
-- Apple ID. Binding a subscription to the first identity that presented it
-- meant "Restore purchases" could never work for anyone who had done either.
--
-- So ownership follows the device. A caller who presents a transaction that
-- Apple signed is holding that Apple ID's purchase, and the subscription
-- moves to them. It still backs exactly one identity (and so one space) at a
-- time: claiming it takes it away from whoever had it.
--
-- App Store server notifications are different. They report what happened to
-- a subscription, and carry the identity it was first bought under, which may
-- be long gone. They update the record and never change who owns it.

create or replace function public.claim_subscription(
  p_original_transaction_id text,
  p_user uuid,
  p_product_id text,
  p_status text,
  p_expires_at timestamptz,
  p_auto_renew boolean,
  p_environment text,
  p_last_transaction_id text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing_owner uuid;
begin
  if p_user is null then
    return 'unknown_owner';
  end if;

  select user_id into existing_owner
  from public.subscriptions
  where original_transaction_id = p_original_transaction_id
  for update;

  insert into public.subscriptions (
    original_transaction_id, user_id, product_id, status, expires_at,
    auto_renew, environment, last_transaction_id
  ) values (
    p_original_transaction_id, p_user, p_product_id, p_status, p_expires_at,
    coalesce(p_auto_renew, true), p_environment, p_last_transaction_id
  )
  on conflict (original_transaction_id) do update set
    user_id = excluded.user_id,
    product_id = excluded.product_id,
    status = excluded.status,
    expires_at = excluded.expires_at,
    auto_renew = coalesce(p_auto_renew, public.subscriptions.auto_renew),
    environment = excluded.environment,
    last_transaction_id = coalesce(excluded.last_transaction_id, public.subscriptions.last_transaction_id),
    updated_at = now();

  if existing_owner is null then
    perform app_private.audit(p_user, null, 'subscription_recorded');
    return 'recorded';
  elsif existing_owner <> p_user then
    perform app_private.audit(existing_owner, null, 'subscription_transferred_away');
    perform app_private.audit(p_user, null, 'subscription_transferred');
    return 'transferred';
  end if;
  return 'updated';
end;
$$;

revoke all on function public.claim_subscription(text, uuid, text, text, timestamptz, boolean, text, text)
  from public, anon, authenticated;
grant execute on function public.claim_subscription(text, uuid, text, text, timestamptz, boolean, text, text)
  to service_role;

create or replace function public.record_subscription(
  p_original_transaction_id text,
  p_user uuid,
  p_product_id text,
  p_status text,
  p_expires_at timestamptz,
  p_auto_renew boolean,
  p_environment text,
  p_last_transaction_id text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing_owner uuid;
begin
  select user_id into existing_owner
  from public.subscriptions
  where original_transaction_id = p_original_transaction_id
  for update;

  if existing_owner is null then
    -- A notification can arrive before the device has presented the purchase.
    -- It may open the record only for an identity that still exists.
    if p_user is null or not exists (select 1 from public.profiles where id = p_user) then
      return 'unknown_owner';
    end if;
    insert into public.subscriptions (
      original_transaction_id, user_id, product_id, status, expires_at,
      auto_renew, environment, last_transaction_id
    ) values (
      p_original_transaction_id, p_user, p_product_id, p_status, p_expires_at,
      coalesce(p_auto_renew, true), p_environment, p_last_transaction_id
    );
    perform app_private.audit(p_user, null, 'subscription_recorded');
    return 'recorded';
  end if;

  update public.subscriptions set
    product_id = p_product_id,
    status = p_status,
    expires_at = p_expires_at,
    auto_renew = coalesce(p_auto_renew, auto_renew),
    environment = p_environment,
    last_transaction_id = coalesce(p_last_transaction_id, last_transaction_id)
  where original_transaction_id = p_original_transaction_id;
  perform app_private.audit(existing_owner, null, 'subscription_' || p_status);
  return 'updated';
end;
$$;
