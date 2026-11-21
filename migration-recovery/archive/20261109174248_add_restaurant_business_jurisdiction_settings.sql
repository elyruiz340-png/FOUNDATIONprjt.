
create table if not exists public.restaurant_business_settings (
  restaurant_id uuid primary key references public.restaurants(id) on delete cascade,
  country_code text not null,
  region_code text,
  region_name text,
  city text,
  tax_registration_type text,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  constraint restaurant_business_settings_country_code_check
    check (country_code ~ '^[A-Z]{2}$'),
  constraint restaurant_business_settings_tax_registration_check
    check (
      tax_registration_type is null
      or tax_registration_type in (
        'ph_vat_registered',
        'ph_non_vat',
        'us_sales_tax',
        'other'
      )
    )
);

alter table public.restaurant_business_settings enable row level security;

grant select, insert, update on public.restaurant_business_settings to authenticated;

drop policy if exists "Owners and admins can view business settings"
  on public.restaurant_business_settings;
create policy "Owners and admins can view business settings"
  on public.restaurant_business_settings
  for select
  to authenticated
  using (
    public.is_system_admin()
    or exists (
      select 1
      from public.restaurant_users ru
      where ru.user_id = (select auth.uid())
        and ru.restaurant_id = restaurant_business_settings.restaurant_id
        and ru.role in ('owner', 'admin')
    )
  );

drop policy if exists "Owners and admins can insert business settings"
  on public.restaurant_business_settings;
create policy "Owners and admins can insert business settings"
  on public.restaurant_business_settings
  for insert
  to authenticated
  with check (
    public.is_system_admin()
    or exists (
      select 1
      from public.restaurant_users ru
      where ru.user_id = (select auth.uid())
        and ru.restaurant_id = restaurant_business_settings.restaurant_id
        and ru.role in ('owner', 'admin')
    )
  );

drop policy if exists "Owners and admins can update business settings"
  on public.restaurant_business_settings;
create policy "Owners and admins can update business settings"
  on public.restaurant_business_settings
  for update
  to authenticated
  using (
    public.is_system_admin()
    or exists (
      select 1
      from public.restaurant_users ru
      where ru.user_id = (select auth.uid())
        and ru.restaurant_id = restaurant_business_settings.restaurant_id
        and ru.role in ('owner', 'admin')
    )
  )
  with check (
    public.is_system_admin()
    or exists (
      select 1
      from public.restaurant_users ru
      where ru.user_id = (select auth.uid())
        and ru.restaurant_id = restaurant_business_settings.restaurant_id
        and ru.role in ('owner', 'admin')
    )
  );

insert into public.restaurant_business_settings (restaurant_id, country_code)
select id, 'PH'
from public.restaurants
where slug = 'halina-bistro-cafe'
on conflict (restaurant_id) do nothing;
