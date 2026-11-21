
drop policy if exists "Authorized managers can add subordinate branch access" on public.staff_branch_access;
drop policy if exists "Authorized managers can remove subordinate branch access" on public.staff_branch_access;
drop policy if exists "Authorized managers can update subordinate branch access" on public.staff_branch_access;

create policy "Owners and admins can add staff branch access"
on public.staff_branch_access for insert to authenticated
with check (public.edmel_is_restaurant_owner_admin(restaurant_id));

create policy "Owners and admins can update staff branch access"
on public.staff_branch_access for update to authenticated
using (public.edmel_is_restaurant_owner_admin(restaurant_id))
with check (public.edmel_is_restaurant_owner_admin(restaurant_id));

create policy "Owners and admins can remove staff branch access"
on public.staff_branch_access for delete to authenticated
using (public.edmel_is_restaurant_owner_admin(restaurant_id));

revoke all on function public.edmel_manager_update_staff_branch_permissions(uuid,uuid,uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.edmel_manager_update_staff_branch_permissions(uuid,uuid,uuid,uuid,jsonb) to service_role;

revoke all on function public.edmel_create_staff_profile_with_pin(uuid,uuid,uuid,uuid,text,text,text,text,jsonb,text) from public, anon, authenticated;
grant execute on function public.edmel_create_staff_profile_with_pin(uuid,uuid,uuid,uuid,text,text,text,text,jsonb,text) to service_role;
