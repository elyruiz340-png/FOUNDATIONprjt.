
create or replace function public.verify_cashier_login_credentials(p_username text,p_pin text)
returns table(cashier_user_id uuid)
language plpgsql security definer set search_path=''
as $function$
declare
 v_user_id uuid;
 v_restaurant_user_id uuid;
 v_pin_hash text;
 v_failed_attempts integer;
 v_locked_at timestamptz;
begin
 if p_username is null or length(trim(p_username))=0 or p_pin is null or p_pin !~ '^[0-9]{6}$' then
  return;
 end if;

 select ru.id,ru.user_id,cc.pin_hash,cc.failed_attempts,cc.locked_at
 into v_restaurant_user_id,v_user_id,v_pin_hash,v_failed_attempts,v_locked_at
 from public.restaurant_users ru
 join public.cashier_credentials cc on cc.restaurant_user_id=ru.id
 where lower(ru.cashier_username)=lower(trim(p_username))
  and lower(ru.role)='staff'
  and ru.is_active=true
  and exists(
   select 1 from public.staff_branch_access sba
   join public.restaurant_branches b on b.id=sba.branch_id
   where sba.restaurant_user_id=ru.id
    and sba.restaurant_id=ru.restaurant_id
    and sba.is_active=true and b.is_active=true
  )
 for update of cc;

 if not found or v_locked_at is not null or v_pin_hash is null then
  return;
 end if;

 if extensions.crypt(p_pin,v_pin_hash)=v_pin_hash then
  update public.cashier_credentials
   set failed_attempts=0,locked_at=null,updated_at=now()
   where restaurant_user_id=v_restaurant_user_id;
  return query select v_user_id;
  return;
 end if;

 update public.cashier_credentials
  set failed_attempts=least(coalesce(v_failed_attempts,0)+1,5),
      locked_at=case when coalesce(v_failed_attempts,0)+1>=5 then now() else null end,
      updated_at=now()
  where restaurant_user_id=v_restaurant_user_id;
 return;
end;
$function$;
