
create policy "Staff can view restaurant void requests"
on public.order_void_requests for select to authenticated
using (exists (
  select 1 from public.restaurant_users ru
  where ru.user_id=auth.uid() and ru.restaurant_id=order_void_requests.restaurant_id
    and ru.is_active=true
));

create or replace function public.create_staff_profile_with_pin(
  p_actor_user_id uuid,p_staff_user_id uuid,p_restaurant_id uuid,
  p_full_name text,p_display_name text,p_position text,p_username text,
  p_permissions jsonb,p_pin text
) returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_restaurant_user_id uuid;
begin
  if p_actor_user_id is null or p_staff_user_id is null or p_restaurant_id is null then
    raise exception 'Missing required account context' using errcode='22023';
  end if;
  if not exists(select 1 from public.restaurant_users ru where ru.user_id=p_actor_user_id
    and ru.restaurant_id=p_restaurant_id and lower(ru.role) in ('owner','admin') and ru.is_active=true) then
    raise exception 'Not authorized to create staff for this restaurant' using errcode='42501';
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
  if p_username is null or length(btrim(p_username))<3 or length(btrim(p_username))>40
    or btrim(p_username)!~'^[A-Za-z0-9._-]+$' then
    raise exception 'Invalid username format' using errcode='22023';
  end if;
  if p_pin is null or p_pin!~'^[0-9]{6}$' then
    raise exception 'PIN must contain exactly six digits' using errcode='22023';
  end if;
  if p_permissions is null or jsonb_typeof(p_permissions)<>'object'
    or not (p_permissions ?& array['orders','tables','stocks','dispatcher','settings'])
    or exists(select 1 from jsonb_each(p_permissions) e
      where e.key not in ('orders','tables','stocks','dispatcher','settings','void')
        or jsonb_typeof(e.value)<>'boolean')
    or (p_permissions ? 'void' and jsonb_typeof(p_permissions->'void')<>'boolean') then
    raise exception 'Invalid staff permissions' using errcode='22023';
  end if;
  if exists(select 1 from public.restaurant_users ru where lower(ru.cashier_username)=lower(btrim(p_username))) then
    raise exception 'Username already exists' using errcode='23505';
  end if;
  insert into public.restaurant_users(user_id,restaurant_id,role,cashier_username,full_name,display_name,position,permissions)
  values(p_staff_user_id,p_restaurant_id,'staff',btrim(p_username),btrim(p_full_name),
    nullif(btrim(coalesce(p_display_name,'')),''),p_position,p_permissions)
  returning id into v_restaurant_user_id;
  insert into public.cashier_credentials(restaurant_user_id,pin_hash,failed_attempts,locked_at,updated_at)
  values(v_restaurant_user_id,extensions.crypt(p_pin,extensions.gen_salt('bf')),0,null,now());
  return v_restaurant_user_id;
end;
$$;
