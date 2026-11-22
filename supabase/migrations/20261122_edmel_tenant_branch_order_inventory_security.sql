-- Remove broad/legacy stock policies and the public stock table read.
DROP POLICY IF EXISTS "Owners and admins can insert product stock" ON public."PRODUCT_STOCK";
DROP POLICY IF EXISTS "Active cashier staff can view product stock" ON public."PRODUCT_STOCK";
DROP POLICY IF EXISTS "Allow public to view product stock" ON public."PRODUCT_STOCK";
DROP POLICY IF EXISTS "Owners and admins can view product stock" ON public."PRODUCT_STOCK";
DROP POLICY IF EXISTS "Active cashiers can update product stock" ON public."PRODUCT_STOCK";
DROP POLICY IF EXISTS "Active demo restaurant staff can update product stock" ON public."PRODUCT_STOCK";
DROP POLICY IF EXISTS "Allow cashier to update product stock" ON public."PRODUCT_STOCK";
DROP POLICY IF EXISTS "Owners and admins can update product stock" ON public."PRODUCT_STOCK";
REVOKE SELECT, UPDATE ON TABLE public."PRODUCT_STOCK" FROM anon;

CREATE POLICY "EDMEL tenant branch stock select"
ON public."PRODUCT_STOCK" FOR SELECT TO authenticated
USING (
  restaurant_id IS NOT NULL
  AND branch_id IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND ru.restaurant_id = "PRODUCT_STOCK".restaurant_id
      AND ru.is_active = true
      AND lower(ru.role) IN ('owner','admin','staff','cashier')
      AND (
        lower(ru.role) IN ('owner','admin')
        OR public.edmel_has_branch_permission("PRODUCT_STOCK".branch_id, 'stocks')
      )
  )
);

CREATE POLICY "EDMEL owner admin branch stock insert"
ON public."PRODUCT_STOCK" FOR INSERT TO authenticated
WITH CHECK (
  restaurant_id IS NOT NULL
  AND branch_id IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND ru.restaurant_id = "PRODUCT_STOCK".restaurant_id
      AND ru.is_active = true
      AND lower(ru.role) IN ('owner','admin')
      AND public.edmel_has_branch_permission("PRODUCT_STOCK".branch_id, NULL)
  )
);

CREATE POLICY "EDMEL tenant branch stock update"
ON public."PRODUCT_STOCK" FOR UPDATE TO authenticated
USING (
  restaurant_id IS NOT NULL
  AND branch_id IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND ru.restaurant_id = "PRODUCT_STOCK".restaurant_id
      AND ru.is_active = true
      AND lower(ru.role) IN ('owner','admin','staff','cashier')
      AND (
        lower(ru.role) IN ('owner','admin')
        OR public.edmel_has_branch_permission("PRODUCT_STOCK".branch_id, 'stocks')
      )
  )
)
WITH CHECK (
  restaurant_id IS NOT NULL
  AND branch_id IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND ru.restaurant_id = "PRODUCT_STOCK".restaurant_id
      AND ru.is_active = true
      AND lower(ru.role) IN ('owner','admin','staff','cashier')
      AND (
        lower(ru.role) IN ('owner','admin')
        OR public.edmel_has_branch_permission("PRODUCT_STOCK".branch_id, 'stocks')
      )
  )
);

DROP POLICY IF EXISTS "HALINA owners view all menu items" ON public.menu_items;
CREATE POLICY "EDMEL staff view tenant branch menu items"
ON public.menu_items FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND ru.restaurant_id = menu_items.restaurant_id
      AND ru.is_active = true
      AND lower(ru.role) IN ('owner','admin','staff','cashier')
      AND (menu_items.branch_id IS NULL OR public.edmel_has_branch_permission(menu_items.branch_id, NULL))
  )
);

DROP POLICY IF EXISTS "HALINA owners view all categories" ON public.menu_categories;
CREATE POLICY "EDMEL staff view tenant branch menu categories"
ON public.menu_categories FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND ru.restaurant_id = menu_categories.restaurant_id
      AND ru.is_active = true
      AND lower(ru.role) IN ('owner','admin','staff','cashier')
      AND (menu_categories.branch_id IS NULL OR public.edmel_has_branch_permission(menu_categories.branch_id, NULL))
  )
);

