create or replace function public.can_view_restaurant_users(target_restaurant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $function$
  select
    public.is_system_admin()
    or exists (
      select 1
      from public.restaurant_users ru
      where ru.user_id = auth.uid()
        and ru.restaurant_id = target_restaurant_id
        and lower(ru.role) in ('owner', 'admin')
    );
$function$;

revoke all on function public.can_view_restaurant_users(uuid) from public;
grant execute on function public.can_view_restaurant_users(uuid) to authenticated;

drop policy if exists "Owners and admins can view restaurant staff links" on public.restaurant_users;

create policy "Owners and admins can view restaurant staff links"
on public.restaurant_users
for select
to authenticated
using (public.can_view_restaurant_users(restaurant_id));