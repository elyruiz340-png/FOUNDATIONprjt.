
create table public.restaurant_payment_methods (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  method_key text not null check (method_key in ('cash','card','qr_manual','online')),
  display_name text not null check (char_length(btrim(display_name)) between 2 and 80),
  is_enabled boolean not null default false,
  provider_name text,
  fee_percent numeric(8,4) not null default 0 check (fee_percent >= 0 and fee_percent <= 100),
  fee_fixed numeric(12,2) not null default 0 check (fee_fixed >= 0),
  qr_image_url text,
  instructions text,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (restaurant_id, method_key)
);

alter table public.restaurant_payment_methods enable row level security;

create policy "Owners and admins view payment methods"
on public.restaurant_payment_methods
for select
using (
  is_system_admin()
  or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_payment_methods.restaurant_id
      and ru.role = any (array['owner'::text, 'admin'::text])
  )
);

create policy "Owners and admins insert payment methods"
on public.restaurant_payment_methods
for insert
with check (
  is_system_admin()
  or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_payment_methods.restaurant_id
      and ru.role = any (array['owner'::text, 'admin'::text])
  )
);

create policy "Owners and admins update payment methods"
on public.restaurant_payment_methods
for update
using (
  is_system_admin()
  or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_payment_methods.restaurant_id
      and ru.role = any (array['owner'::text, 'admin'::text])
  )
)
with check (
  is_system_admin()
  or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_payment_methods.restaurant_id
      and ru.role = any (array['owner'::text, 'admin'::text])
  )
);

create policy "Owners and admins delete payment methods"
on public.restaurant_payment_methods
for delete
using (
  is_system_admin()
  or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_payment_methods.restaurant_id
      and ru.role = any (array['owner'::text, 'admin'::text])
  )
);