DROP POLICY IF EXISTS "Owners can view their restaurant orders" ON public.orders;
DROP POLICY IF EXISTS "Staff can view restaurant orders" ON public.orders;
CREATE POLICY "EDMEL owner admin view tenant orders"
ON public.orders FOR SELECT TO authenticated
USING (
  is_system_admin()
  OR EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND ru.restaurant_id = orders.restaurant_id
      AND ru.is_active = true
      AND lower(ru.role) IN ('owner','admin')
  )
);

CREATE POLICY "EDMEL staff view assigned branch orders"
ON public.orders FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.restaurant_users ru
    WHERE ru.user_id = (SELECT auth.uid())
      AND ru.restaurant_id = orders.restaurant_id
      AND ru.is_active = true
      AND lower(ru.role) IN ('staff','cashier')
      AND public.edmel_has_branch_permission(orders.branch_id, NULL)
  )
);

DROP POLICY IF EXISTS "Staff can view restaurant order items" ON public.order_items;
CREATE POLICY "EDMEL staff view assigned branch order items"
ON public.order_items FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.orders o
    JOIN public.restaurant_users ru
      ON ru.restaurant_id = o.restaurant_id
    WHERE o.id = order_items.order_id
      AND ru.user_id = (SELECT auth.uid())
      AND ru.is_active = true
      AND lower(ru.role) IN ('staff','cashier','owner','admin')
      AND (
        lower(ru.role) IN ('owner','admin')
        OR public.edmel_has_branch_permission(o.branch_id, NULL)
      )
  )
);

DO $block$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.restaurant_users
    WHERE cashier_username IS NOT NULL
      AND btrim(cashier_username) <> ''
    GROUP BY restaurant_id, lower(btrim(cashier_username))
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'Duplicate cashier usernames exist within a restaurant; tenant username index cannot be enabled';
  END IF;
END;
$block$;

DROP INDEX IF EXISTS public.restaurant_users_cashier_username_unique;
DROP INDEX IF EXISTS public.restaurant_users_cashier_username_lower_uidx;

REVOKE ALL ON FUNCTION public.verify_cashier_login_credentials(text, text)
  FROM PUBLIC, anon, authenticated, service_role;


