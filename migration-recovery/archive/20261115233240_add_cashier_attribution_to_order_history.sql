
alter table public.orders
  add column if not exists created_by_name text,
  add column if not exists accepted_by_name text,
  add column if not exists settled_by_name text;

comment on column public.orders.created_by_name is 'Staff display-name snapshot for the cashier who created a manual order.';
comment on column public.orders.accepted_by_name is 'Staff display-name snapshot for the cashier who accepted the order.';
comment on column public.orders.settled_by_name is 'Staff display-name snapshot for the cashier who confirmed payment.';

update public.orders o
set accepted_by_name = (
  select coalesce(nullif(btrim(ru.display_name), ''), nullif(btrim(ru.full_name), ''))
  from public.restaurant_users ru
  where ru.user_id = o.accepted_by_user_id
    and ru.restaurant_id = o.restaurant_id
  order by ru.created_at desc
  limit 1
)
where o.accepted_by_user_id is not null
  and o.accepted_by_name is null;

update public.orders o
set settled_by_name = (
  select coalesce(nullif(btrim(ru.display_name), ''), nullif(btrim(ru.full_name), ''))
  from public.restaurant_users ru
  where ru.user_id = o.settled_by_user_id
    and ru.restaurant_id = o.restaurant_id
  order by ru.created_at desc
  limit 1
)
where o.settled_by_user_id is not null
  and o.settled_by_name is null;

