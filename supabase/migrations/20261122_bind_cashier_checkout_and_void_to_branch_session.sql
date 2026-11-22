-- Bind cashier checkout and void operations to the exact authenticated staff session branch.

CREATE OR REPLACE FUNCTION public.place_order_with_pricing(
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
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_actor record;
  v_order_id uuid;
  v_result jsonb;
  v_expected_total numeric(14,2);
  v_tax_method text := coalesce(p_pricing_breakdown->>'tax_calculation_method','exclusive');
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Cashier authentication is required'; END IF;
  IF p_restaurant_id IS NULL OR p_session_id IS NULL OR p_submission_key IS NULL THEN
    RAISE EXCEPTION 'Restaurant, cashier session, and submission key are required';
  END IF;
  IF p_order_type NOT IN ('dine_in','takeout','delivery') THEN RAISE EXCEPTION 'Unsupported order type'; END IF;
  IF p_subtotal IS NULL OR p_tax IS NULL OR p_discount_amount IS NULL OR p_service_charge IS NULL OR p_total IS NULL
     OR p_subtotal < 0 OR p_tax < 0 OR p_discount_amount < 0 OR p_service_charge < 0 THEN
    RAISE EXCEPTION 'Invalid pricing values';
  END IF;
  IF p_discount_amount > p_subtotal THEN RAISE EXCEPTION 'Discount cannot exceed subtotal'; END IF;
  IF v_tax_method NOT IN ('exclusive','inclusive') THEN RAISE EXCEPTION 'Unsupported tax calculation method'; END IF;

  IF v_tax_method = 'inclusive' THEN
    v_expected_total := round(p_subtotal - p_discount_amount + p_service_charge, 2);
  ELSE
    v_expected_total := round(p_subtotal - p_discount_amount + p_service_charge + p_tax, 2);
  END IF;
  IF abs(v_expected_total - round(p_total, 2)) > 0.01 THEN
    RAISE EXCEPTION 'Pricing total does not match the supplied breakdown';
  END IF;

  SELECT
    ss.restaurant_id,
    ss.branch_id,
    ss.restaurant_user_id,
    ru.role,
    ru.position,
    ru.permissions,
    coalesce(nullif(btrim(ru.display_name), ''), nullif(btrim(ru.full_name), '')) actor_name
  INTO v_actor
  FROM public.staff_sessions ss
  JOIN public.restaurant_users ru
    ON ru.id = ss.restaurant_user_id
   AND ru.restaurant_id = ss.restaurant_id
  WHERE ss.id = p_session_id
    AND ss.restaurant_id = p_restaurant_id
    AND ss.user_id = v_user_id
    AND ru.user_id = v_user_id
    AND ru.is_active = true
    AND ss.logout_at IS NULL
    AND coalesce(ss.last_activity_at, ss.last_seen_at, ss.login_at) > now() - interval '30 minutes';

  IF v_actor.restaurant_user_id IS NULL THEN
    RAISE EXCEPTION 'An active cashier session for this restaurant is required';
  END IF;

  IF lower(coalesce(v_actor.role,'')) NOT IN ('owner','admin','staff','cashier')
     OR NOT public.edmel_has_branch_permission(v_actor.branch_id, 'orders') THEN
    RAISE EXCEPTION 'Order permission is not assigned for this branch';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.restaurant_branches b
    WHERE b.id = v_actor.branch_id
      AND b.restaurant_id = p_restaurant_id
      AND b.is_active = true
  ) THEN
    RAISE EXCEPTION 'The cashier session branch is inactive';
  END IF;

  v_result := public.place_order_with_stock(
    p_restaurant_id,
    p_table_number,
    p_order_type,
    p_items,
    round(p_total,2),
    p_payment_method,
    p_payment_status,
    p_payment_reference,
    p_special_instructions,
    p_submission_key,
    v_actor.branch_id
  );

  v_order_id := nullif(v_result->>'order_id','')::uuid;
  IF v_order_id IS NULL THEN RAISE EXCEPTION 'Order creation did not return an order ID'; END IF;

  UPDATE public.orders
  SET branch_id = v_actor.branch_id,
      subtotal = round(p_subtotal,2),
      tax = round(p_tax,2),
      discount_amount = round(p_discount_amount,2),
      service_charge = round(p_service_charge,2),
      total = round(p_total,2),
      pricing_breakdown = coalesce(p_pricing_breakdown,'{}'::jsonb),
      customer_name = nullif(btrim(p_customer_name), ''),
      customer_phone = nullif(btrim(p_customer_phone), ''),
      created_by_name = v_actor.actor_name,
      updated_at = now()
  WHERE id = v_order_id
    AND restaurant_id = p_restaurant_id
    AND branch_id = v_actor.branch_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'Created order does not match the active cashier branch'; END IF;

  RETURN v_result || jsonb_build_object(
    'subtotal',round(p_subtotal,2),
    'tax',round(p_tax,2),
    'discount_amount',round(p_discount_amount,2),
    'service_charge',round(p_service_charge,2),
    'total',round(p_total,2),
    'branch_id',v_actor.branch_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.edmel_void_order(
  p_order_id uuid,
  p_session_id uuid,
  p_reason text,
  p_action text DEFAULT 'request'::text,
  p_void_request_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_actor record;
  v_order public.orders%rowtype;
  v_request public.order_void_requests%rowtype;
  v_status text;
  v_needs_approval boolean;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 OR length(btrim(p_reason)) > 500 THEN
    RAISE EXCEPTION 'A reason between 3 and 500 characters is required';
  END IF;

  SELECT
    ss.restaurant_id,
    ss.branch_id,
    ss.restaurant_user_id,
    ru.role,
    ru.position,
    ru.permissions,
    coalesce(nullif(btrim(ru.display_name),''),nullif(btrim(ru.full_name),''),'Staff') actor_name
  INTO v_actor
  FROM public.staff_sessions ss
  JOIN public.restaurant_users ru
    ON ru.id = ss.restaurant_user_id
   AND ru.restaurant_id = ss.restaurant_id
  WHERE ss.id = p_session_id
    AND ss.user_id = auth.uid()
    AND ru.user_id = auth.uid()
    AND ru.is_active = true
    AND ss.logout_at IS NULL
    AND coalesce(ss.last_activity_at,ss.last_seen_at,ss.login_at) > now() - interval '30 minutes';

  IF v_actor.restaurant_user_id IS NULL THEN
    RAISE EXCEPTION 'An active staff session is required';
  END IF;

  IF NOT public.edmel_has_branch_permission(v_actor.branch_id, NULL) THEN
    RAISE EXCEPTION 'You are not assigned to the active session branch';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
    AND restaurant_id = v_actor.restaurant_id
    AND branch_id = v_actor.branch_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found for this branch'; END IF;
  IF lower(coalesce(v_order.status,'')) = 'voided' THEN
    RETURN jsonb_build_object('success',false,'message','Order is already voided');
  END IF;
  IF lower(coalesce(v_order.payment_status,'')) IN ('paid','successful','succeeded','verified','refunded')
     OR v_order.settled_at IS NOT NULL THEN
    RAISE EXCEPTION 'Paid or refunded orders require a separate refund/correction workflow';
  END IF;

  v_status := lower(coalesce(v_order.status,''));
  v_needs_approval := v_status IN ('preparing','ready');

  IF p_action = 'request' THEN
    IF lower(v_actor.role) NOT IN ('staff','cashier')
       OR coalesce((v_actor.permissions->>'orders')::boolean,false) IS NOT TRUE
       OR coalesce((v_actor.permissions->>'void')::boolean,false) IS NOT TRUE
       OR NOT public.edmel_has_branch_permission(v_actor.branch_id, 'orders') THEN
      RAISE EXCEPTION 'Orders Void permission required';
    END IF;
    IF v_status NOT IN ('new','pending','accepted','confirmed','preparing','ready') THEN
      RAISE EXCEPTION 'This order status cannot be voided';
    END IF;

    IF v_needs_approval THEN
      INSERT INTO public.order_void_requests(
        restaurant_id,branch_id,order_id,reason,request_status,requested_by_user_id,
        requested_by_staff_id,requested_by_session_id,requested_by_name,requested_order_status
      ) VALUES (
        v_actor.restaurant_id,v_actor.branch_id,v_order.id,btrim(p_reason),'pending',auth.uid(),
        v_actor.restaurant_user_id,p_session_id,v_actor.actor_name,v_status
      )
      ON CONFLICT(order_id) DO NOTHING
      RETURNING * INTO v_request;

      IF v_request.id IS NULL THEN RAISE EXCEPTION 'A void request already exists for this order'; END IF;

      INSERT INTO public.audit_logs(restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,record_type,record_id,result,details)
      VALUES(v_actor.restaurant_id,auth.uid(),v_actor.actor_name,v_actor.role,'orders','void_requested','order',v_order.id::text,'success',
        jsonb_build_object('reason',btrim(p_reason),'status',v_status,'request_id',v_request.id,'branch_id',v_actor.branch_id));
      RETURN jsonb_build_object('success',true,'approval_required',true,'request_id',v_request.id);
    END IF;

    INSERT INTO public.order_void_requests(
      restaurant_id,branch_id,order_id,reason,request_status,requested_by_user_id,
      requested_by_staff_id,requested_by_session_id,requested_by_name,requested_order_status,voided_at
    ) VALUES (
      v_actor.restaurant_id,v_actor.branch_id,v_order.id,btrim(p_reason),'voided',auth.uid(),
      v_actor.restaurant_user_id,p_session_id,v_actor.actor_name,v_status,now()
    ) RETURNING * INTO v_request;

    UPDATE public.orders
    SET status='voided',updated_at=now()
    WHERE id=v_order.id
      AND restaurant_id=v_actor.restaurant_id
      AND branch_id=v_actor.branch_id;

    INSERT INTO public.audit_logs(restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,record_type,record_id,result,details)
    VALUES(v_actor.restaurant_id,auth.uid(),v_actor.actor_name,v_actor.role,'orders','order_voided','order',v_order.id::text,'success',
      jsonb_build_object('reason',btrim(p_reason),'previous_status',v_status,'inventory_adjustment','not_applied_unverified_mapping','branch_id',v_actor.branch_id));
    RETURN jsonb_build_object('success',true,'voided',true,'inventory_adjustment','not_applied_unverified_mapping');

  ELSIF p_action = 'approve' THEN
    IF lower(coalesce(v_actor.position,'')) <> 'manager'
       AND lower(v_actor.role) NOT IN ('owner','admin') THEN
      RAISE EXCEPTION 'Manager or Owner/Admin approval required';
    END IF;
    SELECT * INTO v_request
    FROM public.order_void_requests
    WHERE id=p_void_request_id
      AND order_id=v_order.id
      AND restaurant_id=v_actor.restaurant_id
      AND branch_id=v_actor.branch_id
    FOR UPDATE;
    IF NOT FOUND OR v_request.request_status <> 'pending' THEN
      RAISE EXCEPTION 'Pending void request not found for this branch';
    END IF;
    IF v_request.requested_by_user_id = auth.uid() THEN
      RAISE EXCEPTION 'The requester cannot approve their own void request';
    END IF;
    IF v_status NOT IN ('preparing','ready') THEN
      RAISE EXCEPTION 'Order status changed; approval is no longer valid';
    END IF;

    UPDATE public.order_void_requests
    SET request_status='voided',
        approved_by_user_id=auth.uid(),
        approved_by_staff_id=v_actor.restaurant_user_id,
        approved_by_session_id=p_session_id,
        approved_by_name=v_actor.actor_name,
        approval_reason=btrim(p_reason),
        approved_at=now(),
        voided_at=now()
    WHERE id=v_request.id
      AND restaurant_id=v_actor.restaurant_id
      AND branch_id=v_actor.branch_id;

    UPDATE public.orders
    SET status='voided',updated_at=now()
    WHERE id=v_order.id
      AND restaurant_id=v_actor.restaurant_id
      AND branch_id=v_actor.branch_id;

    INSERT INTO public.audit_logs(restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,record_type,record_id,result,details)
    VALUES(v_actor.restaurant_id,auth.uid(),v_actor.actor_name,v_actor.role,'orders','order_void_approved','order',v_order.id::text,'success',
      jsonb_build_object('request_reason',v_request.reason,'approval_reason',btrim(p_reason),'previous_status',v_status,'inventory_adjustment','not_applied_unverified_mapping','branch_id',v_actor.branch_id));
    RETURN jsonb_build_object('success',true,'voided',true,'inventory_adjustment','not_applied_unverified_mapping');

  ELSIF p_action = 'reject' THEN
    IF lower(coalesce(v_actor.position,'')) <> 'manager'
       AND lower(v_actor.role) NOT IN ('owner','admin') THEN
      RAISE EXCEPTION 'Manager or Owner/Admin approval required';
    END IF;
    SELECT * INTO v_request
    FROM public.order_void_requests
    WHERE id=p_void_request_id
      AND order_id=v_order.id
      AND restaurant_id=v_actor.restaurant_id
      AND branch_id=v_actor.branch_id
    FOR UPDATE;
    IF NOT FOUND OR v_request.request_status <> 'pending' THEN
      RAISE EXCEPTION 'Pending void request not found for this branch';
    END IF;
    IF v_request.requested_by_user_id = auth.uid() THEN
      RAISE EXCEPTION 'The requester cannot review their own request';
    END IF;

    UPDATE public.order_void_requests
    SET request_status='rejected',
        approved_by_user_id=auth.uid(),
        approved_by_staff_id=v_actor.restaurant_user_id,
        approved_by_session_id=p_session_id,
        approved_by_name=v_actor.actor_name,
        approval_reason=btrim(p_reason),
        approved_at=now()
    WHERE id=v_request.id
      AND restaurant_id=v_actor.restaurant_id
      AND branch_id=v_actor.branch_id;

    RETURN jsonb_build_object('success',true,'rejected',true);
  END IF;

  RAISE EXCEPTION 'Unsupported void action';
END;
$function$;

REVOKE ALL ON FUNCTION public.place_order_with_pricing(uuid,text,text,jsonb,numeric,numeric,numeric,numeric,numeric,text,text,text,text,text,text,uuid,uuid,jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.place_order_with_pricing(uuid,text,text,jsonb,numeric,numeric,numeric,numeric,numeric,text,text,text,text,text,text,uuid,uuid,jsonb)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.edmel_void_order(uuid,uuid,text,text,uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edmel_void_order(uuid,uuid,text,text,uuid)
  TO authenticated, service_role;
