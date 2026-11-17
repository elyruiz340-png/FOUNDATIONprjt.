
create or replace function public.edmel_is_own_branch_access(p_restaurant_user_id uuid)
returns boolean language sql stable security definer set search_path=''
as $$
 select exists(select 1 from public.restaurant_users ru
  where ru.id=p_restaurant_user_id and ru.user_id=(select auth.uid()));
$$;
create or replace function public.edmel_is_subordinate_staff(p_restaurant_user_id uuid,p_restaurant_id uuid)
returns boolean language sql stable security definer set search_path=''
as $$
 select exists(select 1 from public.restaurant_users target
  where target.id=p_restaurant_user_id and target.restaurant_id=p_restaurant_id
   and lower(coalesce(target.role,''))='staff'
   and lower(coalesce(target.position,''))<>'manager');
$$;
revoke all on function public.edmel_is_own_branch_access(uuid) from public,anon;
revoke all on function public.edmel_is_subordinate_staff(uuid,uuid) from public,anon;
grant execute on function public.edmel_is_own_branch_access(uuid) to authenticated,service_role;
grant execute on function public.edmel_is_subordinate_staff(uuid,uuid) to authenticated,service_role;

drop policy if exists "Users can view their own branch access and authorized staff access" on public.staff_branch_access;
create policy "Users can view their own branch access and authorized staff access"
on public.staff_branch_access for select to authenticated
using (
 public.edmel_is_own_branch_access(restaurant_user_id)
 or public.edmel_is_restaurant_owner_admin(restaurant_id)
 or public.edmel_can_manage_branch_staff(branch_id)
);

drop policy if exists "Authorized managers can add subordinate branch access" on public.staff_branch_access;
create policy "Authorized managers can add subordinate branch access"
on public.staff_branch_access for insert to authenticated
with check (
 public.edmel_is_restaurant_owner_admin(restaurant_id)
 or (
  public.edmel_can_manage_branch_staff(branch_id)
  and public.edmel_can_assign_branch_permissions(branch_id,permissions)
  and public.edmel_is_subordinate_staff(restaurant_user_id,restaurant_id)
 )
);

drop policy if exists "Authorized managers can update subordinate branch access" on public.staff_branch_access;
create policy "Authorized managers can update subordinate branch access"
on public.staff_branch_access for update to authenticated
using (
 public.edmel_is_restaurant_owner_admin(restaurant_id)
 or (
  public.edmel_can_manage_branch_staff(branch_id)
  and public.edmel_is_subordinate_staff(restaurant_user_id,restaurant_id)
 )
)
with check (
 public.edmel_is_restaurant_owner_admin(restaurant_id)
 or (
  public.edmel_can_manage_branch_staff(branch_id)
  and public.edmel_can_assign_branch_permissions(branch_id,permissions)
  and public.edmel_is_subordinate_staff(restaurant_user_id,restaurant_id)
 )
);

drop policy if exists "Authorized managers can remove subordinate branch access" on public.staff_branch_access;
create policy "Authorized managers can remove subordinate branch access"
on public.staff_branch_access for delete to authenticated
using (
 public.edmel_is_restaurant_owner_admin(restaurant_id)
 or (
  public.edmel_can_manage_branch_staff(branch_id)
  and public.edmel_is_subordinate_staff(restaurant_user_id,restaurant_id)
 )
);
