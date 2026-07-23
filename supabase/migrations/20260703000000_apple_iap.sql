-- Apple In-App Purchase support.
--
-- `public.subscriptions` keeps its one-row-per-user shape (UNIQUE(user_id));
-- Apple subscriptions reuse the same row, distinguished by `provider`. The
-- existing `on_subscription_change` trigger keeps `public.users` in sync, so
-- nothing else needs to change for entitlements to flow.
--
-- Writes remain service-role only (RLS has a SELECT-own-row policy and no
-- INSERT/UPDATE policies): the `apple-iap-sync` and `apple-webhook` Edge
-- Functions are the only writers for provider='apple' rows.

alter table public.subscriptions
  add column if not exists provider text not null default 'stripe'
    check (provider in ('stripe', 'apple')),
  add column if not exists apple_original_transaction_id text,
  add column if not exists apple_product_id text,
  add column if not exists apple_environment text
    check (apple_environment in ('Sandbox', 'Production'));

create unique index if not exists subscriptions_apple_original_txid_key
  on public.subscriptions (apple_original_transaction_id)
  where apple_original_transaction_id is not null;

-- Idempotency + audit log for App Store Server Notifications V2. Service-role
-- only: RLS enabled with no policies.
create table if not exists public.apple_notification_log (
  notification_uuid text primary key,
  notification_type text,
  subtype text,
  original_transaction_id text,
  payload jsonb,
  created_at timestamptz not null default now()
);

alter table public.apple_notification_log enable row level security;
