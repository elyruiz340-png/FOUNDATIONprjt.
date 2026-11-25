
CREATE OR REPLACE FUNCTION public.edmel_manager_request_order_void(
  p_order_id uuid,p_session_id uuid,p_reason text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_actor record;
  v_order public.orders%rowtype;
  v_request public.order_void_requests%rowtype;
  v_status text;
  v_resubmission boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 OR length(btrim(p_reason)) > 500 THEN
    RAISE EXCEPTION 'A void reason between 3 and 500 characters is required';
  END IF;
  SELECT ss.restaurant_id,ss.branch_id,ss.restaurant_user_id,ru.role,ru.position,
    coalesce(nullif(btrim(ru.display_name),''),nullif(btrim(ru.full_name),''),'Manager') AS actor_name,
    sba.permissions
  INTO v_actor
  FROM public.staff_sessions ss
  JOIN public.restaurant_users ru ON ru.id=ss.restaurant_user_id AND ru.restaurant_id=ss.restaurant_id
  JOIN public.staff_branch_access sba ON sba.restaurant_user_id=ru.id AND sba.restaurant_id=ru.restaurant_id
    AND sba.branch_id=ss.branch_id AND sba.is_active=true
  JOIN public.restaurant_branches b ON b.id=ss.branch_id AND b.restaurant_id=ss.restaurant_id AND b.is_active=true
  WHERE ss.id=p_session_id AND ss.user_id=auth.uid() AND ru.user_id=auth.uid() AND ru.is_active=true
    AND lower(coalesce(ru.role,''))='staff' AND lower(coalesce(ru.position,''))='manager'
    AND ss.logout_at IS NULL
    AND coalesce(ss.last_activity_at,ss.last_seen_at,ss.login_at)>now()-interval '30 minutes'
  FOR SHARE OF ss,ru,sba,b;
  IF v_actor.restaurant_user_id IS NULL THEN RAISE EXCEPTION 'An active Manager session and branch assignment are required'; END IF;
  IF NOT (public.edmel_permission_json_allows(v_actor.permissions,'orders','delete') OR public.edmel_permission_json_allows(v_actor.permissions,'transactions','delete')) THEN
    RAISE EXCEPTION 'Orders Delete permission is required to request an order void';
  END IF;
  SELECT * INTO v_order FROM public.orders o
  WHERE o.id=p_order_id AND o.restaurant_id=v_actor.restaurant_id AND o.branch_id=v_actor.branch_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found for this Manager branch'; END IF;
  v_status:=lower(coalesce(nullif(btrim(v_order.status),''),nullif(btrim(v_order.order_status),''),''));
  IF v_status NOT IN ('preparing','ready') THEN
    RAISE EXCEPTION 'Manager void requests are available only for Preparing or Ready orders';
  END IF;
  IF lower(coalesce(v_order.payment_status,'')) IN ('paid','successful','succeeded','verified','refunded')
     OR v_order.settled_at IS NOT NULL THEN
    RAISE EXCEPTION 'Paid, refunded, or settled orders cannot be voided through this workflow';
  END IF;
  SELECT * INTO v_request FROM public.order_void_requests r WHERE r.order_id=v_order.id FOR UPDATE;
  IF FOUND THEN
    IF v_request.restaurant_id<>v_actor.restaurant_id OR v_request.branch_id<>v_actor.branch_id THEN
      RAISE EXCEPTION 'A void request already exists outside this Manager branch';
    END IF;
    IF v_request.request_status='pending' THEN RAISE EXCEPTION 'A pending void request already exists for this order';
    ELSIF v_request.request_status<>'rejected' THEN RAISE EXCEPTION 'This order already has a completed void request';
    END IF;
    v_resubmission:=true;
    UPDATE public.order_void_requests SET reason=btrim(p_reason),request_status='pending',
      requested_by_user_id=auth.uid(),requested_by_staff_id=v_actor.restaurant_user_id,
      requested_by_session_id=p_session_id,requested_by_name=v_actor.actor_name,
      requested_order_status=v_status,approved_by_user_id=NULL,approved_by_staff_id=NULL,
      approved_by_session_id=NULL,approved_by_name=NULL,approval_reason=NULL,approved_at=NULL,
      voided_at=NULL,created_at=now()
    WHERE id=v_request.id RETURNING * INTO v_request;
  ELSE
    INSERT INTO public.order_void_requests(restaurant_id,branch_id,order_id,reason,request_status,
      requested_by_user_id,requested_by_staff_id,requested_by_session_id,requested_by_name,requested_order_status)
    VALUES(v_actor.restaurant_id,v_actor.branch_id,v_order.id,btrim(p_reason),'pending',auth.uid(),
      v_actor.restaurant_user_id,p_session_id,v_actor.actor_name,v_status)
    RETURNING * INTO v_request;
  END IF;
  INSERT INTO public.audit_logs(restaurant_id,actor_user_id,actor_name,actor_role,action_category,action,
    record_type,record_id,result,details)
  VALUES(v_actor.restaurant_id,auth.uid(),v_actor.actor_name,v_actor.role,'orders','void_requested',
    'order',v_order.id::text,'success',jsonb_build_object('request_id',v_request.id,'reason',btrim(p_reason),
    'order_status',v_status,'branch_id',v_actor.branch_id,'resubmission',v_resubmission));
  RETURN jsonb_build_object('success',true,'approval_required',true,'request_id',v_request.id,'order_id',v_order.id);
END;
$function$;
REVOKE ALL ON FUNCTION public.edmel_manager_request_order_void(uuid,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.edmel_manager_request_order_void(uuid,uuid,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.edmel_manager_request_order_void(uuid,uuid,text) TO authenticated;