CREATE OR REPLACE FUNCTION public.edmel_get_customer_stock_availability(
  p_restaurant_id uuid,
  p_table_number text,
  p_table_id uuid DEFAULT NULL,
  p_qr_token text DEFAULT NULL
)
RETURNS TABLE(product_id text, stock_group text, stock_remaining integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_branch_id uuid;
BEGIN
  IF p_restaurant_id IS NULL OR NULLIF(btrim(p_table_number), '') IS NULL THEN
    RAISE EXCEPTION 'Restaurant and table are required';
  END IF;

  IF p_table_id IS NOT NULL OR p_qr_token IS NOT NULL THEN
    IF p_table_id IS NULL OR NULLIF(btrim(p_qr_token), '') IS NULL THEN
      RAISE EXCEPTION 'Both table ID and QR token are required';
    END IF;

    SELECT rt.branch_id INTO v_branch_id
    FROM public.restaurant_tables rt
    JOIN public.restaurant_table_qr_tokens q ON q.table_id = rt.id
    WHERE rt.id = p_table_id
      AND rt.restaurant_id = p_restaurant_id
      AND lower(btrim(rt.table_number)) = lower(btrim(p_table_number))
      AND rt.is_active = true
      AND rt.is_locked = false
      AND q.token = p_qr_token;
  ELSE
    SELECT rt.branch_id INTO v_branch_id
    FROM public.restaurant_tables rt
    WHERE rt.restaurant_id = p_restaurant_id
      AND lower(btrim(rt.table_number)) = lower(btrim(p_table_number))
      AND rt.is_active = true
      AND rt.is_locked = false
    ORDER BY rt.created_at
    LIMIT 1;
  END IF;

  IF v_branch_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.restaurant_branches b
    WHERE b.id = v_branch_id
      AND b.restaurant_id = p_restaurant_id
      AND b.is_active = true
  ) THEN
    RAISE EXCEPTION 'The selected table is not active for this restaurant';
  END IF;

  RETURN QUERY
  SELECT ps.product_id, ps.stock_group, greatest(ps.stock_remaining, 0)
  FROM public."PRODUCT_STOCK" ps
  WHERE ps.restaurant_id = p_restaurant_id
    AND ps.branch_id = v_branch_id
    AND ps.is_available = true
    AND ps.is_archived = false
    AND EXISTS (
      SELECT 1 FROM public.menu_items mi
      WHERE mi.restaurant_id = p_restaurant_id
        AND mi.stock_product_id = ps.product_id
        AND mi.is_available = true
        AND (mi.branch_id IS NULL OR mi.branch_id = v_branch_id)
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.edmel_get_customer_stock_availability(uuid, text, uuid, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.edmel_get_customer_stock_availability(uuid, text, uuid, text)
  TO anon, authenticated;


CREATE OR REPLACE FUNCTION public.place_order_with_stock(p_restaurant_id uuid, p_table_number text, p_order_type text, p_items jsonb, p_total numeric, p_payment_method text, p_payment_status text, p_payment_reference text, p_special_instructions text, p_submission_key uuid, p_branch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  item jsonb;
  v_product_id text;
  v_quantity integer;
  v_stock_group text;
  v_remaining integer;
  v_order_id uuid;
  v_order_number bigint;
  v_existing_order_id uuid;
  v_existing_order_number bigint;
BEGIN
  IF p_restaurant_id IS NULL OR p_branch_id IS NULL THEN
    RAISE EXCEPTION 'Restaurant and branch are required';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.restaurant_branches b
    WHERE b.id = p_branch_id
      AND b.restaurant_id = p_restaurant_id
      AND b.is_active = true
  ) THEN
    RAISE EXCEPTION 'The selected branch is not active for this restaurant';
  END IF;

  IF p_submission_key IS NULL THEN
    RAISE EXCEPTION 'A submission key is required';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Order must contain at least one item';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(p_restaurant_id::text || ':' || p_submission_key::text, 0)
  );

  SELECT id, order_number
  INTO v_existing_order_id, v_existing_order_number
  FROM public.orders
  WHERE restaurant_id = p_restaurant_id
    AND submission_key = p_submission_key
  LIMIT 1;

  IF v_existing_order_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', true,
      'order_id', v_existing_order_id,
      'order_number', v_existing_order_number,
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
    WHERE ps.restaurant_id = p_restaurant_id
      AND ps.branch_id = p_branch_id
      AND ps.is_available = true
      AND ps.is_archived = false
      AND (
        ps.product_id = v_product_id
        OR (ps.stock_group = 'chicken-wings'
            AND EXISTS (
              SELECT 1 FROM public."PRODUCT_STOCK" wing
              WHERE wing.product_id = v_product_id
                AND wing.restaurant_id = p_restaurant_id
                AND wing.branch_id = p_branch_id
                AND wing.stock_group = 'chicken-wings'
                AND wing.is_available = true
                AND wing.is_archived = false
            ))
      )
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
    restaurant_id, branch_id, table_number, order_type, items, total, status,
    payment_method, payment_status, payment_reference, special_instructions,
    submission_key
  )
  VALUES (
    p_restaurant_id, p_branch_id, p_table_number, p_order_type, p_items, p_total, 'new',
    p_payment_method, p_payment_status, p_payment_reference,
    NULLIF(BTRIM(p_special_instructions), ''), p_submission_key
  )
  RETURNING id, order_number INTO v_order_id, v_order_number;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := item->>'product_id';
    v_quantity := (item->>'quantity')::integer;

    SELECT stock_group INTO v_stock_group
    FROM public."PRODUCT_STOCK"
    WHERE product_id = v_product_id
      AND restaurant_id = p_restaurant_id
      AND branch_id = p_branch_id
    LIMIT 1;

    IF v_stock_group = 'chicken-wings' THEN
      UPDATE public."PRODUCT_STOCK"
      SET stock_remaining = stock_remaining - v_quantity
      WHERE stock_group = 'chicken-wings'
        AND restaurant_id = p_restaurant_id
        AND branch_id = p_branch_id;
    ELSE
      UPDATE public."PRODUCT_STOCK"
      SET stock_remaining = stock_remaining - v_quantity
      WHERE product_id = v_product_id
        AND restaurant_id = p_restaurant_id
        AND branch_id = p_branch_id;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'order_id', v_order_id,
    'order_number', v_order_number,
    'duplicate_submission', false
  );
END;
$function$


