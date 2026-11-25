-- Manager-only review route for pending order void requests.
-- Keeps the existing Cashier void workflow unchanged.
CREATE OR REPLACE FUNCTION public.edmel_manager_review_order_void(
  p_order_id uuid,
  p_session_id uuid,
  p_void_request_id uuid,
  p_action text,
  p_reason text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_actor record;
  v_order public.orders%rowtype;
  v_request public.order_void_requests%rowtype;
  v_status text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_action NOT IN ('approve','reject') THEN
    RAISE EXCEPTION 'Unsupported review action';
  END IF;

  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 OR length(btrim(p_reason)) > 500 THEN
    RAISE EXCEPTION 'A review reason between 3 and 500 characters is required';
  END IF;

  SELECT
    ss.restaurant_id,
    ss.branch_id,
    ss.restaurant_user_id,
    ru.role,
    ru.position,
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

  IF NOT (
    public.edmel_permission_json_allows(v_actor.permissions,'orders','approve')
    OR public.edmel_permission_json_allows(v_actor.permissions,'transactions','approve')
  ) THEN
    RAISE EXCEPTION 'Orders or Transactions Approve permission is not assigned for this branch';
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

  SELECT *
  INTO v_request
  FROM public.order_void_requests r
  WHERE r.id = p_void_request_id
    AND r.order_id = v_order.id
    AND r.restaurant_id = v_actor.restaurant_id
    AND r.branch_id = v_actor.branch_id
  FOR UPDATE;

  IF NOT FOUND OR v_request.request_status <> 'pending' THEN
    RAISE EXCEPTION 'Pending void request not found for this branch';
  END IF;

  IF v_request.requested_by_user_id = auth.uid() THEN
    RAISE EXCEPTION 'The requester cannot review their own void request';
  END IF;

  IF lower(coalesce(v_order.payment_status,'')) IN ('paid','successful','succeeded','verified','refunded')
     OR v_order.settled_at IS NOT NULL THEN
    RAISE EXCEPTION 'Paid, refunded, or settled orders cannot be voided through this workflow';
  END IF;

  IF p_action = 'approve' THEN
    IF v_status NOT IN ('preparing','ready') THEN
      RAISE EXCEPTION 'Order status changed; approval is no longer valid';
    END IF;

    UPDATE public.order_void_requests
    SET request_status = 'voided',
        approved_by_user_id = auth.uid(),
        approved_by_staff_id = v_actor.restaurant_user_id,
        approved_by_session_id = p_session_id,
        approved_by_name = v_actor.actor_name,
        approval_reason = btrim(p_reason),
        approved_at = now(),
        voided_at = now()
    WHERE id = v_request.id
      AND restaurant_id = v_actor.restaurant_id
      AND branch_id = v_actor.branch_id;

    UPDATE public.orders
    SET status = 'voided',
        order_status = 'voided',
        updated_at = now()
    WHERE id = v_order.id
      AND restaurant_id = v_actor.restaurant_id
      AND branch_id = v_actor.branch_id;

    INSERT INTO public.audit_logs(
      restaurant_id,actor_user_id,actor_name,actor_role,
      action_category,action,record_type,record_id,result,details
    ) VALUES (
      v_actor.restaurant_id,auth.uid(),v_actor.actor_name,v_actor.role,
      'orders','order_void_approved','order',v_order.id::text,'success',
      jsonb_build_object(
        'request_id',v_request.id,
        'request_reason',v_request.reason,
        'approval_reason',btrim(p_reason),
        'previous_status',v_status,
        'inventory_adjustment','not_applied_unverified_mapping',
        'branch_id',v_actor.branch_id
      )
    );

    RETURN jsonb_build_object('success',true,'action','approve','voided',true,'order_id',v_order.id);
  END IF;

  UPDATE public.order_void_requests
  SET request_status = 'rejected',
      approved_by_user_id = auth.uid(),
      approved_by_staff_id = v_actor.restaurant_user_id,
      approved_by_session_id = p_session_id,
      approved_by_name = v_actor.actor_name,
      approval_reason = btrim(p_reason),
      approved_at = now()
  WHERE id = v_request.id
    AND restaurant_id = v_actor.restaurant_id
    AND branch_id = v_actor.branch_id;

  INSERT INTO public.audit_logs(
    restaurant_id,actor_user_id,actor_name,actor_role,
    action_category,action,record_type,record_id,result,details
  ) VALUES (
    v_actor.restaurant_id,auth.uid(),v_actor.actor_name,v_actor.role,
    'orders','order_void_rejected','order',v_order.id::text,'success',
    jsonb_build_object(
      'request_id',v_request.id,
      'request_reason',v_request.reason,
      'review_reason',btrim(p_reason),
      'order_status',v_status,
      'branch_id',v_actor.branch_id
    )
  );

  RETURN jsonb_build_object('success',true,'action','reject','order_id',v_order.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_manager_review_order_void(uuid,uuid,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.edmel_manager_review_order_void(uuid,uuid,uuid,text,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.edmel_manager_review_order_void(uuid,uuid,uuid,text,text) TO authenticated;

DROP POLICY IF EXISTS "EDMEL manager view assigned branch void requests" ON public.order_void_requests;
CREATE POLICY "EDMEL manager view assigned branch void requests"
ON public.order_void_requests
FOR SELECT
TO authenticated
USING (
  public.edmel_manager_has_module_access(restaurant_id,branch_id,'orders','view')
  OR public.edmel_manager_has_module_access(restaurant_id,branch_id,'transactions','view')
);
