create table public.restaurant_discount_rules (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  rule_name text not null check (char_length(btrim(rule_name)) between 2 and 120),
  discount_category text not null check (discount_category in ('senior','pwd','promotion','staff','other')),
  discount_type text not null check (discount_type in ('percentage','fixed')),
  rate numeric(12,2) not null check (rate >= 0 and rate <= 1000000),
  max_discount_amount numeric(12,2) check (max_discount_amount is null or max_discount_amount >= 0),
  minimum_subtotal numeric(12,2) not null default 0 check (minimum_subtotal >= 0),
  applies_to text[] not null default array['dine_in','takeout','delivery']::text[]
    check (cardinality(applies_to) > 0 and applies_to <@ array['dine_in','takeout','delivery']::text[]),
  requires_verification boolean not null default false,
  effective_from date not null,
  effective_to date,
  is_active boolean not null default false,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  constraint restaurant_discount_rules_rate_limit check (discount_type <> 'percentage' or rate <= 100),
  constraint restaurant_discount_rules_dates check (effective_to is null or effective_to >= effective_from)
);

create index restaurant_discount_rules_restaurant_active_idx
  on public.restaurant_discount_rules (restaurant_id, is_active, effective_from desc);

create table public.restaurant_vouchers (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  code text not null check (char_length(btrim(code)) between 3 and 40),
  description text,
  discount_type text not null check (discount_type in ('percentage','fixed')),
  discount_value numeric(12,2) not null check (discount_value > 0 and discount_value <= 1000000),
  max_discount_amount numeric(12,2) check (max_discount_amount is null or max_discount_amount >= 0),
  minimum_order_amount numeric(12,2) not null default 0 check (minimum_order_amount >= 0),
  usage_limit integer check (usage_limit is null or usage_limit > 0),
  per_customer_limit integer check (per_customer_limit is null or per_customer_limit > 0),
  applies_to text[] not null default array['dine_in','takeout','delivery']::text[]
    check (cardinality(applies_to) > 0 and applies_to <@ array['dine_in','takeout','delivery']::text[]),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  is_active boolean not null default false,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  constraint restaurant_vouchers_code_upper check (code = upper(btrim(code))),
  constraint restaurant_vouchers_percentage_limit check (discount_type <> 'percentage' or discount_value <= 100),
  constraint restaurant_vouchers_dates check (ends_at is null or ends_at >= starts_at)
);

create unique index restaurant_vouchers_restaurant_code_uidx
  on public.restaurant_vouchers (restaurant_id, code);
create index restaurant_vouchers_restaurant_active_idx
  on public.restaurant_vouchers (restaurant_id, is_active, starts_at, ends_at);

alter table public.restaurant_discount_rules enable row level security;
alter table public.restaurant_vouchers enable row level security;

create policy "Owners and admins view discount rules"
on public.restaurant_discount_rules for select to authenticated
using (
  is_system_admin() or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_discount_rules.restaurant_id
      and ru.role = any (array['owner','admin']::text[])
  )
);

create policy "Owners and admins insert discount rules"
on public.restaurant_discount_rules for insert to authenticated
with check (
  is_system_admin() or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_discount_rules.restaurant_id
      and ru.role = any (array['owner','admin']::text[])
  )
);

create policy "Owners and admins update discount rules"
on public.restaurant_discount_rules for update to authenticated
using (
  is_system_admin() or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_discount_rules.restaurant_id
      and ru.role = any (array['owner','admin']::text[])
  )
)
with check (
  is_system_admin() or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_discount_rules.restaurant_id
      and ru.role = any (array['owner','admin']::text[])
  )
);

create policy "Owners and admins delete discount rules"
on public.restaurant_discount_rules for delete to authenticated
using (
  is_system_admin() or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_discount_rules.restaurant_id
      and ru.role = any (array['owner','admin']::text[])
  )
);

create policy "Owners and admins view vouchers"
on public.restaurant_vouchers for select to authenticated
using (
  is_system_admin() or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_vouchers.restaurant_id
      and ru.role = any (array['owner','admin']::text[])
  )
);

create policy "Owners and admins insert vouchers"
on public.restaurant_vouchers for insert to authenticated
with check (
  is_system_admin() or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_vouchers.restaurant_id
      and ru.role = any (array['owner','admin']::text[])
  )
);

create policy "Owners and admins update vouchers"
on public.restaurant_vouchers for update to authenticated
using (
  is_system_admin() or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_vouchers.restaurant_id
      and ru.role = any (array['owner','admin']::text[])
  )
)
with check (
  is_system_admin() or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_vouchers.restaurant_id
      and ru.role = any (array['owner','admin']::text[])
  )
);

create policy "Owners and admins delete vouchers"
on public.restaurant_vouchers for delete to authenticated
using (
  is_system_admin() or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_vouchers.restaurant_id
      and ru.role = any (array['owner','admin']::text[])
  )
);