CREATE OR REPLACE FUNCTION public.edmel_customer_place_order(p_restaurant_id uuid, p_table_number text, p_table_id uuid, p_qr_token text, p_order_type text, p_items jsonb, p_payment_method text, p_special_instructions text, p_submission_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_table_id uuid;
  v_table_number text;
  v_branch_id uuid;
  v_input_items jsonb;
  v_item jsonb;
  v_menu_item_id uuid;
  v_quantity integer;
  v_name text;
  v_price numeric(10,2);
  v_stock_product_id text;
  v_seen_ids uuid[] := ARRAY[]::uuid[];
  v_stock_items jsonb := '[]'::jsonb;
  v_subtotal numeric(14,2) := 0;
  v_result jsonb;
  v_order_id uuid;
  v_order_number bigint;
  v_existing_order_id uuid;
  v_existing_order_number bigint;
BEGIN
  IF p_restaurant_id IS NULL OR p_submission_key IS NULL THEN
    RAISE EXCEPTION 'Restaurant and submission key are required';
  END IF;
  IF p_order_type NOT IN ('dine_in','takeout') THEN
    RAISE EXCEPTION 'Unsupported order type';
  END IF;
  IF p_payment_method NOT IN ('online','cash') THEN
    RAISE EXCEPTION 'Unsupported payment method';
  END IF;
  IF NULLIF(BTRIM(p_table_number),'') IS NULL THEN
    RAISE EXCEPTION 'A valid table number is required';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.restaurants r WHERE r.id=p_restaurant_id) THEN
    RAISE EXCEPTION 'Restaurant not found';
  END IF;

  IF p_table_id IS NOT NULL OR p_qr_token IS NOT NULL THEN
    IF p_table_id IS NULL OR NULLIF(BTRIM(p_qr_token),'') IS NULL THEN
      RAISE EXCEPTION 'Both table ID and QR token are required';
    END IF;

    SELECT rt.id, rt.table_number, rt.branch_id
      INTO v_table_id, v_table_number, v_branch_id
    FROM public.restaurant_tables rt
    JOIN public.restaurant_table_qr_tokens q ON q.table_id=rt.id
    WHERE rt.id=p_table_id
      AND rt.restaurant_id=p_restaurant_id
      AND lower(BTRIM(rt.table_number))=lower(BTRIM(p_table_number))
      AND rt.is_active=true
      AND rt.is_locked=false
      AND q.token=p_qr_token;

    IF v_table_id IS NULL THEN
      RAISE EXCEPTION 'Invalid, inactive, or locked table QR';
    END IF;
  ELSE
    SELECT rt.id, rt.table_number, rt.branch_id
      INTO v_table_id, v_table_number, v_branch_id
    FROM public.restaurant_tables rt
    WHERE rt.restaurant_id=p_restaurant_id
      AND lower(BTRIM(rt.table_number))=lower(BTRIM(p_table_number))
      AND rt.is_active=true
      AND rt.is_locked=false
    LIMIT 1;

    IF v_table_id IS NULL THEN
      RAISE EXCEPTION 'The selected table is not active for this restaurant';
    END IF;
  END IF;

  IF v_branch_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.restaurant_branches b
    WHERE b.id = v_branch_id
      AND b.restaurant_id = p_restaurant_id
      AND b.is_active = true
  ) THEN
    RAISE EXCEPTION 'The selected table does not belong to an active branch';
  END IF;

  SELECT o.id, o.order_number
    INTO v_existing_order_id, v_existing_order_number
  FROM public.orders o
  WHERE o.restaurant_id=p_restaurant_id
    AND o.submission_key=p_submission_key
  LIMIT 1;

  IF v_existing_order_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success',true,
      'order_id',v_existing_order_id,
      'order_number',v_existing_order_number,
      'duplicate_submission',true,
      'payment_status','pending'
    );
  END IF;

  IF p_table_id IS NOT NULL THEN
    SELECT c.cart_items
      INTO v_input_items
    FROM public.table_shared_carts c
    WHERE c.table_id=v_table_id
      AND c.checkout_locked=true
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'The shared cart must be locked before checkout';
    END IF;
  ELSE
    v_input_items := p_items;
  END IF;

  IF v_input_items IS NULL
     OR jsonb_typeof(v_input_items) <> 'array'
     OR jsonb_array_length(v_input_items)=0
     OR jsonb_array_length(v_input_items)>100 THEN
    RAISE EXCEPTION 'Order must contain between 1 and 100 items';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(v_input_items)
  LOOP
    IF NULLIF(BTRIM(v_item->>'id'),'') IS NULL THEN
      RAISE EXCEPTION 'Every order item must include a menu item ID';
    END IF;

    BEGIN
      v_menu_item_id := (v_item->>'id')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'Invalid menu item ID';
    END;

    IF v_menu_item_id = ANY(v_seen_ids) THEN
      RAISE EXCEPTION 'Duplicate menu items are not allowed in the checkout payload';
    END IF;
    v_seen_ids := array_append(v_seen_ids,v_menu_item_id);

    IF COALESCE(v_item->>'qty',v_item->>'quantity','') !~ '^[0-9]{1,3}$' THEN
      RAISE EXCEPTION 'Invalid item quantity';
    END IF;
    v_quantity := COALESCE(v_item->>'qty',v_item->>'quantity')::integer;
    IF v_quantity < 1 OR v_quantity > 100 THEN
      RAISE EXCEPTION 'Item quantity must be between 1 and 100';
    END IF;

    SELECT mi.name, mi.price, mi.stock_product_id
      INTO v_name, v_price, v_stock_product_id
    FROM public.menu_items mi
    JOIN public.menu_categories mc
      ON mc.id=mi.category_id
     AND mc.restaurant_id=mi.restaurant_id
    WHERE mi.id=v_menu_item_id
      AND mi.restaurant_id=p_restaurant_id
      AND (mi.branch_id IS NULL OR mi.branch_id = v_branch_id)
      AND (mc.branch_id IS NULL OR mc.branch_id = v_branch_id)
      AND mi.is_available=true
      AND mc.is_active=true
    FOR SHARE OF mi;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'A selected menu item is unavailable for this restaurant';
    END IF;

    IF NULLIF(BTRIM(v_stock_product_id),'') IS NULL
       OR NOT EXISTS (
         SELECT 1
         FROM public."PRODUCT_STOCK" ps
         WHERE ps.product_id=v_stock_product_id
           AND ps.restaurant_id=p_restaurant_id
           AND ps.branch_id=v_branch_id
           AND ps.is_available=true
           AND ps.is_archived=false
       ) THEN
      RAISE EXCEPTION 'Inventory is not configured for menu item: %', v_name;
    END IF;

    v_subtotal := v_subtotal + (v_price * v_quantity);
    v_stock_items := v_stock_items || jsonb_build_array(
      jsonb_build_object(
        'id',v_menu_item_id,
        'menu_item_id',v_menu_item_id,
        'product_id',v_stock_product_id,
        'name',v_name,
        'price',v_price,
        'qty',v_quantity,
        'quantity',v_quantity
      )
    );
  END LOOP;

  v_result := public.place_order_with_stock(
    p_restaurant_id,
    v_table_number,
    p_order_type,
    v_stock_items,
    round(v_subtotal,2),
    p_payment_method,
    'pending',
    NULL,
    NULLIF(BTRIM(p_special_instructions),''),
    p_submission_key,
    v_branch_id
  );

  v_order_id := NULLIF(v_result->>'order_id','')::uuid;
  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'Order creation did not return an order ID';
  END IF;

  UPDATE public.orders
  SET table_id=v_table_id,
      branch_id=v_branch_id,
      table_number=v_table_number,
      subtotal=round(v_subtotal,2),
      tax=0,
      discount_amount=0,
      service_charge=0,
      total=round(v_subtotal,2),
      payment_status='pending',
      payment_reference=NULL,
      pricing_breakdown=jsonb_build_object(
        'source','customer_menu_catalog',
        'currency',(SELECT r.currency FROM public.restaurants r WHERE r.id=p_restaurant_id),
        'tax',0,
        'discount',0,
        'service_charge',0,
        'payment_confirmation','staff_required'
      ),
      updated_at=now()
  WHERE id=v_order_id
    AND restaurant_id=p_restaurant_id
  RETURNING order_number INTO v_order_number;

  RETURN v_result || jsonb_build_object(
    'success',true,
    'order_id',v_order_id,
    'order_number',v_order_number,
    'subtotal',round(v_subtotal,2),
    'total',round(v_subtotal,2),
    'payment_status','pending'
  );
