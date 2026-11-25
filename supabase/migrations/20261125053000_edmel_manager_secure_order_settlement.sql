-- Manager-only manual payment confirmation route.
-- Does not write provider payment records; it mirrors the existing Cashier order settlement model.
CREATE OR REPLACE FUNCTION public.edmel_manager_settle_order(
  p_order_id uuid,
  p_session_id uuid,
  p_confirmation_note text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_actor record;
  v_order public.orders%rowtype;
  v_status text;
  v_payment_status text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_confirmation_note IS NULL
     OR length(btrim(p_confirmation_note)) < 3
     OR length(btrim(p_confirmation_note)) > 500 THEN
    RAISE EXCEPTION 'Enter a payment confirmation note between 3 and 500 characters';
  END IF;

  SELECT
    ss.restaurant_id,
    ss.branch_id,
    ss.restaurant_user_id,
    ru.role,
    coalesce(nullif(btrim(ru.display_name),''),nullif(btrim(ru.full_name),''),'Manager') AS actor_name,
    sba.permissions
  INTO v_actor
  FROM public.staff_sessions ss
  JOIN public.restaurant_users ru
    ON ru.id = ss.restaurant_user_id
   AND ru.restaurant_id = ss.restaurant_id
  JOIN public.staff_branch_access sba
    ON sba.restaurant_user_id = ru.id
   AND sba.restaurant_id = ru.restaurant_id
   AND sba.branch_id = ss.branch_id
   AND sba.is_active = true
  JOIN public.restaurant_branches b
    ON b.id = ss.branch_id
   AND b.restaurant_id = ss.restaurant_id
   AND b.is_active = true
  WHERE ss.id = p_session_id
    AND ss.user_id = auth.uid()
    AND ru.user_id = auth.uid()
    AND ru.is_active = true
    AND lower(coalesce(ru.role,'')) = 'staff'
    AND lower(coalesce(ru.position,'')) = 'manager'
    AND ss.logout_at IS NULL
    AND coalesce(ss.last_activity_at,ss.last_seen_at,ss.login_at) > now() - interval '30 minutes'
  FOR SHARE OF ss, ru, sba, b;

  IF v_actor.restaurant_user_id IS NULL THEN
    RAISE EXCEPTION 'An active Manager session and branch assignment are required';
  END IF;

  IF NOT public.edmel_permission_json_allows(v_actor.permissions,'transactions','approve') THEN
    RAISE EXCEPTION 'Transactions Approve permission is not assigned for this branch';
  END IF;

  SELECT *
  INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
    AND o.restaurant_id = v_actor.restaurant_id
    AND o.branch_id = v_actor.branch_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found for this Manager branch';
  END IF;

  v_status := lower(coalesce(nullif(btrim(v_order.status),''),nullif(btrim(v_order.order_status),''),''));
  v_payment_status := lower(coalesce(nullif(btrim(v_order.payment_status),''),'pending'));

  IF v_status NOT IN ('served','completed') THEN
    RAISE EXCEPTION 'Only served or completed orders can be settled';
  END IF;

  IF v_payment_status NOT IN ('pending','unpaid') OR v_order.settled_at IS NOT NULL THEN
    RAISE EXCEPTION 'This order is already paid or is not eligible for settlement';
  END IF;

  UPDATE public.orders o
  SET payment_status = 'paid',
      settled_by_user_id = auth.uid(),
      settled_by_session_id = p_session_id,
      settled_by_name = v_actor.actor_name,
      settled_at = now(),
      updated_at = now()
  WHERE o.id = v_order.id
    AND o.restaurant_id = v_actor.restaurant_id
    AND o.branch_id = v_actor.branch_id
    AND lower(coalesce(o.payment_status,'pending')) IN ('pending','unpaid')
    AND o.settled_at IS NULL
  RETURNING o.* INTO v_order;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order payment state changed. Refresh and try again.';
  END IF;

  INSERT INTO public.audit_logs(
    restaurant_id,actor_user_id,actor_name,actor_role,
    action_category,action,record_type,record_id,result,details
  ) VALUES (
    v_actor.restaurant_id,auth.uid(),v_actor.actor_name,'manager',
    'transactions','manager_order_payment_confirmed','order',v_order.id::text,'success',
    jsonb_build_object(
      'branch_id',v_actor.branch_id,
      'payment_method',v_order.payment_method,
      'amount',v_order.total,
      'confirmation_note',btrim(p_confirmation_note),
      'previous_payment_status',v_payment_status,
      'payment_source','manual_confirmation'
    )
  );

  RETURN jsonb_build_object(
    'success',true,
    'order_id',v_order.id,
    'payment_status',v_order.payment_status,
    'settled_at',v_order.settled_at
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_manager_settle_order(uuid,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.edmel_manager_settle_order(uuid,uuid,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.edmel_manager_settle_order(uuid,uuid,text) TO authenticated;
