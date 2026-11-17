
drop policy if exists "Owners and admins can create restaurant branches" on public.restaurant_branches;
drop policy if exists "Owners and admins can update restaurant branches" on public.restaurant_branches;
drop policy if exists "Owners and admins can delete restaurant branches" on public.restaurant_branches;
revoke insert,update,delete on public.restaurant_branches from authenticated;
grant select on public.restaurant_branches to authenticated;
