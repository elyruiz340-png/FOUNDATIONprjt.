CREATE OR REPLACE FUNCTION public.edmel_customer_place_order(
  p_restaurant_id uuid,
  p_table_number text,
  p_table_id uuid,
  p_qr_token text,
  p_order_type text,
  p_items jsonb,
  p_payment_method text,
  p_special_instructions text,
  p_submission_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_table_id uuid;
  v_table_number text;
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

    SELECT rt.id, rt.table_number
      INTO v_table_id, v_table_number
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
    SELECT rt.id, rt.table_number
      INTO v_table_id, v_table_number
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
    p_submission_key
  );

  v_order_id := NULLIF(v_result->>'order_id','')::uuid;
  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'Order creation did not return an order ID';
  END IF;

  UPDATE public.orders
  SET table_id=v_table_id,
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
$function$;

REVOKE ALL ON FUNCTION public.edmel_customer_place_order(uuid,text,uuid,text,text,jsonb,text,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.edmel_customer_place_order(uuid,text,uuid,text,text,jsonb,text,text,uuid) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.halina_finish_shared_cart_checkout(
  p_table_id uuid,
  p_qr_token text,
  p_clear boolean,
  p_submission_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_restaurant_id uuid;
  v_locked boolean;
BEGIN
  SELECT rt.restaurant_id
    INTO v_restaurant_id
  FROM public.restaurant_tables rt
  JOIN public.restaurant_table_qr_tokens q ON q.table_id=rt.id
  WHERE rt.id=p_table_id
    AND q.token=p_qr_token
    AND rt.is_active=true
    AND rt.is_locked=false;

  IF v_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'Invalid, inactive, or locked table QR';
  END IF;

  SELECT c.checkout_locked
    INTO v_locked
  FROM public.table_shared_carts c
  WHERE c.table_id=p_table_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shared cart not found';
  END IF;

  IF p_clear THEN
    IF p_submission_key IS NULL OR NOT EXISTS (
      SELECT 1
      FROM public.orders o
      WHERE o.restaurant_id=v_restaurant_id
        AND o.table_id=p_table_id
        AND o.submission_key=p_submission_key
    ) THEN
      RAISE EXCEPTION 'The shared cart cannot be cleared without a matching saved order';
    END IF;
  END IF;

  IF v_locked IS DISTINCT FROM true THEN
    IF p_clear=false THEN
      RETURN jsonb_build_object('success',true,'already_unlocked',true);
    END IF;
    RAISE EXCEPTION 'Shared cart is not locked';
  END IF;

  UPDATE public.table_shared_carts
  SET cart_items=CASE WHEN p_clear THEN '[]'::jsonb ELSE cart_items END,
      revision=revision+CASE WHEN p_clear THEN 1 ELSE 0 END,
      checkout_locked=false,
      updated_at=now()
  WHERE table_id=p_table_id;

  RETURN jsonb_build_object('success',true);
END;
$function$;

REVOKE ALL ON FUNCTION public.halina_finish_shared_cart_checkout(uuid,text,boolean,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.halina_finish_shared_cart_checkout(uuid,text,boolean,uuid) TO anon, authenticated;