alter table public.manager_pin_reset_challenges
  add column if not exists verification_token_hash text;

drop function if exists public.reset_manager_pin_with_otp(uuid,text);
create function public.reset_manager_pin_with_otp(p_challenge_id uuid, p_new_pin text, p_verification_token_hash text)
returns table(manager_user_id uuid, restaurant_id uuid, manager_restaurant_user_id uuid)
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_challenge public.manager_pin_reset_challenges%rowtype;
  v_user public.restaurant_users%rowtype;
begin
  if p_new_pin is null or p_new_pin !~ '^[0-9]{6}$' then raise exception 'PIN must be exactly 6 digits'; end if;
  if p_verification_token_hash is null or length(p_verification_token_hash) <> 64 then raise exception 'Verified reset token required'; end if;
  select * into v_challenge from public.manager_pin_reset_challenges
  where id=p_challenge_id for update;
  if not found or v_challenge.verified_at is null then raise exception 'Verified reset code required'; end if;
  if v_challenge.consumed_at is not null then raise exception 'Reset code has already been used'; end if;
  if v_challenge.expires_at <= now() then raise exception 'Reset code has expired'; end if;
  if v_challenge.verification_token_hash is distinct from p_verification_token_hash then raise exception 'Invalid or expired reset token'; end if;

  select * into v_user from public.restaurant_users
  where id=v_challenge.manager_restaurant_user_id
    and user_id=v_challenge.manager_user_id
    and restaurant_id=v_challenge.restaurant_id
    and lower(role)='staff'
    and lower(coalesce(position,''))='manager'
    and is_active=true
    and manager_can_change_pin=true
  for update;
  if not found then raise exception 'Manager PIN reset is not enabled for this account'; end if;

  update public.cashier_credentials
    set pin_hash=extensions.crypt(p_new_pin,extensions.gen_salt('bf')),
        failed_attempts=0,locked_at=null,updated_at=now()
  where restaurant_user_id=v_user.id;
  if not found then raise exception 'Manager PIN record not found'; end if;

  update public.manager_pin_reset_challenges set consumed_at=now(),verification_token_hash=null where id=p_challenge_id;
  return query select v_user.user_id,v_user.restaurant_id,v_user.id;
end;
$function$;
revoke all on function public.reset_manager_pin_with_otp(uuid,text,text) from public, anon, authenticated;
grant execute on function public.reset_manager_pin_with_otp(uuid,text,text) to service_role;
