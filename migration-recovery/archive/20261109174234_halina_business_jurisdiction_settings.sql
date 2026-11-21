
create table if not exists public.restaurant_business_settings (
  restaurant_id uuid primary key references public.restaurants(id) on delete cascade,
  country_code text not null default 'PH' check (country_code in ('PH','US')),
  region text,
  city text,
  tax_registration_type text not null default 'NOT_SET'
    check (tax_registration_type in ('NOT_SET','PH_VAT_REGISTERED','PH_NON_VAT','US_SALES_TAX')),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  constraint restaurant_business_settings_region_length check (region is null or char_length(region) <= 120),
  constraint restaurant_business_settings_city_length check (city is null or char_length(city) <= 120)
);

alter table public.restaurant_business_settings enable row level security;

create policy "Restaurant owners and admins manage business settings"
on public.restaurant_business_settings
for all
to authenticated
using (
  public.is_system_admin()
  or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_business_settings.restaurant_id
      and lower(coalesce(ru.role,'')) in ('owner','admin')
  )
)
with check (
  public.is_system_admin()
  or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_business_settings.restaurant_id
      and lower(coalesce(ru.role,'')) in ('owner','admin')
  )
);

grant select, insert, update on public.restaurant_business_settings to authenticated;

insert into public.restaurant_business_settings
  (restaurant_id, country_code, tax_registration_type)
values
  ('5e562ca7-38aa-4894-8265-ddca2f4e61b6', 'PH', 'NOT_SET')
on conflict (restaurant_id) do nothing;
