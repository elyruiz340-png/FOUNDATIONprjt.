
CREATE OR REPLACE FUNCTION public.cashier_accept_order(
  p_order_id uuid,
  p_session_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_restaurant_user_id uuid;
  v_restaurant_id uuid;
  v_order public.orders%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT ru.id, ru.restaurant_id
    INTO v_restaurant_user_id, v_restaurant_id
  FROM public.restaurant_users ru
  WHERE ru.user_id = auth.uid()
    AND ru.is_active = true
    AND lower(ru.role) IN ('owner','admin','staff','cashier')
  ORDER BY CASE lower(ru.role) WHEN 'owner' THEN 1 WHEN 'admin' THEN 2 ELSE 3 END
  LIMIT 1;

  IF v_restaurant_user_id IS NULL THEN
    RAISE EXCEPTION 'Active cashier account not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.staff_sessions ss
    WHERE ss.id = p_session_id
      AND ss.user_id = auth.uid()
      AND ss.restaurant_user_id = v_restaurant_user_id
      AND ss.restaurant_id = v_restaurant_id
      AND ss.logout_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Active cashier session required';
  END IF;

  SELECT o.* INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
    AND o.restaurant_id = v_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found for this restaurant';
  END IF;

  IF lower(coalesce(v_order.status, '')) = 'accepted'
     AND v_order.accepted_by_session_id = p_session_id THEN
    RETURN jsonb_build_object(
      'success', true,
      'already_accepted', true,
      'order_id', v_order.id,
      'accepted_at', v_order.accepted_at
    );
  END IF;

  UPDATE public.orders o
  SET status = 'accepted',
      accepted_by_user_id = auth.uid(),
      accepted_by_session_id = p_session_id,
      accepted_at = now(),
      updated_at = now()
  WHERE o.id = p_order_id
    AND o.restaurant_id = v_restaurant_id
    AND lower(coalesce(o.status, 'new')) IN ('new','pending','confirmed')
    AND o.accepted_at IS NULL
  RETURNING o.* INTO v_order;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'already_accepted', true,
      'message', 'This order has already been accepted by another session or is no longer new.'
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'order_id', v_order.id,
    'accepted_at', v_order.accepted_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.cashier_settle_order(
  p_order_id uuid,
  p_session_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_restaurant_user_id uuid;
  v_restaurant_id uuid;
  v_order public.orders%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT ru.id, ru.restaurant_id
    INTO v_restaurant_user_id, v_restaurant_id
  FROM public.restaurant_users ru
  WHERE ru.user_id = auth.uid()
    AND ru.is_active = true
    AND lower(ru.role) IN ('owner','admin','staff','cashier')
  ORDER BY CASE lower(ru.role) WHEN 'owner' THEN 1 WHEN 'admin' THEN 2 ELSE 3 END
  LIMIT 1;

  IF v_restaurant_user_id IS NULL THEN
    RAISE EXCEPTION 'Active cashier account not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.staff_sessions ss
    WHERE ss.id = p_session_id
      AND ss.user_id = auth.uid()
      AND ss.restaurant_user_id = v_restaurant_user_id
      AND ss.restaurant_id = v_restaurant_id
      AND ss.logout_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Active cashier session required';
  END IF;

  SELECT o.* INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
    AND o.restaurant_id = v_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found for this restaurant';
  END IF;

  IF lower(coalesce(v_order.payment_status, '')) IN ('paid','successful','succeeded','verified')
     AND v_order.settled_by_session_id = p_session_id THEN
    RETURN jsonb_build_object(
      'success', true,
      'already_settled', true,
      'order_id', v_order.id,
      'settled_at', v_order.settled_at
    );
  END IF;

  UPDATE public.orders o
  SET payment_status = 'paid',
      settled_by_user_id = auth.uid(),
      settled_by_session_id = p_session_id,
      settled_at = now(),
      updated_at = now()
  WHERE o.id = p_order_id
    AND o.restaurant_id = v_restaurant_id
    AND lower(coalesce(o.status, '')) IN ('served','completed')
    AND lower(coalesce(o.payment_status, 'pending')) IN ('pending','unpaid','')
    AND o.settled_at IS NULL
  RETURNING o.* INTO v_order;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'already_settled', true,
      'message', 'This order is already settled by another session or is not ready for payment.'
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'order_id', v_order.id,
    'settled_at', v_order.settled_at
  );
END;
$$;
