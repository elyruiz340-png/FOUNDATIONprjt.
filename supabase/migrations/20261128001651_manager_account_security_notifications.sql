create table if not exists public.manager_pin_reset_challenges (
  id uuid primary key default gen_random_uuid(),
  manager_restaurant_user_id uuid not null references public.restaurant_users(id) on delete cascade,
  manager_user_id uuid not null references auth.users(id) on delete cascade,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  otp_hash text not null,
  expires_at timestamptz not null,
  attempts smallint not null default 0 check (attempts between 0 and 5),
  verified_at timestamptz,
  consumed_at timestamptz,
  last_sent_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index if not exists manager_pin_reset_challenges_target_created_idx
  on public.manager_pin_reset_challenges(manager_restaurant_user_id, created_at desc);

create table if not exists public.manager_security_notifications (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  actor_user_id uuid references auth.users(id) on delete set null,
  recipient_user_id uuid not null references auth.users(id) on delete cascade,
  event_type text not null check (event_type in ('password_changed','password_reset','pin_changed','pin_reset')),
  title text not null,
  message text not null,
  is_read boolean not null default false,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists manager_security_notifications_recipient_idx
  on public.manager_security_notifications(recipient_user_id, restaurant_id, created_at desc);

alter table public.manager_security_notifications enable row level security;
revoke all on public.manager_security_notifications from anon, authenticated;
grant select on public.manager_security_notifications to authenticated;
grant update (is_read, read_at) on public.manager_security_notifications to authenticated;

drop policy if exists "Admins can view own manager security notifications" on public.manager_security_notifications;
create policy "Admins can view own manager security notifications"
on public.manager_security_notifications for select to authenticated
using (
  recipient_user_id = (select auth.uid())
  and exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = manager_security_notifications.restaurant_id
      and lower(ru.role) in ('owner','admin')
      and coalesce(ru.is_active,true) = true
  )
);
drop policy if exists "Admins can mark own manager security notifications read" on public.manager_security_notifications;
create policy "Admins can mark own manager security notifications read"
on public.manager_security_notifications for update to authenticated
using (
  recipient_user_id = (select auth.uid())
  and exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = manager_security_notifications.restaurant_id
      and lower(ru.role) in ('owner','admin')
      and coalesce(ru.is_active,true) = true
  )
)
with check (
  recipient_user_id = (select auth.uid())
  and exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = manager_security_notifications.restaurant_id
      and lower(ru.role) in ('owner','admin')
      and coalesce(ru.is_active,true) = true
  )
);

create or replace function public.manager_change_own_pin(p_current_pin text, p_new_pin text)
returns void
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
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_current_pin is null or p_current_pin !~ '^[0-9]{6}$'
     or p_new_pin is null or p_new_pin !~ '^[0-9]{6}$' then
    raise exception 'PIN must be exactly 6 digits';
  end if;
  if p_current_pin = p_new_pin then raise exception 'Choose a new PIN different from the current PIN'; end if;

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

  if v_ru_id is null or v_pin_hash is null then
    raise exception 'Manager PIN change is not enabled for this account';
  end if;
  if v_locked is not null then raise exception 'PIN is locked. Contact the Owner or Admin for assistance.'; end if;

  if extensions.crypt(p_current_pin, v_pin_hash) <> v_pin_hash then
    update public.cashier_credentials
      set failed_attempts = least(coalesce(v_failed,0)+1,5),
          locked_at = case when coalesce(v_failed,0)+1 >= 5 then now() else null end,
          updated_at = now()
    where restaurant_user_id = v_ru_id;
    raise exception 'Current PIN is incorrect';
  end if;

  update public.cashier_credentials
    set pin_hash = extensions.crypt(p_new_pin, extensions.gen_salt('bf')),
        failed_attempts = 0,
        locked_at = null,
        updated_at = now()
  where restaurant_user_id = v_ru_id;
end;
$function$;
revoke all on function public.manager_change_own_pin(text,text) from public, anon;
grant execute on function public.manager_change_own_pin(text,text) to authenticated;

create or replace function public.verify_manager_pin_reset_otp(p_challenge_id uuid, p_otp_hash text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_challenge public.manager_pin_reset_challenges%rowtype;
begin
  select * into v_challenge
  from public.manager_pin_reset_challenges
  where id = p_challenge_id
  for update;
  if not found then return 'invalid'; end if;
  if v_challenge.consumed_at is not null then return 'used'; end if;
  if v_challenge.expires_at <= now() then return 'expired'; end if;
  if v_challenge.attempts >= 5 then return 'locked'; end if;
  if v_challenge.verified_at is not null then return 'verified'; end if;
  if v_challenge.otp_hash = p_otp_hash then
    update public.manager_pin_reset_challenges set verified_at=now() where id=p_challenge_id;
    return 'verified';
  end if;
  update public.manager_pin_reset_challenges set attempts=attempts+1 where id=p_challenge_id;
  return 'invalid';
end;
$function$;
revoke all on function public.verify_manager_pin_reset_otp(uuid,text) from public, anon, authenticated;
grant execute on function public.verify_manager_pin_reset_otp(uuid,text) to service_role;

create or replace function public.reset_manager_pin_with_otp(p_challenge_id uuid, p_new_pin text)
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
  select * into v_challenge from public.manager_pin_reset_challenges
  where id=p_challenge_id for update;
  if not found or v_challenge.verified_at is null then raise exception 'Verified reset code required'; end if;
  if v_challenge.consumed_at is not null then raise exception 'Reset code has already been used'; end if;
  if v_challenge.expires_at <= now() then raise exception 'Reset code has expired'; end if;

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

  update public.manager_pin_reset_challenges set consumed_at=now() where id=p_challenge_id;
  return query select v_user.user_id,v_user.restaurant_id,v_user.id;
end;
$function$;
revoke all on function public.reset_manager_pin_with_otp(uuid,text) from public, anon, authenticated;
grant execute on function public.reset_manager_pin_with_otp(uuid,text) to service_role;
