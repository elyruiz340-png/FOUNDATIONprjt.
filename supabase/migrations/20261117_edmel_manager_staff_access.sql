
create or replace function public.edmel_create_staff_profile_with_pin(
 p_actor_user_id uuid,p_staff_user_id uuid,p_restaurant_id uuid,p_branch_id uuid,
 p_full_name text,p_display_name text,p_position text,p_username text,p_permissions jsonb,p_pin text
) returns uuid
language plpgsql security definer set search_path=''
as $$
declare
 v_staff_id uuid;
 v_actor_role text;
 v_actor_position text;
 v_actor_permissions jsonb;
 v_is_owner_admin boolean := false;
 v_final_permissions jsonb;
begin
 if p_actor_user_id is null or p_staff_user_id is null or p_restaurant_id is null or p_branch_id is null then
  raise exception 'Missing required account or branch context' using errcode='22023';
 end if;
 if not exists(select 1 from public.restaurant_branches b where b.id=p_branch_id and b.restaurant_id=p_restaurant_id and b.is_active=true) then
  raise exception 'Branch not found or inactive' using errcode='22023';
 end if;
 select lower(ru.role),lower(coalesce(ru.position,'')) into v_actor_role,v_actor_position
 from public.restaurant_users ru
 where ru.user_id=p_actor_user_id and ru.restaurant_id=p_restaurant_id and ru.is_active=true
 order by case when lower(ru.role) in ('owner','admin') then 0 else 1 end
 limit 1;
 if v_actor_role is null then
  raise exception 'Active restaurant account required' using errcode='42501';
 end if;
 v_is_owner_admin := v_actor_role in ('owner','admin');
 if not v_is_owner_admin then
  if v_actor_role<>'staff' or v_actor_position<>'manager' then
   raise exception 'Manager access required' using errcode='42501';
  end if;
  select sba.permissions into v_actor_permissions
  from public.staff_branch_access sba
  join public.restaurant_users ru on ru.id=sba.restaurant_user_id
  where ru.user_id=p_actor_user_id and ru.restaurant_id=p_restaurant_id
   and ru.is_active=true and sba.branch_id=p_branch_id and sba.is_active=true
  limit 1;
  if v_actor_permissions is null or not (v_actor_permissions @> '{"staff_management":true}'::jsonb) then
   raise exception 'You do not have staff management access for this branch' using errcode='42501';
  end if;
 end if;
 if p_full_name is null or length(btrim(p_full_name))=0 or length(btrim(p_full_name))>100 then
  raise exception 'Full name is required and must be at most 100 characters' using errcode='22023';
 end if;
 if p_display_name is not null and length(btrim(p_display_name))>60 then
  raise exception 'Display name must be at most 60 characters' using errcode='22023';
 end if;
 if p_position not in ('Cashier','Manager','Kitchen Staff','Dispatcher') then
  raise exception 'Invalid staff position' using errcode='22023';
 end if;
 if not v_is_owner_admin and p_position='Manager' then
  raise exception 'Managers cannot create or promote another Manager' using errcode='42501';
 end if;
 if p_username is null or length(btrim(p_username))<3 or length(btrim(p_username))>40
  or btrim(p_username)!~'^[A-Za-z0-9._-]+$' then
  raise exception 'Invalid username format' using errcode='22023';
 end if;
 if p_pin is null or p_pin!~'^[0-9]{6}$' then
  raise exception 'PIN must contain exactly six digits' using errcode='22023';
 end if;
 if p_permissions is null or jsonb_typeof(p_permissions)<>'object'
  or exists(select 1 from jsonb_each(p_permissions) e
   where e.key not in ('orders','tables','stocks','dispatcher','settings','void','staff_management')
    or jsonb_typeof(e.value)<>'boolean') then
  raise exception 'Invalid staff permissions' using errcode='22023';
 end if;
 if not v_is_owner_admin then
  if p_permissions ? 'staff_management' and coalesce((p_permissions->>'staff_management')::boolean,false) then
   raise exception 'Managers cannot grant staff management or Manager authority' using errcode='42501';
  end if;
  if exists(select 1 from jsonb_each(p_permissions) e
   where e.value='true'::jsonb and not (v_actor_permissions @> jsonb_build_object(e.key,true))) then
   raise exception 'You cannot assign permissions beyond your own branch access' using errcode='42501';
  end if;
 end if;
 v_final_permissions := coalesce(p_permissions,'{}'::jsonb) - 'staff_management';
 if v_is_owner_admin and p_position='Manager' then
  v_final_permissions := v_final_permissions || jsonb_build_object('staff_management',true);
 else
  v_final_permissions := v_final_permissions || jsonb_build_object('staff_management',false);
 end if;
 insert into public.restaurant_users(user_id,restaurant_id,role,cashier_username,full_name,display_name,position,permissions)
 values(p_staff_user_id,p_restaurant_id,'staff',btrim(p_username),btrim(p_full_name),
  nullif(btrim(coalesce(p_display_name,'')),''),p_position,v_final_permissions)
 returning id into v_staff_id;
 insert into public.cashier_credentials(restaurant_user_id,pin_hash,failed_attempts,locked_at,updated_at)
 values(v_staff_id,extensions.crypt(p_pin,extensions.gen_salt('bf')),0,null,now());
 insert into public.staff_branch_access(restaurant_user_id,restaurant_id,branch_id,permissions,is_active,created_by)
 values(v_staff_id,p_restaurant_id,p_branch_id,v_final_permissions,true,p_actor_user_id);
 return v_staff_id;
end;
$$;
revoke all on function public.edmel_create_staff_profile_with_pin(uuid,uuid,uuid,uuid,text,text,text,text,jsonb,text) from public,anon,authenticated;
grant execute on function public.edmel_create_staff_profile_with_pin(uuid,uuid,uuid,uuid,text,text,text,text,jsonb,text) to service_role;

create policy "Managers can view subordinate restaurant staff links"
on public.restaurant_users for select to authenticated
using (
 lower(coalesce(role,''))='staff'
 and lower(coalesce(position,''))<>'manager'
 and exists (
  select 1 from public.staff_branch_access target_access
  where target_access.restaurant_user_id=restaurant_users.id
   and target_access.restaurant_id=restaurant_users.restaurant_id
   and target_access.is_active=true
   and public.edmel_can_manage_branch_staff(target_access.branch_id)
 )
);

create policy "Managers can view subordinate staff session history"
on public.staff_sessions for select to authenticated
using (
 exists (
  select 1 from public.restaurant_users target
  where target.id=staff_sessions.restaurant_user_id
   and target.restaurant_id=staff_sessions.restaurant_id
   and lower(coalesce(target.role,''))='staff'
   and lower(coalesce(target.position,''))<>'manager'
 )
 and staff_sessions.branch_id is not null
 and public.edmel_can_manage_branch_staff(staff_sessions.branch_id)
);