END;
$function$


CREATE OR REPLACE FUNCTION public.cashier_accept_order(p_order_id uuid, p_session_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_staff record;
  v_order public.orders%rowtype;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;

  SELECT ss.restaurant_id, ss.restaurant_user_id, ss.branch_id,
         ru.role, ru.position, ru.permissions,
         coalesce(nullif(btrim(ru.display_name), ''), nullif(btrim(ru.full_name), '')) actor_name
  INTO v_staff
  FROM public.staff_sessions ss
  JOIN public.restaurant_users ru
    ON ru.id = ss.restaurant_user_id
   AND ru.restaurant_id = ss.restaurant_id
  WHERE ss.id = p_session_id
    AND ss.user_id = auth.uid()
    AND ru.user_id = auth.uid()
    AND ru.is_active = true
    AND ss.logout_at IS NULL
    AND coalesce(ss.last_activity_at, ss.last_seen_at, ss.login_at) > now() - interval '30 minutes';

  IF v_staff.restaurant_user_id IS NULL THEN RAISE EXCEPTION 'Active cashier session required'; END IF;
  IF lower(coalesce(v_staff.role, '')) NOT IN ('staff','cashier','owner','admin')
     OR NOT public.edmel_has_branch_permission(v_staff.branch_id, 'orders') THEN
    RAISE EXCEPTION 'Cashier order permission is not assigned for this branch';
  END IF;

  SELECT o.* INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
    AND o.restaurant_id = v_staff.restaurant_id
    AND o.branch_id = v_staff.branch_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found for this branch'; END IF;

  IF lower(coalesce(v_order.status, '')) = 'accepted'
     AND v_order.accepted_by_session_id = p_session_id THEN
    RETURN jsonb_build_object('success', true, 'already_accepted', true,
      'order_id', v_order.id, 'accepted_at', v_order.accepted_at);
  END IF;

  UPDATE public.orders o
  SET status = 'accepted',
      accepted_by_user_id = auth.uid(),
      accepted_by_session_id = p_session_id,
      accepted_by_name = v_staff.actor_name,
      accepted_at = now(),
      updated_at = now()
  WHERE o.id = p_order_id
    AND o.restaurant_id = v_staff.restaurant_id
    AND o.branch_id = v_staff.branch_id
    AND lower(coalesce(o.status, 'new')) IN ('new','pending','confirmed')
    AND o.accepted_at IS NULL
  RETURNING o.* INTO v_order;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'already_accepted', true,
      'message', 'This order has already been accepted by another session or is no longer new.');
  END IF;

  RETURN jsonb_build_object('success', true, 'order_id', v_order.id, 'accepted_at', v_order.accepted_at);
