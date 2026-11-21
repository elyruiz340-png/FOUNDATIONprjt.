alter table public.restaurants
  add column if not exists address text,
  add column if not exists contact_number text,
  add column if not exists email text,
  add column if not exists website text,
  add column if not exists logo_url text,
  add column if not exists operating_hours jsonb;

create policy "Owners and admins can update restaurant profile"
on public.restaurants
for update
to authenticated
using (
  public.is_system_admin()
  or exists (
    select 1
    from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurants.id
      and lower(coalesce(ru.role, '')) in ('owner', 'admin')
  )
)
with check (
  public.is_system_admin()
  or exists (
    select 1
    from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurants.id
      and lower(coalesce(ru.role, '')) in ('owner', 'admin')
  )
);