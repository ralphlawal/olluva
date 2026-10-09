-- Subscriptions and the shared couple entitlement.
--
-- A subscription belongs to the account that bought it. Premium is a property
-- of the couple space: the space is premium while either active member holds a
-- live subscription. One purchase therefore covers both partners, and it
-- follows the purchaser if the couple unlinks.
--
-- Clients can read their own subscription rows and nothing else. Rows are
-- written only by the `verify-purchase` and `app-store-notifications` Edge
-- Functions (service role) after they have verified Apple's signature. There is
-- no client-callable path that creates or extends an entitlement.

create table public.subscriptions (
  original_transaction_id text primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  product_id text not null,
  status text not null
    check (status in ('active', 'grace', 'billing_retry', 'expired', 'revoked')),
  -- For 'grace' this is the end of the grace period, not the paid period.
  expires_at timestamptz,
  auto_renew boolean not null default true,
  environment text not null check (environment in ('Production', 'Sandbox', 'Xcode')),
  last_transaction_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index subscriptions_by_user on public.subscriptions (user_id);

create trigger subscriptions_touch
  before update on public.subscriptions
  for each row execute function app_private.touch_updated_at();

alter table public.subscriptions enable row level security;
revoke all on table public.subscriptions from anon, authenticated;
grant select on table public.subscriptions to authenticated;
create policy subscriptions_select_own on public.subscriptions
  for select to authenticated
  using (user_id = (select auth.uid()));

create or replace function app_private.user_is_premium(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.subscriptions s
    where s.user_id = p_user
      and s.status in ('active', 'grace')
      and (s.expires_at is null or s.expires_at > now())
  );
$$;

create or replace function app_private.couple_is_premium(p_couple uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.couple_members m
    where m.couple_id = p_couple
      and m.left_at is null
      and app_private.user_is_premium(m.user_id)
  );
$$;

-- Server-enforced quantities. Mirrors ProductConfiguration in the iOS Domain
-- module; the two are kept in step by a test on each side.
create or replace function app_private.couple_limit(p_couple uuid, p_key text)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  premium boolean := app_private.couple_is_premium(p_couple);
begin
  return case p_key
    when 'memories' then case when premium then 2000 else 30 end
    when 'scheduled_pending' then case when premium then 50 else 1 end
    when 'important_dates' then 100
    else null
  end;
end;
$$;

-- What the signed-in user is entitled to right now, and why.
create or replace function public.get_entitlement()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := app_private.require_user();
  my_couple uuid := app_private.current_couple_id();
  own boolean := app_private.user_is_premium(uid);
  shared boolean := false;
  own_expiry timestamptz;
begin
  if my_couple is not null then
    shared := app_private.couple_is_premium(my_couple);
  end if;

  select max(expires_at) into own_expiry
  from public.subscriptions
  where user_id = uid and status in ('active', 'grace');

  return jsonb_build_object(
    'is_premium', own or shared,
    'source', case when own then 'self' when shared then 'partner' else null end,
    'expires_at', case when own then own_expiry else null end,
    'memories_limit', case when own or shared then 2000 else 30 end,
    'scheduled_limit', case when own or shared then 50 else 1 end
  );
end;
$$;

-- Service role only. `p_user` comes from the verified transaction's
-- appAccountToken, never from an unauthenticated request body.
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
    if p_user is null then
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

  -- One Apple subscription backs one account. A second account presenting the
  -- same purchase does not take it over.
  if p_user is not null and existing_owner <> p_user then
    return 'owned_by_other_account';
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
