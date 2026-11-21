
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS accepted_by_user_id uuid,
  ADD COLUMN IF NOT EXISTS accepted_by_session_id uuid,
  ADD COLUMN IF NOT EXISTS accepted_at timestamptz,
  ADD COLUMN IF NOT EXISTS settled_by_user_id uuid,
  ADD COLUMN IF NOT EXISTS settled_by_session_id uuid,
  ADD COLUMN IF NOT EXISTS settled_at timestamptz,
  ADD COLUMN IF NOT EXISTS submission_key uuid;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'orders_accepted_by_user_id_fkey') THEN
    ALTER TABLE public.orders ADD CONSTRAINT orders_accepted_by_user_id_fkey
      FOREIGN KEY (accepted_by_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'orders_accepted_by_session_id_fkey') THEN
    ALTER TABLE public.orders ADD CONSTRAINT orders_accepted_by_session_id_fkey
      FOREIGN KEY (accepted_by_session_id) REFERENCES public.staff_sessions(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'orders_settled_by_user_id_fkey') THEN
    ALTER TABLE public.orders ADD CONSTRAINT orders_settled_by_user_id_fkey
      FOREIGN KEY (settled_by_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'orders_settled_by_session_id_fkey') THEN
    ALTER TABLE public.orders ADD CONSTRAINT orders_settled_by_session_id_fkey
      FOREIGN KEY (settled_by_session_id) REFERENCES public.staff_sessions(id) ON DELETE SET NULL;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS orders_restaurant_submission_key_uidx
  ON public.orders (restaurant_id, submission_key)
  WHERE submission_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS orders_accepted_by_session_idx
  ON public.orders (accepted_by_session_id)
  WHERE accepted_by_session_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS orders_settled_by_session_idx
  ON public.orders (settled_by_session_id)
  WHERE settled_by_session_id IS NOT NULL;

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
  v_role text;
  v_order public.orders%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT ru.id, ru.restaurant_id, lower(ru.role)
    INTO v_restaurant_user_id, v_restaurant_id, v_role
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
      'message', 'This order has already been accepted or is no longer new.'
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
      'message', 'This order is already settled or is not ready for payment.'
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'order_id', v_order.id,
    'settled_at', v_order.settled_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.place_order_with_stock(
  p_restaurant_id uuid,
  p_table_number text,
  p_order_type text,
  p_items jsonb,
  p_total numeric,
  p_payment_method text,
  p_payment_status text,
  p_payment_reference text,
  p_special_instructions text,
  p_submission_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  item jsonb;
  v_product_id text;
  v_quantity integer;
  v_stock_group text;
  v_remaining integer;
  v_order_id uuid;
  v_existing_order_id uuid;
BEGIN
  IF p_submission_key IS NULL THEN
    RAISE EXCEPTION 'A submission key is required';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Order must contain at least one item';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(p_restaurant_id::text || ':' || p_submission_key::text, 0)
  );

  SELECT id INTO v_existing_order_id
  FROM public.orders
  WHERE restaurant_id = p_restaurant_id
    AND submission_key = p_submission_key
  LIMIT 1;

  IF v_existing_order_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', true,
      'order_id', v_existing_order_id,
      'duplicate_submission', true
    );
  END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := NULLIF(BTRIM(item->>'product_id'), '');
    IF v_product_id IS NULL THEN
      RAISE EXCEPTION 'Every order item must have a product_id';
    END IF;

    IF COALESCE(item->>'quantity','') !~ '^[0-9]+$' THEN
      RAISE EXCEPTION 'Invalid quantity for product: %', v_product_id;
    END IF;
    v_quantity := (item->>'quantity')::integer;
    IF v_quantity < 1 THEN
      RAISE EXCEPTION 'Quantity must be at least 1 for product: %', v_product_id;
    END IF;

    SELECT ps.stock_group, ps.stock_remaining
      INTO v_stock_group, v_remaining
    FROM public."PRODUCT_STOCK" ps
    WHERE ps.product_id = v_product_id
       OR (ps.stock_group = 'chicken-wings'
           AND EXISTS (
             SELECT 1 FROM public."PRODUCT_STOCK" wing
             WHERE wing.product_id = v_product_id
               AND wing.stock_group = 'chicken-wings'
           ))
    ORDER BY CASE WHEN ps.product_id = v_product_id THEN 0 ELSE 1 END
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Stock not configured for product: %', v_product_id;
    END IF;

    IF v_remaining < v_quantity THEN
      RAISE EXCEPTION 'Not enough stock for product: %. Remaining: %, Requested: %',
        v_product_id, v_remaining, v_quantity;
    END IF;
  END LOOP;

  INSERT INTO public.orders (
    restaurant_id, table_number, order_type, items, total, status,
    payment_method, payment_status, payment_reference, special_instructions,
    submission_key
  )
  VALUES (
    p_restaurant_id, p_table_number, p_order_type, p_items, p_total, 'new',
    p_payment_method, p_payment_status, p_payment_reference,
    NULLIF(BTRIM(p_special_instructions), ''), p_submission_key
  )
  RETURNING id INTO v_order_id;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := item->>'product_id';
    v_quantity := (item->>'quantity')::integer;

    SELECT stock_group INTO v_stock_group
    FROM public."PRODUCT_STOCK"
    WHERE product_id = v_product_id
    LIMIT 1;

    IF v_stock_group = 'chicken-wings' THEN
      UPDATE public."PRODUCT_STOCK"
      SET stock_remaining = stock_remaining - v_quantity
      WHERE stock_group = 'chicken-wings';
    ELSE
      UPDATE public."PRODUCT_STOCK"
      SET stock_remaining = stock_remaining - v_quantity
      WHERE product_id = v_product_id;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'order_id', v_order_id,
    'duplicate_submission', false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.cashier_accept_order(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cashier_accept_order(uuid, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.cashier_settle_order(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cashier_settle_order(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.place_order_with_stock(uuid,text,text,jsonb,numeric,text,text,text,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.place_order_with_stock(uuid,text,text,jsonb,numeric,text,text,text,text,uuid) TO anon, authenticated;
