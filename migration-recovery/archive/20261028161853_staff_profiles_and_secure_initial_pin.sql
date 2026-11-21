
alter table public.restaurant_users
  add column if not exists full_name text,
  add column if not exists display_name text,
  add column if not exists position text,
  add column if not exists permissions jsonb not null
    default '{"orders":true,"tables":true,"stocks":true,"dispatcher":false,"settings":false}'::jsonb;

create unique index if not exists restaurant_users_cashier_username_lower_uidx
  on public.restaurant_users (lower(cashier_username))
  where cashier_username is not null and btrim(cashier_username) <> '';

create or replace function public.create_staff_record_with_pin(
  p_user_id uuid,
  p_restaurant_id uuid,
  p_full_name text,
  p_display_name text,
  p_position text,
  p_username text,
  p_permissions jsonb,
  p_pin text
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_staff_id uuid;
  v_permissions jsonb;
begin
  if p_user_id is null or p_restaurant_id is null then
    raise exception 'Missing account or restaurant identifier';
  end if;

  if p_full_name is null or length(btrim(p_full_name)) < 1 or length(btrim(p_full_name)) > 100 then
    raise exception 'Full name is required and must be at most 100 characters';
  end if;

  if p_display_name is not null and length(btrim(p_display_name)) > 60 then
    raise exception 'Display name must be at most 60 characters';
  end if;

  if p_position not in ('Cashier','Manager','Kitchen Staff','Dispatcher') then
    raise exception 'Invalid staff position';
  end if;

  if p_username is null or p_username !~ '^[A-Za-z0-9._-]{3,40}$' then
    raise exception 'Invalid username format';
  end if;

  if p_pin is null or p_pin !~ '^[0-9]{6}$' then
    raise exception 'PIN must contain exactly six digits';
  end if;

  if jsonb_typeof(coalesce(p_permissions, '{}'::jsonb)) <> 'object' then
    raise exception 'Permissions must be an object';
  end if;

  v_permissions := jsonb_build_object(
    'orders', coalesce((p_permissions->>'orders')::boolean, false),
    'tables', coalesce((p_permissions->>'tables')::boolean, false),
    'stocks', coalesce((p_permissions->>'stocks')::boolean, false),
    'dispatcher', coalesce((p_permissions->>'dispatcher')::boolean, false),
    'settings', coalesce((p_permissions->>'settings')::boolean, false)
  );

  insert into public.restaurant_users
    (user_id, restaurant_id, role, cashier_username, full_name, display_name, position, permissions)
  values
    (p_user_id, p_restaurant_id, 'staff', btrim(p_username), btrim(p_full_name),
     nullif(btrim(coalesce(p_display_name, '')), ''), p_position, v_permissions)
  returning id into v_staff_id;

  insert into public.cashier_credentials
    (restaurant_user_id, pin_hash, failed_attempts, locked_at, updated_at)
  values
    (v_staff_id, extensions.crypt(p_pin, extensions.gen_salt('bf')), 0, null, now());

  return v_staff_id;
end;
$$;

revoke all on function public.create_staff_record_with_pin(uuid,uuid,text,text,text,text,jsonb,text) from public, anon, authenticated;
grant execute on function public.create_staff_record_with_pin(uuid,uuid,text,text,text,text,jsonb,text) to service_role;