create or replace function public.cashier_accept_order(p_order_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_restaurant_user_id uuid;
  v_restaurant_id uuid;
  v_actor_name text;
  v_order public.orders%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select ru.id, ru.restaurant_id,
         coalesce(nullif(btrim(ru.display_name), ''), nullif(btrim(ru.full_name), ''))
    into v_restaurant_user_id, v_restaurant_id, v_actor_name
  from public.restaurant_users ru
  where ru.user_id = auth.uid()
    and ru.is_active = true
    and lower(ru.role) in ('owner','admin','staff','cashier')
  order by case lower(ru.role) when 'owner' then 1 when 'admin' then 2 else 3 end
  limit 1;

  if v_restaurant_user_id is null then
    raise exception 'Active cashier account not found';
  end if;

  if not exists (
    select 1 from public.staff_sessions ss
    where ss.id = p_session_id
      and ss.user_id = auth.uid()
      and ss.restaurant_user_id = v_restaurant_user_id
      and ss.restaurant_id = v_restaurant_id
      and ss.logout_at is null
  ) then
    raise exception 'Active cashier session required';
  end if;

  select o.* into v_order
  from public.orders o
  where o.id = p_order_id
    and o.restaurant_id = v_restaurant_id
  for update;

  if not found then
    raise exception 'Order not found for this restaurant';
  end if;

  if lower(coalesce(v_order.status, '')) = 'accepted'
     and v_order.accepted_by_session_id = p_session_id then
    return jsonb_build_object(
      'success', true,
      'already_accepted', true,
      'order_id', v_order.id,
      'accepted_at', v_order.accepted_at
    );
  end if;

  update public.orders o
  set status = 'accepted',
      accepted_by_user_id = auth.uid(),
      accepted_by_session_id = p_session_id,
      accepted_by_name = v_actor_name,
      accepted_at = now(),
      updated_at = now()
  where o.id = p_order_id
    and o.restaurant_id = v_restaurant_id
    and lower(coalesce(o.status, 'new')) in ('new','pending','confirmed')
    and o.accepted_at is null
  returning o.* into v_order;

  if not found then
    return jsonb_build_object(
      'success', false,
      'already_accepted', true,
      'message', 'This order has already been accepted by another session or is no longer new.'
    );
  end if;

  return jsonb_build_object(
    'success', true,
    'order_id', v_order.id,
    'accepted_at', v_order.accepted_at
  );
end;
$function$;

create or replace function public.cashier_settle_order(p_order_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_restaurant_user_id uuid;
  v_restaurant_id uuid;
  v_actor_name text;
  v_order public.orders%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select ru.id, ru.restaurant_id,
         coalesce(nullif(btrim(ru.display_name), ''), nullif(btrim(ru.full_name), ''))
    into v_restaurant_user_id, v_restaurant_id, v_actor_name
  from public.restaurant_users ru
  where ru.user_id = auth.uid()
    and ru.is_active = true
    and lower(ru.role) in ('owner','admin','staff','cashier')
  order by case lower(ru.role) when 'owner' then 1 when 'admin' then 2 else 3 end
  limit 1;

  if v_restaurant_user_id is null then
    raise exception 'Active cashier account not found';
  end if;

  if not exists (
    select 1 from public.staff_sessions ss
    where ss.id = p_session_id
      and ss.user_id = auth.uid()
      and ss.restaurant_user_id = v_restaurant_user_id
      and ss.restaurant_id = v_restaurant_id
      and ss.logout_at is null
  ) then
    raise exception 'Active cashier session required';
  end if;

  select o.* into v_order
  from public.orders o
  where o.id = p_order_id
    and o.restaurant_id = v_restaurant_id
  for update;

  if not found then
    raise exception 'Order not found for this restaurant';
  end if;

  if lower(coalesce(v_order.payment_status, '')) in ('paid','successful','succeeded','verified')
     and v_order.settled_by_session_id = p_session_id then
    return jsonb_build_object(
      'success', true,
      'already_settled', true,
      'order_id', v_order.id,
      'settled_at', v_order.settled_at
    );
  end if;

  update public.orders o
  set payment_status = 'paid',
      settled_by_user_id = auth.uid(),
      settled_by_session_id = p_session_id,
      settled_by_name = v_actor_name,
      settled_at = now(),
      updated_at = now()
  where o.id = p_order_id
    and o.restaurant_id = v_restaurant_id
    and lower(coalesce(o.status, '')) in ('served','completed')
    and lower(coalesce(o.payment_status, 'pending')) in ('pending','unpaid','')
    and o.settled_at is null
  returning o.* into v_order;

  if not found then
    return jsonb_build_object(
      'success', false,
      'already_settled', true,
      'message', 'This order is already settled by another session or is not ready for payment.'
    );
  end if;

  return jsonb_build_object(
    'success', true,
    'order_id', v_order.id,
    'settled_at', v_order.settled_at
  );
end;
$function$;

create or replace function public.place_order_with_pricing(
  p_restaurant_id uuid,
  p_table_number text,
  p_order_type text,
  p_items jsonb,
  p_subtotal numeric,
  p_tax numeric,
  p_discount_amount numeric,
  p_service_charge numeric,
  p_total numeric,
  p_payment_method text,
  p_payment_status text,
  p_payment_reference text,
  p_customer_name text,
  p_customer_phone text,
  p_special_instructions text,
  p_submission_key uuid,
  p_session_id uuid,
  p_pricing_breakdown jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_order_id uuid;
  v_result jsonb;
  v_expected_total numeric(14,2);
  v_tax_method text := coalesce(p_pricing_breakdown->>'tax_calculation_method','exclusive');
  v_actor_name text;
begin
  if v_user_id is null then raise exception 'Cashier authentication is required'; end if;
  if p_restaurant_id is null or p_session_id is null or p_submission_key is null then
    raise exception 'Restaurant, cashier session, and submission key are required';
  end if;
  if p_order_type not in ('dine_in','takeout','delivery') then raise exception 'Unsupported order type'; end if;
  if p_subtotal is null or p_tax is null or p_discount_amount is null or p_service_charge is null or p_total is null
     or p_subtotal < 0 or p_tax < 0 or p_discount_amount < 0 or p_service_charge < 0 then
    raise exception 'Invalid pricing values';
  end if;
  if p_discount_amount > p_subtotal then raise exception 'Discount cannot exceed subtotal'; end if;
  if v_tax_method not in ('exclusive','inclusive') then raise exception 'Unsupported tax calculation method'; end if;
  if v_tax_method = 'inclusive' then
    v_expected_total := round(p_subtotal - p_discount_amount + p_service_charge, 2);
  else
    v_expected_total := round(p_subtotal - p_discount_amount + p_service_charge + p_tax, 2);
  end if;
  if abs(v_expected_total - round(p_total, 2)) > 0.01 then
    raise exception 'Pricing total does not match the supplied breakdown';
  end if;
  if not exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = v_user_id and ru.restaurant_id = p_restaurant_id and ru.is_active = true
      and (ru.role in ('owner','admin') or coalesce((ru.permissions->>'orders')::boolean,false) = true)
  ) then raise exception 'This staff account is not authorized to create orders'; end if;
  if not exists (
    select 1 from public.staff_sessions ss
    where ss.id = p_session_id and ss.restaurant_id = p_restaurant_id
      and ss.user_id = v_user_id and ss.logout_at is null
  ) then raise exception 'Active cashier session not found'; end if;

  select coalesce(nullif(btrim(ru.display_name), ''), nullif(btrim(ru.full_name), ''))
    into v_actor_name
  from public.restaurant_users ru
  where ru.user_id = v_user_id
    and ru.restaurant_id = p_restaurant_id
    and ru.is_active = true
  order by ru.created_at desc
  limit 1;

  v_result := public.place_order_with_stock(
    p_restaurant_id,p_table_number,p_order_type,p_items,round(p_total,2),
    p_payment_method,p_payment_status,p_payment_reference,p_special_instructions,p_submission_key
  );
  v_order_id := nullif(v_result->>'order_id','')::uuid;
  if v_order_id is null then raise exception 'Order creation did not return an order ID'; end if;

  update public.orders
  set subtotal=round(p_subtotal,2),tax=round(p_tax,2),
      discount_amount=round(p_discount_amount,2),service_charge=round(p_service_charge,2),
      total=round(p_total,2),pricing_breakdown=coalesce(p_pricing_breakdown,'{}'::jsonb),
      customer_name=nullif(btrim(p_customer_name), ''),
      customer_phone=nullif(btrim(p_customer_phone), ''),
      created_by_name=v_actor_name,
      updated_at=now()
  where id=v_order_id and restaurant_id=p_restaurant_id;

  return v_result || jsonb_build_object(
    'subtotal',round(p_subtotal,2),'tax',round(p_tax,2),
    'discount_amount',round(p_discount_amount,2),'service_charge',round(p_service_charge,2),
    'total',round(p_total,2)
  );
end;
$function$;
