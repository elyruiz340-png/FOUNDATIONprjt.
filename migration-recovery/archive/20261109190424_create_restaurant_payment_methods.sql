create table if not exists public.restaurant_payment_methods (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  method_key text not null check (method_key in ('cash','card','online')),
  display_name text not null check (char_length(btrim(display_name)) between 2 and 80),
  is_enabled boolean not null default false,
  provider_name text,
  confirmation_mode text not null default 'cashier_verification' check (confirmation_mode in ('immediate','cashier_verification','provider_webhook')),
  fee_type text not null default 'none' check (fee_type in ('none','percentage','fixed')),
  fee_value numeric(12,4) not null default 0 check (fee_value >= 0 and fee_value <= 1000000),
  instructions text,
  qr_image_url text,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (restaurant_id, method_key),
  check ((fee_type <> 'none') or fee_value = 0),
  check ((method_key <> 'cash') or confirmation_mode = 'immediate'),
  check ((confirmation_mode <> 'provider_webhook') or method_key = 'online')
);

alter table public.restaurant_payment_methods enable row level security;

drop policy if exists "Owners and admins view payment methods" on public.restaurant_payment_methods;
create policy "Owners and admins view payment methods" on public.restaurant_payment_methods
for select to authenticated
using (
  public.is_system_admin() or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_payment_methods.restaurant_id
      and ru.role in ('owner','admin')
  )
);

drop policy if exists "Owners and admins insert payment methods" on public.restaurant_payment_methods;
create policy "Owners and admins insert payment methods" on public.restaurant_payment_methods
for insert to authenticated
with check (
  public.is_system_admin() or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_payment_methods.restaurant_id
      and ru.role in ('owner','admin')
  )
);

drop policy if exists "Owners and admins update payment methods" on public.restaurant_payment_methods;
create policy "Owners and admins update payment methods" on public.restaurant_payment_methods
for update to authenticated
using (
  public.is_system_admin() or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_payment_methods.restaurant_id
      and ru.role in ('owner','admin')
  )
)
with check (
  public.is_system_admin() or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_payment_methods.restaurant_id
      and ru.role in ('owner','admin')
  )
);

drop policy if exists "Owners and admins delete payment methods" on public.restaurant_payment_methods;
create policy "Owners and admins delete payment methods" on public.restaurant_payment_methods
for delete to authenticated
using (
  public.is_system_admin() or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_payment_methods.restaurant_id
      and ru.role in ('owner','admin')
  )
);