END;
$function$;

CREATE OR REPLACE FUNCTION public.cashier_settle_order(p_order_id uuid, p_session_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_staff record;
  v_order public.orders%rowtype;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;

  SELECT ss.restaurant_id, ss.restaurant_user_id, ss.branch_id,
         ru.role, ru.position, ru.permissions,
         coalesce(nullif(btrim(ru.display_name), ''), nullif(btrim(ru.full_name), '')) actor_name
  INTO v_staff
  FROM public.staff_sessions ss
  JOIN public.restaurant_users ru
    ON ru.id = ss.restaurant_user_id
   AND ru.restaurant_id = ss.restaurant_id
  WHERE ss.id = p_session_id
    AND ss.user_id = auth.uid()
    AND ru.user_id = auth.uid()
    AND ru.is_active = true
    AND ss.logout_at IS NULL
    AND coalesce(ss.last_activity_at, ss.last_seen_at, ss.login_at) > now() - interval '30 minutes';

  IF v_staff.restaurant_user_id IS NULL THEN RAISE EXCEPTION 'Active cashier session required'; END IF;
  IF lower(coalesce(v_staff.role, '')) NOT IN ('staff','cashier','owner','admin')
     OR NOT public.edmel_has_branch_permission(v_staff.branch_id, 'orders') THEN
    RAISE EXCEPTION 'Cashier payment permission is not assigned for this branch';
  END IF;

  SELECT o.* INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
    AND o.restaurant_id = v_staff.restaurant_id
    AND o.branch_id = v_staff.branch_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found for this branch'; END IF;

  IF lower(coalesce(v_order.payment_status, '')) IN ('paid','successful','succeeded','verified')
     AND v_order.settled_by_session_id = p_session_id THEN
    RETURN jsonb_build_object('success', true, 'already_settled', true,
      'order_id', v_order.id, 'settled_at', v_order.settled_at);
  END IF;

  UPDATE public.orders o
  SET payment_status = 'paid',
      settled_by_user_id = auth.uid(),
      settled_by_session_id = p_session_id,
      settled_by_name = v_staff.actor_name,
      settled_at = now(),
      updated_at = now()
  WHERE o.id = p_order_id
    AND o.restaurant_id = v_staff.restaurant_id
    AND o.branch_id = v_staff.branch_id
    AND lower(coalesce(o.status, '')) IN ('served','completed')
    AND lower(coalesce(o.payment_status, 'pending')) IN ('pending','unpaid','')
    AND o.settled_at IS NULL
  RETURNING o.* INTO v_order;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'already_settled', true,
      'message', 'This order is already settled by another session or is not ready for payment.');
  END IF;

  RETURN jsonb_build_object('success', true, 'order_id', v_order.id, 'settled_at', v_order.settled_at);
