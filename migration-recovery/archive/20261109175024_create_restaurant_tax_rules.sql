
create table public.restaurant_tax_rules (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  rule_name text not null check (char_length(trim(rule_name)) between 2 and 120),
  tax_type text not null check (tax_type in ('VAT','PERCENTAGE_TAX','US_SALES_TAX','OTHER')),
  rate numeric(7,4) not null check (rate >= 0 and rate <= 100),
  calculation_method text not null default 'exclusive'
    check (calculation_method in ('exclusive','inclusive')),
  tax_scope text not null default 'all_sales'
    check (tax_scope in ('all_sales','taxable_items_only')),
  effective_from date not null,
  effective_to date,
  is_active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  constraint restaurant_tax_rules_effective_dates_check
    check (effective_to is null or effective_to >= effective_from)
);

create index restaurant_tax_rules_restaurant_effective_idx
  on public.restaurant_tax_rules (restaurant_id, effective_from desc);

alter table public.restaurant_tax_rules enable row level security;
grant select, insert, update, delete on public.restaurant_tax_rules to authenticated;

create policy "Owners and admins view restaurant tax rules"
on public.restaurant_tax_rules for select to authenticated
using (
  public.is_system_admin()
  or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_tax_rules.restaurant_id
      and ru.role in ('owner','admin')
  )
);

create policy "Owners and admins insert restaurant tax rules"
on public.restaurant_tax_rules for insert to authenticated
with check (
  public.is_system_admin()
  or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_tax_rules.restaurant_id
      and ru.role in ('owner','admin')
  )
);

create policy "Owners and admins update restaurant tax rules"
on public.restaurant_tax_rules for update to authenticated
using (
  public.is_system_admin()
  or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_tax_rules.restaurant_id
      and ru.role in ('owner','admin')
  )
)
with check (
  public.is_system_admin()
  or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_tax_rules.restaurant_id
      and ru.role in ('owner','admin')
  )
);

create policy "Owners and admins delete restaurant tax rules"
on public.restaurant_tax_rules for delete to authenticated
using (
  public.is_system_admin()
  or exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_tax_rules.restaurant_id
      and ru.role in ('owner','admin')
  )
);
