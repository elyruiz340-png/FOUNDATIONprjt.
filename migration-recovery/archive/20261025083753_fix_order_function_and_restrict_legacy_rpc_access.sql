BEGIN;

-- Fix the case-sensitive column typo in the 9-argument order function.
CREATE OR REPLACE FUNCTION public.place_order_with_stock(
  p_restaurant_id uuid,
  p_table_number text,
  p_order_type text,
  p_items jsonb,
  p_total numeric,
  p_payment_method text,
  p_payment_status text,
  p_payment_reference text,
  p_special_instructions text
)
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
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Order must contain at least one item';
  END IF;

  -- Validate stock before creating the order; lock the matched stock row.
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
    payment_method, payment_status, payment_reference, special_instructions
  )
  VALUES (
    p_restaurant_id, p_table_number, p_order_type, p_items, p_total, 'new',
    p_payment_method, p_payment_status, p_payment_reference,
    NULLIF(BTRIM(p_special_instructions), '')
  )
  RETURNING id INTO v_order_id;

  -- Preserve shared Chicken Wings stock behavior.
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

  RETURN jsonb_build_object('success', true, 'order_id', v_order_id);
END;
$function$;

-- This legacy global-PIN verifier is not used by the reviewed current cashier HTML,
-- which uses the cashier-login Edge Function and Supabase Auth OTP.
REVOKE ALL ON FUNCTION public.verify_cashier_pin(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.verify_cashier_pin(text) FROM anon, authenticated;

-- Event-trigger functions must not be callable through the exposed RPC API.
REVOKE ALL ON FUNCTION public.rls_auto_enable() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM anon, authenticated;

-- This is a trigger function, not an application RPC.
REVOKE ALL ON FUNCTION public.generate_daily_order_number() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.generate_daily_order_number() FROM anon, authenticated;

-- These helpers are used by authenticated RLS checks; remove anonymous RPC access only.
REVOKE EXECUTE ON FUNCTION public.current_user_restaurant_id() FROM anon;
REVOKE EXECUTE ON FUNCTION public.is_system_admin() FROM anon;

COMMIT;