END;
$function$;

CREATE OR REPLACE FUNCTION public.edmel_dispatcher_update_order(p_order_id uuid, p_session_id uuid, p_status text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_staff record;
  v_order public.orders%rowtype;
  v_current text;
  v_next text := lower(coalesce(p_status, ''));
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF v_next NOT IN ('preparing','ready','served') THEN RAISE EXCEPTION 'Unsupported Dispatcher status'; END IF;

  SELECT ss.restaurant_id, ss.restaurant_user_id, ss.branch_id,
         ru.role, ru.position, ru.permissions,
         coalesce(nullif(btrim(ru.display_name), ''), nullif(btrim(ru.full_name), ''), 'Dispatcher') actor_name
  INTO v_staff
  FROM public.staff_sessions ss
  JOIN public.restaurant_users ru
    ON ru.id = ss.restaurant_user_id
   AND ru.restaurant_id = ss.restaurant_id
  WHERE ss.id = p_session_id
    AND ss.user_id = auth.uid()
    AND ru.user_id = auth.uid()
    AND ru.is_active = true
    AND ss.logout_at IS NULL
    AND coalesce(ss.last_activity_at, ss.last_seen_at, ss.login_at) > now() - interval '30 minutes';

  IF v_staff.restaurant_user_id IS NULL
     OR lower(coalesce(v_staff.position, '')) <> 'dispatcher'
     OR coalesce((v_staff.permissions->>'dispatcher')::boolean, false) IS NOT TRUE
     OR NOT public.edmel_has_branch_permission(v_staff.branch_id, NULL) THEN
    RAISE EXCEPTION 'Active Dispatcher access is required for this branch';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
    AND restaurant_id = v_staff.restaurant_id
    AND branch_id = v_staff.branch_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found for this branch'; END IF;
  v_current := lower(coalesce(v_order.status, ''));
  IF v_current = 'voided' THEN RAISE EXCEPTION 'Voided orders cannot be updated'; END IF;

  IF (v_next = 'preparing' AND v_current NOT IN ('new','pending','accepted','confirmed'))
     OR (v_next = 'ready' AND v_current <> 'preparing')
     OR (v_next = 'served' AND v_current <> 'ready') THEN
    RAISE EXCEPTION 'Order status has changed or transition is not allowed';
  END IF;

  UPDATE public.orders
  SET status = v_next,
      completed_at = CASE WHEN v_next = 'served' THEN now() ELSE completed_at END,
      updated_at = now()
  WHERE id = v_order.id
    AND restaurant_id = v_staff.restaurant_id
    AND branch_id = v_staff.branch_id;

  INSERT INTO public.audit_logs(
    restaurant_id, actor_user_id, actor_name, actor_role,
    action_category, action, record_type, record_id, result, details
  )
  VALUES (
    v_staff.restaurant_id, auth.uid(), v_staff.actor_name, v_staff.role,
    'orders', 'dispatcher_status_updated', 'order', v_order.id::text, 'success',
    jsonb_build_object('from', v_current, 'to', v_next, 'branch_id', v_staff.branch_id)
  );

  RETURN jsonb_build_object('success', true, 'order_id', v_order.id, 'status', v_next);
END;
$function$;


REVOKE ALL ON FUNCTION public.place_order_with_stock(uuid, text, text, jsonb, numeric, text, text, text, text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.place_order_with_stock(uuid, text, text, jsonb, numeric, text, text, text, text, uuid, uuid)
  TO service_role;

REVOKE ALL ON FUNCTION public.cashier_accept_order(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cashier_accept_order(uuid, uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.cashier_settle_order(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cashier_settle_order(uuid, uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.edmel_dispatcher_update_order(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.edmel_dispatcher_update_order(uuid, uuid, text) TO authenticated, service_role;
