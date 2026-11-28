alter table public.manager_pin_reset_challenges enable row level security;
revoke all on public.manager_pin_reset_challenges from anon, authenticated;
grant all on public.manager_pin_reset_challenges to service_role;
grant all on public.manager_security_notifications to service_role;

drop function if exists public.manager_change_own_pin(text,text);
create function public.manager_change_own_pin(p_current_pin text, p_new_pin text)
returns text
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_ru_id uuid;
  v_pin_hash text;
  v_failed integer;
  v_locked timestamptz;
begin
  if auth.uid() is null then return 'authentication_required'; end if;
  if p_current_pin is null or p_current_pin !~ '^[0-9]{6}$'
     or p_new_pin is null or p_new_pin !~ '^[0-9]{6}$' then return 'invalid_pin'; end if;
  if p_current_pin = p_new_pin then return 'same_pin'; end if;
  select ru.id, cc.pin_hash, cc.failed_attempts, cc.locked_at
    into v_ru_id, v_pin_hash, v_failed, v_locked
  from public.restaurant_users ru
  join public.cashier_credentials cc on cc.restaurant_user_id = ru.id
  where ru.user_id = auth.uid()
    and lower(ru.role) = 'staff'
    and lower(coalesce(ru.position,'')) = 'manager'
    and ru.is_active = true
    and ru.manager_can_change_pin = true
  order by ru.created_at desc
  limit 1
  for update of cc;
  if v_ru_id is null or v_pin_hash is null then return 'disabled'; end if;
  if v_locked is not null then return 'locked'; end if;
  if extensions.crypt(p_current_pin, v_pin_hash) <> v_pin_hash then
    update public.cashier_credentials
      set failed_attempts = least(coalesce(v_failed,0)+1,5),
          locked_at = case when coalesce(v_failed,0)+1 >= 5 then now() else null end,
          updated_at = now()
    where restaurant_user_id = v_ru_id;
    return case when coalesce(v_failed,0)+1 >= 5 then 'locked' else 'incorrect' end;
  end if;
  update public.cashier_credentials
    set pin_hash = extensions.crypt(p_new_pin, extensions.gen_salt('bf')),
        failed_attempts = 0, locked_at = null, updated_at = now()
  where restaurant_user_id = v_ru_id;
  return 'success';
end;
$function$;
revoke all on function public.manager_change_own_pin(text,text) from public, anon;
grant execute on function public.manager_change_own_pin(text,text) to authenticated;
