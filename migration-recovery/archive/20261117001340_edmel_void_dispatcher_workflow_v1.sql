
-- EDMEL: secure order void workflow and dispatcher transitions (test project)
alter table public.orders drop constraint if exists orders_order_status_check;
alter table public.orders add constraint orders_order_status_check
  check (order_status = any (array['pending','confirmed','preparing','ready','served','completed','cancelled','voided']::text[]));

create or replace function public.sync_order_status_legacy()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.order_status := case lower(coalesce(new.status, ''))
    when 'new' then 'pending'
    when 'pending' then 'pending'
    when 'accepted' then 'confirmed'
    when 'confirmed' then 'confirmed'
    when 'preparing' then 'preparing'
    when 'ready' then 'ready'
    when 'served' then 'served'
    when 'completed' then 'completed'
    when 'cancelled' then 'cancelled'
    when 'voided' then 'voided'
    else new.order_status
  end;
  return new;
end;
$$;

create table if not exists public.order_void_requests (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  order_id uuid not null references public.orders(id) on delete restrict,
  reason text not null check (length(btrim(reason)) between 3 and 500),
  request_status text not null default 'pending'
    check (request_status in ('pending','approved','rejected','voided')),
  requested_by_user_id uuid not null references auth.users(id),
  requested_by_staff_id uuid not null references public.restaurant_users(id),
  requested_by_session_id uuid not null references public.staff_sessions(id),
  requested_by_name text,
  requested_order_status text not null,
  approved_by_user_id uuid references auth.users(id),
  approved_by_staff_id uuid references public.restaurant_users(id),
  approved_by_session_id uuid references public.staff_sessions(id),
  approved_by_name text,
  approval_reason text,
  created_at timestamptz not null default now(),
  approved_at timestamptz,
  voided_at timestamptz,
  constraint order_void_requests_one_per_order unique(order_id)
);

create index if not exists order_void_requests_restaurant_created_idx
  on public.order_void_requests(restaurant_id, created_at desc);

alter table public.order_void_requests enable row level security;
revoke all on public.order_void_requests from anon, authenticated;
grant select on public.order_void_requests to authenticated;

drop policy if exists "Cashier can update order status" on public.orders;

