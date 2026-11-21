
create table public.restaurant_service_charge_rules (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  rule_name text not null check (char_length(trim(rule_name)) between 2 and 120),
  display_label text not null default 'Service Charge'
    check (char_length(trim(display_label)) between 2 and 80),
  charge_type text not null check (charge_type in ('percentage','fixed')),
  rate numeric(10,4) not null check (rate >= 0 and rate <= 1000000),
  applies_to text[] not null default array['dine_in']::text[],
  is_mandatory boolean not null default true,
  is_active boolean not null default false,
  effective_from date not null,
  effective_to date,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  constraint restaurant_service_charge_dates_check
    check (effective_to is null or effective_to >= effective_from),
  constraint restaurant_service_charge_order_types_check
    check (
      cardinality(applies_to) > 0
      and applies_to <@ array['dine_in','takeout','delivery']::text[]
    )
);

create index restaurant_service_charge_restaurant_effective_idx
  on public.restaurant_service_charge_rules (restaurant_id, effective_from desc);

alter table public.restaurant_service_charge_rules enable row level security;
grant select, insert, update, delete on public.restaurant_service_charge_rules to authenticated;

create policy "Owners and admins view service charge rules"
on public.restaurant_service_charge_rules for select to authenticated
using (
  public.is_system_admin()
  or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_service_charge_rules.restaurant_id
      and ru.role in ('owner','admin')
  )
);

create policy "Owners and admins insert service charge rules"
on public.restaurant_service_charge_rules for insert to authenticated
with check (
  public.is_system_admin()
  or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_service_charge_rules.restaurant_id
      and ru.role in ('owner','admin')
  )
);

create policy "Owners and admins update service charge rules"
on public.restaurant_service_charge_rules for update to authenticated
using (
  public.is_system_admin()
  or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_service_charge_rules.restaurant_id
      and ru.role in ('owner','admin')
  )
)
with check (
  public.is_system_admin()
  or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_service_charge_rules.restaurant_id
      and ru.role in ('owner','admin')
  )
);

create policy "Owners and admins delete service charge rules"
on public.restaurant_service_charge_rules for delete to authenticated
using (
  public.is_system_admin()
  or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_service_charge_rules.restaurant_id
      and ru.role in ('owner','admin')
  )
);