create or replace function public.edmel_void_order(
  p_order_id uuid,
  p_session_id uuid,
  p_reason text,
  p_action text default 'request',
  p_void_request_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor record;
  v_order public.orders%rowtype;
  v_request public.order_void_requests%rowtype;
  v_status text;
  v_needs_approval boolean;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_reason is null or length(btrim(p_reason)) < 3 or length(btrim(p_reason)) > 500 then
    raise exception 'A reason between 3 and 500 characters is required';
  end if;

  select ru.id, ru.restaurant_id, ru.role, ru.position, ru.permissions,
         coalesce(nullif(btrim(ru.display_name),''),nullif(btrim(ru.full_name),''),'Staff') as actor_name
    into v_actor
  from public.restaurant_users ru
  where ru.user_id = auth.uid() and ru.is_active = true
  order by case lower(ru.role) when 'owner' then 1 when 'admin' then 2 else 3 end
  limit 1;
  if v_actor.id is null then raise exception 'Active staff account required'; end if;

  if not exists (
    select 1 from public.staff_sessions ss
    where ss.id = p_session_id and ss.user_id = auth.uid()
      and ss.restaurant_user_id = v_actor.id and ss.restaurant_id = v_actor.restaurant_id
      and ss.logout_at is null
      and coalesce(ss.last_activity_at,ss.last_seen_at,ss.login_at) > now() - interval '30 minutes'
  ) then raise exception 'An active staff session is required'; end if;

  select * into v_order from public.orders
   where id = p_order_id and restaurant_id = v_actor.restaurant_id for update;
  if not found then raise exception 'Order not found for this restaurant'; end if;
  if lower(coalesce(v_order.status,'')) = 'voided' then
    return jsonb_build_object('success',false,'message','Order is already voided');
  end if;
  if lower(coalesce(v_order.payment_status,'')) in ('paid','refunded') or v_order.settled_at is not null then
    raise exception 'Paid or refunded orders require a separate refund/correction workflow';
  end if;

  v_status := lower(coalesce(v_order.status,''));
  v_needs_approval := v_status in ('preparing','ready');

  if p_action = 'request' then
    if lower(v_actor.role) not in ('staff','cashier') or coalesce((v_actor.permissions->>'orders')::boolean,false) is not true
       or coalesce((v_actor.permissions->>'void')::boolean,false) is not true then
      raise exception 'Orders Void permission required';
    end if;
    if v_status not in ('new','pending','accepted','confirmed','preparing','ready') then
      raise exception 'This order status cannot be voided';
    end if;
    if v_needs_approval then
      insert into public.order_void_requests(
        restaurant_id,order_id,reason,request_status,requested_by_user_id,
        requested_by_staff_id,requested_by_session_id,requested_by_name,requested_order_status
      ) values (
        v_actor.restaurant_id,v_order.id,btrim(p_reason),'pending',auth.uid(),
        v_actor.id,p_session_id,v_actor.actor_name,v_status
      )
      on conflict(order_id) do nothing
      returning * into v_request;
      if v_request.id is null then raise exception 'A void request already exists for this order'; end if;
      insert into public.audit_logs(restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,record_type,record_id,result,details)
      values(v_actor.restaurant_id,auth.uid(),v_actor.actor_name,v_actor.role,'orders','void_requested','order',v_order.id::text,'success',
        jsonb_build_object('reason',btrim(p_reason),'status',v_status,'request_id',v_request.id));
      return jsonb_build_object('success',true,'approval_required',true,'request_id',v_request.id);
    end if;

    insert into public.order_void_requests(
      restaurant_id,order_id,reason,request_status,requested_by_user_id,
      requested_by_staff_id,requested_by_session_id,requested_by_name,requested_order_status,
      voided_at
    ) values (
      v_actor.restaurant_id,v_order.id,btrim(p_reason),'voided',auth.uid(),
      v_actor.id,p_session_id,v_actor.actor_name,v_status,now()
    ) returning * into v_request;

    update public.orders set status='voided',updated_at=now()
     where id=v_order.id and restaurant_id=v_actor.restaurant_id;
    insert into public.audit_logs(restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,record_type,record_id,result,details)
    values(v_actor.restaurant_id,auth.uid(),v_actor.actor_name,v_actor.role,'orders','order_voided','order',v_order.id::text,'success',
      jsonb_build_object('reason',btrim(p_reason),'previous_status',v_status,'inventory_adjustment','not_applied_unverified_mapping'));
    return jsonb_build_object('success',true,'voided',true,'inventory_adjustment','not_applied_unverified_mapping');
  elsif p_action = 'approve' then
    if lower(coalesce(v_actor.position,'')) <> 'manager' and lower(v_actor.role) not in ('owner','admin') then
      raise exception 'Manager or Owner/Admin approval required';
    end if;
    select * into v_request from public.order_void_requests
      where id=p_void_request_id and order_id=v_order.id and restaurant_id=v_actor.restaurant_id
      for update;
    if not found or v_request.request_status <> 'pending' then
      raise exception 'Pending void request not found';
    end if;
    if v_request.requested_by_user_id = auth.uid() then
      raise exception 'The requester cannot approve their own void request';
    end if;
    if v_status not in ('preparing','ready') then raise exception 'Order status changed; approval is no longer valid'; end if;

    update public.order_void_requests set request_status='voided',
      approved_by_user_id=auth.uid(),approved_by_staff_id=v_actor.id,
      approved_by_session_id=p_session_id,approved_by_name=v_actor.actor_name,
      approval_reason=btrim(p_reason),approved_at=now(),voided_at=now()
      where id=v_request.id;
    update public.orders set status='voided',updated_at=now()
      where id=v_order.id and restaurant_id=v_actor.restaurant_id;
    insert into public.audit_logs(restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,record_type,record_id,result,details)
    values(v_actor.restaurant_id,auth.uid(),v_actor.actor_name,v_actor.role,'orders','order_void_approved','order',v_order.id::text,'success',
      jsonb_build_object('request_reason',v_request.reason,'approval_reason',btrim(p_reason),'previous_status',v_status,'inventory_adjustment','not_applied_unverified_mapping'));
    return jsonb_build_object('success',true,'voided',true,'inventory_adjustment','not_applied_unverified_mapping');
  elsif p_action = 'reject' then
    if lower(coalesce(v_actor.position,'')) <> 'manager' and lower(v_actor.role) not in ('owner','admin') then
      raise exception 'Manager or Owner/Admin approval required';
    end if;
    select * into v_request from public.order_void_requests
      where id=p_void_request_id and order_id=v_order.id and restaurant_id=v_actor.restaurant_id
      for update;
    if not found or v_request.request_status <> 'pending' then raise exception 'Pending void request not found'; end if;
    if v_request.requested_by_user_id = auth.uid() then raise exception 'The requester cannot review their own request'; end if;
    update public.order_void_requests set request_status='rejected',
      approved_by_user_id=auth.uid(),approved_by_staff_id=v_actor.id,
      approved_by_session_id=p_session_id,approved_by_name=v_actor.actor_name,
      approval_reason=btrim(p_reason),approved_at=now()
      where id=v_request.id;
    return jsonb_build_object('success',true,'rejected',true);
  end if;
  raise exception 'Unsupported void action';
end;
$$;

revoke all on function public.edmel_void_order(uuid,uuid,text,text,uuid) from public, anon;
grant execute on function public.edmel_void_order(uuid,uuid,text,text,uuid) to authenticated;

create or replace function public.edmel_dispatcher_update_order(
  p_order_id uuid, p_session_id uuid, p_status text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff record;
  v_order public.orders%rowtype;
  v_current text;
  v_next text := lower(coalesce(p_status,''));
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if v_next not in ('preparing','ready','served') then raise exception 'Unsupported Dispatcher status'; end if;
  select ru.id,ru.restaurant_id,ru.role,ru.position,ru.permissions,
    coalesce(nullif(btrim(ru.display_name),''),nullif(btrim(ru.full_name),''),'Dispatcher') actor_name
    into v_staff from public.restaurant_users ru
    where ru.user_id=auth.uid() and ru.is_active=true
    order by ru.id limit 1;
  if v_staff.id is null or lower(coalesce(v_staff.position,'')) <> 'dispatcher'
     or coalesce((v_staff.permissions->>'dispatcher')::boolean,false) is not true then
    raise exception 'Active Dispatcher permission required';
  end if;
  if not exists(select 1 from public.staff_sessions ss where ss.id=p_session_id
    and ss.user_id=auth.uid() and ss.restaurant_user_id=v_staff.id
    and ss.restaurant_id=v_staff.restaurant_id and ss.logout_at is null
    and coalesce(ss.last_activity_at,ss.last_seen_at,ss.login_at)>now()-interval '30 minutes') then
    raise exception 'Active Dispatcher session required';
  end if;
  select * into v_order from public.orders where id=p_order_id
    and restaurant_id=v_staff.restaurant_id for update;
  if not found then raise exception 'Order not found for this restaurant'; end if;
  v_current:=lower(coalesce(v_order.status,''));
  if v_current='voided' then raise exception 'Voided orders cannot be updated'; end if;
  if (v_next='preparing' and v_current not in ('new','pending','accepted','confirmed'))
    or (v_next='ready' and v_current<>'preparing')
    or (v_next='served' and v_current<>'ready') then
    raise exception 'Order status has changed or transition is not allowed';
  end if;
  update public.orders set status=v_next,
    completed_at=case when v_next='served' then now() else completed_at end,
    updated_at=now()
    where id=v_order.id and restaurant_id=v_staff.restaurant_id;
  insert into public.audit_logs(restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,record_type,record_id,result,details)
  values(v_staff.restaurant_id,auth.uid(),v_staff.actor_name,v_staff.role,'orders','dispatcher_status_updated','order',v_order.id::text,'success',
    jsonb_build_object('from',v_current,'to',v_next));
  return jsonb_build_object('success',true,'order_id',v_order.id,'status',v_next);
end;
$$;
revoke all on function public.edmel_dispatcher_update_order(uuid,uuid,text) from public, anon;
grant execute on function public.edmel_dispatcher_update_order(uuid,uuid,text) to authenticated;
